---
hide:
  - toc
---

# 10. Window Functions

**You will learn:** computing across related rows *without collapsing them*: rankings, running totals, comparisons with previous rows, top-N per group.

## The idea

So far, `GROUP BY` has been our tool for looking at groups of rows—but it has a catch: it **collapses** each group into a single row. Ask for the average price per category and the individual products disappear; you get one row per category, not the products with their category average beside them.

A **window function** gives you the same group-level calculations *without throwing the rows away*. Every original row stays, and each one gets an extra computed column based on a "window" of related rows—usually the rows in the same group.

The name is literal: the *window* is the block of rows the function is allowed to see. For each row, SQL looks through that window at a set of related rows, computes something (an average, a sum, a rank, the previous value), and writes the result next to the current row. The same product can be examined through a window of its category, a window of all products, or a window of the last seven days—the calculation changes, but the rows never disappear.

Compare the two approaches:

```sql
-- GROUP BY: one row per category, the individual products are gone
SELECT category_id, avg(price) AS category_avg
FROM products
GROUP BY category_id;

-- Window: every product kept, with its category average attached
SELECT name, category_id, price,
       avg(price) OVER (PARTITION BY category_id) AS category_avg,
       price - avg(price) OVER (PARTITION BY category_id) AS diff
FROM products;
```

The window version answers a question `GROUP BY` cannot answer on its own: "how does *this* product compare with its category average?" Because each detail row survives, you can keep computing with it—here subtracting the category average from the price.

Syntax: `function(...) OVER ([PARTITION BY cols] [ORDER BY cols] [frame])`.

- `PARTITION BY` splits rows into groups (like `GROUP BY`, but rows are kept).
- `ORDER BY` inside `OVER` orders rows within each partition.
- Window functions run **after** `WHERE`/`GROUP BY`/`HAVING`, so you cannot filter on them directly; wrap in a subquery/CTE.

## Ranking

Ordering rows and numbering them is a common need: "who is first?", "which is the top seller?" You already know `ORDER BY`, but that only sorts the output—it doesn't attach a position to each row or keep a separate numbering per group. Ranking window functions do exactly that.

```sql
SELECT name, category_id, price,
       row_number() OVER w AS rn,      -- 1,2,3,4 always unique
       rank()       OVER w AS rnk,     -- 1,2,2,4 ties share rank, gap after
       dense_rank() OVER w AS drnk     -- 1,2,2,3 no gap
FROM products
WINDOW w AS (PARTITION BY category_id ORDER BY price DESC);
```

`WINDOW w AS (...)` names a window definition so you don't repeat it.

### Top-N per group

A very frequent question is "the top 3 products in each category", not just the overall top 3. Because window functions keep every row, you can number rows within each partition and then keep only the low numbers in an outer query—something a plain `GROUP BY` or `LIMIT` cannot express per group.

```sql
SELECT * FROM (
    SELECT p.*, row_number() OVER (PARTITION BY category_id ORDER BY price DESC) AS rn
    FROM products p
) x
WHERE rn <= 3;      -- 3 most expensive products per category
```

## Running totals and frames

With `ORDER BY`, the default frame is "from the start of the partition to the current row (including peers)", which gives running totals:

```sql
WITH daily AS (
    SELECT created_at::date AS day, count(*) AS orders
    FROM orders GROUP BY 1
)
SELECT day, orders,
       sum(orders) OVER (ORDER BY day) AS running_total,
       avg(orders) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS moving_avg_7d
FROM daily ORDER BY day;
```

`ROWS BETWEEN ... AND ...` makes the frame explicit. Prefer `ROWS` over the default `RANGE` when you want exact row counts (and it avoids surprises with ties).

**Peers** are rows tied on the window's `ORDER BY` expressions. With the default `RANGE` frame, all peers enter the frame together. With `ROWS`, rows enter one physical result row at a time; add a unique tie-breaker to make that order deterministic.

## Looking at neighbours

Sometimes you only need the row just before or after the current one: yesterday's value, the previous order date, the next status. The two functions that do this are named after what they do:

- **`lag`** means "behind"—it reaches *back* to a **previous** row.
- **`lead`** means "ahead"—it reaches *forward* to a **later** row.

Both take an optional offset and a default: `lag(orders, 1, 0)` reads "one row back, and use `0` if there is no previous row". The defaults are offset `1` and `NULL`, so `lag(orders)` is the row immediately before, or `NULL` at the start of the partition.

```sql
SELECT day, orders,
       lag(orders)  OVER (ORDER BY day) AS prev_day,
       orders - lag(orders) OVER (ORDER BY day) AS change,
       lead(orders) OVER (ORDER BY day) AS next_day
FROM (SELECT created_at::date AS day, count(*) AS orders FROM orders GROUP BY 1) d;
```

Once you know these names, the rest of the family is easy to read:

- `first_value(col)` / `last_value(col)` — the first or last row **in the frame** (watch the frame: `last_value` often stops at the current row).
- `nth_value(col, n)` — the `n`th row in the frame.
- `ntile(n)` — splits the partition into `n` buckets and numbers them (e.g. quartiles with `ntile(4)`).
- `percent_rank()` — a row's rank scaled to `0`–`1`.
- `cume_dist()` — the cumulative distribution: the proportion of rows at or before the current row.

## Share of total

Often you want a row's value as a percentage of the whole—"what fraction of all orders came from this country?"

The tricky part is the denominator: you need the **grand total**, not the per-country count. A window function can give it to you, and the key is the empty `OVER ()`.

`OVER ()` means "no `PARTITION BY`, no `ORDER BY`". With no partition, the window is the **entire result set**—one single window covering every row. So whichever row you're on, the function sees all of them. Compare:

- `sum(x) OVER ()` — sum of `x` across **all** rows.
- `sum(x) OVER (PARTITION BY country)` — sum of `x` **within each country**.

Here is the calculation split into two steps so you can see what `OVER ()` produces:

```sql
SELECT c.country,
       count(*) AS orders,                 -- per country
       sum(count(*)) OVER () AS total      -- the same grand total on every row
FROM orders o JOIN customers c ON c.id = o.customer_id
GROUP BY c.country;
```

`count(*)` is an aggregate, so it is computed per country first. Then `sum(count(*)) OVER ()` adds those per-country counts together and places the grand total on every row. With both numbers available, the percentage is just a division:

```sql
SELECT c.country, count(*) AS orders,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM orders o JOIN customers c ON c.id = o.customer_id
GROUP BY c.country;
```

So yes, this is a window function over an aggregate: grouping happens first, then the window runs over the grouped rows.

## Common patterns

These recipes come up again and again in real work. Learn the shape of each one—once you recognise the pattern, adapting it to a new table is straightforward.

- **Deduplicate, keep the latest:** `row_number() OVER (PARTITION BY key ORDER BY updated_at DESC) = 1`.
- **Gaps and islands:** compare `value - row_number()` to group consecutive runs.
- **Sessionization:** `lag` the timestamp, flag gaps > 30 min, cumulative `sum` of flags.

## Exercises

1. For every product, show how its price compares to the most expensive product in its category (percentage of that max).
2. The cheapest 2 products in each category.
3. For each customer, their orders numbered by date (1 = first order) and the days since the previous order.
4. Cumulative revenue by month, with each month's percentage of the grand total.
5. Divide customers into 4 spend quartiles with `ntile(4)`.
6. Using `row_number`, identify duplicate customers by email (pretend the `UNIQUE` is not there): keep the newest. Then write a `DELETE ... WHERE id IN (SELECT ...)`. Why must referencing foreign keys be handled before deleting real customer rows?

??? note "Solutions"

    ```sql
    -- 1
    SELECT name, price, round(100 * price / max(price) OVER (PARTITION BY category_id), 1) AS pct_of_max FROM products;
    -- 2
    SELECT * FROM (SELECT p.*, row_number() OVER (PARTITION BY category_id ORDER BY price) rn FROM products p) x WHERE rn <= 2;
    -- 3
    SELECT id, customer_id, created_at,
           row_number() OVER w AS nth_order,
           created_at::date - lag(created_at::date) OVER w AS days_since_prev
    FROM orders WINDOW w AS (PARTITION BY customer_id ORDER BY created_at);
    -- 4
    WITH m AS (SELECT date_trunc('month', o.created_at) AS month, sum(oi.quantity*oi.unit_price) AS rev
               FROM orders o JOIN order_items oi ON oi.order_id = o.id GROUP BY 1)
    SELECT month, rev, sum(rev) OVER (ORDER BY month) AS cumulative,
           round(100 * rev / sum(rev) OVER (), 1) AS pct FROM m ORDER BY month;
    -- 5
    SELECT customer_id, total, ntile(4) OVER (ORDER BY total DESC) AS quartile FROM (
      SELECT o.customer_id, sum(oi.quantity*oi.unit_price) total FROM orders o JOIN order_items oi ON oi.order_id=o.id GROUP BY 1) t;
    -- 6
    DELETE FROM customers WHERE id IN (
      SELECT id FROM (
        SELECT id, row_number() OVER (PARTITION BY email ORDER BY created_at DESC, id DESC) rn
        FROM customers
      ) x WHERE rn > 1);
    -- In the sample schema this can fail when orders reference a duplicate customer.
    -- Real deduplication usually re-points child rows to the retained id in the same
    -- transaction before deleting duplicates.
    ```

Next: [11. Set Operations, Upsert and MERGE](11-sets-upsert-merge.md)
