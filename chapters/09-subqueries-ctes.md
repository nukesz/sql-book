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

A Common Table Expression names a subquery so the main query reads top to bottom.

```sql
WITH order_totals AS (
    SELECT order_id, sum(quantity * unit_price) AS total
    FROM order_items GROUP BY order_id
),
big_orders AS (
    SELECT * FROM order_totals WHERE total > 1000
)
SELECT c.country, count(*) AS big_orders, sum(b.total) AS revenue
FROM big_orders b
JOIN orders o    ON o.id = b.order_id
JOIN customers c ON c.id = o.customer_id
GROUP BY c.country
ORDER BY revenue DESC;
```

Uses: readability, reusing a result several times, and stepwise problem solving. Since PostgreSQL 12 a CTE referenced once is inlined like a subquery (no optimization fence); force old behaviour with `WITH x AS MATERIALIZED (...)` or prevent materialization with `NOT MATERIALIZED`.

## Recursive CTEs

For hierarchies and graphs: an anchor part `UNION ALL` a recursive part that refers to the CTE itself.

```sql
WITH RECURSIVE tree AS (
    SELECT id, name, parent_id, name::text AS path, 0 AS depth
    FROM categories WHERE parent_id IS NULL
  UNION ALL
    SELECT c.id, c.name, c.parent_id, t.path || ' > ' || c.name, t.depth + 1
    FROM categories c JOIN tree t ON c.parent_id = t.id
)
SELECT * FROM tree ORDER BY path;
```

Generate a series with it (or just use `generate_series`):

```sql
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10)
SELECT * FROM n;
```

Guard against infinite loops: a terminating condition, a depth limit, or `UNION` (dedupes) for graphs with cycles.

## Data-modifying CTEs

`INSERT`/`UPDATE`/`DELETE ... RETURNING` can be a CTE, which lets one statement do several steps atomically:

```sql
-- archive and delete in one statement
CREATE TABLE orders_archive (LIKE orders);
WITH moved AS (
    DELETE FROM orders
    WHERE status = 'cancelled' AND created_at < now() - interval '300 days'
      AND NOT EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = orders.id)
    RETURNING *
)
INSERT INTO orders_archive SELECT * FROM moved;
```

## VALUES and generate_series

```sql
SELECT * FROM (VALUES (1, 'a'), (2, 'b')) AS t(id, label);
SELECT d::date FROM generate_series('2025-01-01'::date, '2025-01-07', interval '1 day') d;
```

`generate_series` is perfect for filling gaps: left-join your data onto a complete calendar to show days with zero orders.

## Exercises

1. Products priced above the average price of *their own category* (correlated subquery).
2. Customers whose total spent exceeds the average total spent per customer (CTE).
3. Print the full category tree with depth, using indentation (`repeat('  ', depth) || name`).
4. Show orders per day for the last 14 days, **including days with zero orders** (`generate_series` + `LEFT JOIN`).
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
    SELECT d::date AS day, count(o.id)
    FROM generate_series(current_date - 13, current_date, interval '1 day') d
    LEFT JOIN orders o ON o.created_at::date = d::date
    GROUP BY 1 ORDER BY 1;
    -- 5
    WITH avg_cat AS (SELECT category_id, avg(price) a FROM products GROUP BY category_id)
    SELECT p.name, p.price FROM products p JOIN avg_cat a USING (category_id) WHERE p.price > a.a;
    -- 6
    WITH u AS (UPDATE products SET stock = stock + 10 RETURNING 1) SELECT count(*) FROM u;
    ```

Next: [10. Window Functions](10-window-functions.md)
