---
hide:
  - toc
---

# 10. Window Functions

**You will learn:** computing across related rows *without collapsing them*: rankings, running totals, comparisons with previous rows, top-N per group.

## The idea

`GROUP BY` collapses rows. A window function keeps every row and adds a computed column based on a "window" of related rows.

```sql
SELECT name, category_id, price,
       avg(price) OVER (PARTITION BY category_id) AS category_avg,
       price - avg(price) OVER (PARTITION BY category_id) AS diff
FROM products;
```

Syntax: `function(...) OVER ([PARTITION BY cols] [ORDER BY cols] [frame])`.

- `PARTITION BY` splits rows into groups (like `GROUP BY`, but rows are kept).
- `ORDER BY` inside `OVER` orders rows within each partition.
- Window functions run **after** `WHERE`/`GROUP BY`/`HAVING`, so you cannot filter on them directly; wrap in a subquery/CTE.

## Ranking

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

```sql
SELECT day, orders,
       lag(orders)  OVER (ORDER BY day) AS prev_day,
       orders - lag(orders) OVER (ORDER BY day) AS change,
       lead(orders) OVER (ORDER BY day) AS next_day
FROM (SELECT created_at::date AS day, count(*) AS orders FROM orders GROUP BY 1) d;
```

Also: `first_value`, `last_value` (mind the frame!), `nth_value`, `ntile(n)` (buckets, e.g. quartiles), `percent_rank`, `cume_dist`.

## Share of total

```sql
SELECT c.country, count(*) AS orders,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM orders o JOIN customers c ON c.id = o.customer_id
GROUP BY c.country;
```

Yes, a window function over an aggregate: grouping happens first, then the window runs over grouped rows.

## Common patterns

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
