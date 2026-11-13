---
hide:
  - toc
---

# 9. Subqueries and CTEs

**You will learn:** composing queries from queries: scalar/`IN`/`EXISTS` subqueries, CTEs, recursive CTEs, and data-modifying CTEs.

## Subqueries

A subquery is a `SELECT` inside another statement.

```sql
-- scalar: returns one value
SELECT name, price FROM products WHERE price > (SELECT avg(price) FROM products);

-- IN: membership in a list
SELECT * FROM customers WHERE id IN (SELECT customer_id FROM orders WHERE status = 'cancelled');

-- EXISTS: is there at least one row? (stops at the first match)
SELECT * FROM customers c
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id AND o.status = 'new');

-- in FROM: a derived table (must have an alias)
SELECT country, avg(n) FROM (
    SELECT c.country, count(o.id) AS n
    FROM customers c LEFT JOIN orders o ON o.customer_id = c.id
    GROUP BY c.id, c.country
) per_customer
GROUP BY country;
```

A **correlated** subquery references the outer query (`o.customer_id = c.id` above); conceptually it runs per outer row, though the planner often rewrites it into a join.

`EXISTS` vs `IN`: equivalent for positive tests. For negation, prefer `NOT EXISTS`; `NOT IN` breaks with NULLs (chapter 7).

## CTEs: WITH

A **Common Table Expression** (CTE) gives a name to a subquery, and then lets the main query use that name like a table. The point is not new capability — most CTEs can be written as nested subqueries — but **readability**: instead of reading a query inside-out, you read it top to bottom, one named step at a time.

The same query, first as a nested derived table and then as a CTE:

```sql
-- nested: start at the innermost SELECT and work outwards
SELECT country, avg(n)
FROM (
    SELECT c.id, c.country, count(o.id) AS n
    FROM customers c LEFT JOIN orders o ON o.customer_id = c.id
    GROUP BY c.id, c.country
) per_customer
GROUP BY country;
```

```sql
-- same query, with the intermediate result named first
WITH per_customer AS (
    SELECT c.id, c.country, count(o.id) AS n
    FROM customers c LEFT JOIN orders o ON o.customer_id = c.id
    GROUP BY c.id, c.country
)
SELECT country, avg(n)
FROM per_customer
GROUP BY country;
```

The shape is always:

```sql
WITH step1 AS (SELECT ...),
     step2 AS (SELECT ... FROM step1 ...)   -- later CTEs can use earlier ones
SELECT ... FROM step2;                      -- the main query
```

A CTE exists only for that one statement. It is not a view and not a temporary table; it disappears when the statement finishes. The main query may reference the same CTE more than once, which is one thing a derived table cannot do conveniently.

Use a CTE when you want to:

- give a long or subtle intermediate result a meaningful name;
- **reuse** the same result in several places without repeating the subquery;
- turn deep nesting into a short, ordered pipeline of steps;
- write a **recursive** query (next section) — recursion requires `WITH RECURSIVE`;
- combine `INSERT`/`UPDATE`/`DELETE ... RETURNING` with another query (data-modifying CTEs, below).

### A worked example

```sql
WITH order_totals AS (        -- step 1: one row per order, with its total
    SELECT order_id, sum(quantity * unit_price) AS total
    FROM order_items
    GROUP BY order_id
),
big_orders AS (               -- step 2: keep only orders above 1000
    SELECT * FROM order_totals WHERE total > 1000
)
SELECT c.country,             -- step 3: join to the customer, aggregate by country
       count(*) AS big_orders,
       sum(b.total) AS revenue
FROM big_orders b
JOIN orders o    ON o.id = b.order_id
JOIN customers c ON c.id = o.customer_id
GROUP BY c.country
ORDER BY revenue DESC;
```

How to read it:

- `order_totals` collapses `order_items` (several lines per order) into **one total per order**.
- `big_orders` filters those order-level totals; it refers back to `order_totals` by name.
- The final query uses `big_orders`, then joins `orders` and `customers` to find the country for each order and aggregate by it.
- `sum(b.total)` sums the already-computed order totals, so the final `GROUP BY` must not include the order id.

CTEs are definitions, not separate executions. All parts form one statement, and the planner is free to combine them.

### Materialization

Since PostgreSQL 12, a CTE referenced **once** is inlined into the main query by default, exactly like a subquery — there is no optimization fence. A CTE referenced **more than once** is materialized (computed once into a temporary result) by default. You can override either behaviour:

```sql
WITH x AS MATERIALIZED (...)      -- force a separate, computed-once result
     y AS NOT MATERIALIZED (...)  -- ask for inlining, even if referenced twice
```

Materialization can be an optimization: compute an expensive result once and reuse it. It can also hurt: it may block the planner from pushing filters or indexes into the CTE. Measure with `EXPLAIN (ANALYZE, BUFFERS)` when in doubt.

## Recursive CTEs

A recursive CTE builds its result in repeated steps. It is the standard tool for hierarchies (category trees, org charts) and graphs (following edges until you run out). Unlike a normal CTE, it refers to **itself**.

`WITH RECURSIVE name AS (...)` contains two parts joined by `UNION ALL`:

- the **anchor** — a normal `SELECT` that produces the starting rows;
- the **recursive step** — a `SELECT` that reads from the CTE by name (`FROM tree`) and produces the next rows from the ones found so far.

PostgreSQL does not evaluate the whole thing at once; it loops:

1. Run the anchor once. Its rows go into the final result and become the *working set*.
2. Run the recursive step, with the CTE containing only the rows from the previous iteration.
3. Append the new rows to the result and make them the next working set.
4. Repeat until the recursive step returns no rows. The accumulated result is the answer.

So each iteration sees one more "level" of the hierarchy, which is exactly what lets the recursive part build on the previous level (`t.depth + 1`, `t.path || ' > ' || c.name`).

```sql
WITH RECURSIVE tree AS (
    -- anchor: start at the roots (categories with no parent)
    SELECT id, name, parent_id, name::text AS path, 0 AS depth
    FROM categories WHERE parent_id IS NULL
  UNION ALL
    -- recursive step: attach children to the rows just found
    SELECT c.id, c.name, c.parent_id, t.path || ' > ' || c.name, t.depth + 1
    FROM categories c JOIN tree t ON c.parent_id = t.id
)
SELECT * FROM tree ORDER BY path;
```

What happens, level by level:

- Iteration 1 (the anchor) returns the roots: `depth = 0`, `path = name`, e.g. `Electronics`.
- Iteration 2 joins `categories` to those roots, giving their children with `depth = 1` and `path = 'Electronics > Phones'`.
- Iteration 3 does the same for the children found in iteration 2, and so on.
- When a level has no children, the join produces no rows and the recursion stops.

The `path` and `depth` columns are not needed for the recursion itself; they are carried along so every row knows its lineage. `path` starts as the root name and grows with each child, so `ORDER BY path` prints the whole tree as a readable outline.

Two rules to remember: the CTE's column names and types come from the **anchor**, and the recursive part must return the same columns in the same order with compatible types (that is why the anchor casts `name::text`).

Generate a series with the same pattern (or just use `generate_series`):

```sql
WITH RECURSIVE n(i) AS (
    SELECT 1                    -- anchor: start at 1
  UNION ALL
    SELECT i + 1 FROM n         -- recursive step: add 1 to the previous row
    WHERE i < 10                -- stop after 10
)
SELECT * FROM n;
```

Here the anchor produces `i = 1`; each iteration adds 1 while `i < 10`, so the loop ends after 10 rows. The `n(i)` after the CTE name simply names its single column.

Recursion can loop forever if no step ever stops producing rows. Guard against it with a terminating condition (`WHERE i < 10`), a depth limit (`WHERE t.depth < 5`), or `UNION` instead of `UNION ALL` for graphs with cycles — `UNION` dedupes rows, so a cycle stops yielding new ones.

## Data-modifying CTEs

`INSERT`/`UPDATE`/`DELETE ... RETURNING` can be a CTE, which lets one statement do several steps atomically:

```sql
-- archive and delete in one statement
CREATE TABLE orders_archive (LIKE orders);  -- new empty table
WITH moved AS (
    DELETE FROM orders
    WHERE status = 'cancelled' AND created_at < now() - interval '300 days'
      AND NOT EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = orders.id)
    RETURNING *
)
INSERT INTO orders_archive SELECT * FROM moved;
```

## VALUES and generate_series

Both tools let a query invent rows that are not stored in any table. That is useful on its own, and essential when you need a **complete** list (every day, every id) to compare real data against.

### VALUES: a table built from literals

`VALUES` normally appears in `INSERT`, but it is also a complete query: it returns one row per parenthesised list. Put it in `FROM`, give it an alias and column names, and it behaves like a small read-only table:

```sql
SELECT * FROM (VALUES (1, 'a'), (2, 'b')) AS t(id, label);
```

Why use it?

- build a short lookup or reference list without creating a table (map codes to labels, filter by a hand-written list of ids);
- supply test or seed data in a single statement;
- feed a set of values into an `UPDATE` or `JOIN` instead of repeating a long `CASE` expression.

### generate_series: a table of generated values

`generate_series` is a **set-returning function**: it produces one row per value between a start and a stop. For integers you can supply a step; for timestamps the step is an interval:

```sql
SELECT * FROM generate_series(1, 5);                                    -- 1,2,3,4,5
SELECT * FROM generate_series(1, 10, 2);                                -- 1,3,5,7,9
SELECT d::date
FROM generate_series('2025-01-01'::date, '2025-01-07', interval '1 day') d;
```

Why use it? A real table only contains rows that exist. A day with no orders has no row in `orders`, so a plain `GROUP BY day` silently drops it. Generate the full calendar first, then `LEFT JOIN` the real data onto it. Days with no match come back with a `NULL` order id, and `count` ignores `NULL`, so they show as zero instead of disappearing:

```sql
SELECT d::date AS day, count(o.id) AS orders
FROM generate_series(current_date - 13, current_date, interval '1 day') d
LEFT JOIN orders o ON o.created_at::date = d::date
GROUP BY 1
ORDER BY 1;
```

The same trick fills gaps in reports, generates ids for batch jobs, and creates test data. `VALUES` and `generate_series` are often combined with a CTE (above) to build the reference rows once and reuse them.

## Exercises

1. Products priced above the average price of *their own category* (correlated subquery).
2. Customers whose total spent exceeds the average total spent per customer (CTE).
3. Print the full category tree with depth, using indentation (`repeat('  ', depth) || name`).
4. Find the gaps in the order id sequence: every integer between the smallest and largest order id that has no order (`generate_series` + `NOT EXISTS`).
5. Rewrite exercise 1 using a join to a pre-aggregated CTE. Which do you find more readable?
6. Using a data-modifying CTE, increase stock of all products by 10 and return count of changed rows in a single statement. (Hint: `WITH u AS (UPDATE ... RETURNING 1) SELECT count(*) FROM u`.)

??? note "Solutions"

    ```sql
    -- 1
    SELECT p.name, p.price FROM products p
    WHERE p.price > (SELECT avg(price) FROM products x WHERE x.category_id = p.category_id);
    -- 2
    WITH spent AS (
      SELECT o.customer_id, sum(oi.quantity * oi.unit_price) AS total
      FROM orders o JOIN order_items oi ON oi.order_id = o.id GROUP BY o.customer_id)
    SELECT * FROM spent WHERE total > (SELECT avg(total) FROM spent);
    -- 3
    WITH RECURSIVE t AS (
      SELECT id, name, 0 AS depth, name::text AS path FROM categories WHERE parent_id IS NULL
      UNION ALL
      SELECT c.id, c.name, t.depth + 1, t.path || '/' || c.name FROM categories c JOIN t ON c.parent_id = t.id)
    SELECT repeat('  ', depth) || name FROM t ORDER BY path;
    -- 4
    SELECT g AS missing_id
    FROM generate_series((SELECT min(id) FROM orders), (SELECT max(id) FROM orders)) g
    WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.id = g);
    -- 5
    WITH avg_cat AS (SELECT category_id, avg(price) a FROM products GROUP BY category_id)
    SELECT p.name, p.price FROM products p JOIN avg_cat a USING (category_id) WHERE p.price > a.a;
    -- 6
    WITH u AS (UPDATE products SET stock = stock + 10 RETURNING 1) SELECT count(*) FROM u;
    ```

Next: [10. Window Functions](10-window-functions.md)
