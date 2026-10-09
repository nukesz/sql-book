---
hide:
  - toc
---

# 4. Aggregation and Grouping

**You will learn:** summarizing many rows into few, `GROUP BY`, `HAVING`, and `FILTER`.

## Aggregate functions

An aggregate collapses many rows into one value.

```sql
SELECT count(*)            AS rows,
       count(phone)        AS with_phone,      -- count(col) skips NULLs!
       count(DISTINCT country) AS countries
FROM customers;

SELECT min(price), max(price), avg(price), sum(stock) FROM products;
```

`count(*)` counts rows; `count(col)` counts non-NULL values. `sum`/`avg` over zero rows return `NULL` (not 0), so use `coalesce(sum(x), 0)`.

Other useful ones: `string_agg(name, ', ')` joins text values, `array_agg(x)` collects values into an array, and `bool_or(x)` is true when any input is true. `percentile_cont(0.5) WITHIN GROUP (ORDER BY price)` is an **ordered-set aggregate**: it sorts the values and finds the continuous 50th percentile (the median, interpolating when necessary).

## GROUP BY

```sql
SELECT country, count(*) AS customers
FROM customers
GROUP BY country
ORDER BY customers DESC;
```

**Practical rule:** every selected expression must either identify the group (appear in `GROUP BY`) or summarize the group (use an aggregate). This is invalid:

```sql
SELECT country, name, count(*) FROM customers GROUP BY country;  -- which name?
```

PostgreSQL has a limited exception when it can prove functional dependency from a grouped primary key, but writing the full grouping rule explicitly is clearer while learning and more portable.

Group by several columns, or by expressions:

```sql
SELECT status, date_trunc('month', created_at) AS month, count(*)
FROM orders
GROUP BY status, date_trunc('month', created_at)
ORDER BY month, status;
-- shorthand: GROUP BY 1, 2   (positional)
```

## WHERE vs HAVING

`WHERE` filters rows *before* grouping; `HAVING` filters groups *after* aggregation.

```sql
SELECT country, count(*) AS n
FROM customers
WHERE created_at > now() - interval '1 year'   -- rows
GROUP BY country
HAVING count(*) > 50;                          -- groups
```

Put as much as possible in `WHERE`: it reduces work earlier.

## FILTER: conditional aggregation

```sql
SELECT count(*)                                   AS all_orders,
       count(*) FILTER (WHERE status = 'cancelled') AS cancelled,
       round(100.0 * count(*) FILTER (WHERE status = 'cancelled') / count(*), 1) AS pct_cancelled
FROM orders;
```

This "pivot" trick (many conditional counts in one scan) is hugely useful for reports.

## ROLLUP / GROUPING SETS

```sql
SELECT country, status, count(*)
FROM customers c JOIN orders o ON o.customer_id = c.id
GROUP BY ROLLUP (country, status);   -- adds subtotals per country and a grand total (NULL = "all")
```

Be careful: a `NULL` in a rollup column can mean either "all values" or a real `NULL` from the data. `GROUPING(country)` and `GROUPING(status)` return `1` for subtotal columns and `0` for values originating in rows.

## Exercises

1. How many products are in stock (`stock > 0`)? What is their average price?
2. Number of orders per status.
3. Monthly order count for the last 6 months.
4. Which countries have more than 150 customers?
5. For each country, the share (percentage) of customers without a phone, using `FILTER`.
6. Median product price (`percentile_cont`).
7. (Think) Why does `SELECT sum(stock) FROM products WHERE price > 10000;` return `NULL` and how do you get `0`?

??? note "Solutions"

    ```sql
    -- 1
    SELECT count(*), avg(price) FROM products WHERE stock > 0;
    -- 2
    SELECT status, count(*) FROM orders GROUP BY status;
    -- 3
    SELECT date_trunc('month', created_at) AS month, count(*)
    FROM orders WHERE created_at >= date_trunc('month', now()) - interval '5 months'
    GROUP BY 1 ORDER BY 1;
    -- 4
    SELECT country, count(*) FROM customers GROUP BY country HAVING count(*) > 150;
    -- 5
    SELECT country, round(100.0 * count(*) FILTER (WHERE phone IS NULL) / count(*), 1) AS pct_no_phone
    FROM customers GROUP BY country;
    -- 6
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY price) FROM products;
    -- 7  No rows -> sum of nothing is NULL. Use coalesce(sum(stock), 0).
    ```

Next: [5. Joins](05-joins.md)
