---
hide:
  - toc
---

# 4. Aggregation and Grouping

**You will learn:** summarizing many rows into few, `GROUP BY`, `HAVING`, and `FILTER`.

## Aggregate functions

Until now, every query returned individual rows. But most real questions are about the data as a whole: *How many customers do we have? What is the average price? What is the most expensive product?* Nobody wants to scroll through a million rows to answer those. An **aggregate function** reads many rows and **collapses them into a single value**, so the database does the arithmetic and you only receive the answer.

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

A plain aggregate gives you one answer for the *whole table*. Often you want one answer *per category*: customers **per country**, revenue **per month**, orders **per status**. `GROUP BY` does exactly that: it splits the rows into buckets, one bucket per distinct value of the grouping column(s), and then runs the aggregate separately inside each bucket. The result has one row per group.

Think of it as "for each country, count the customers". Whenever a question contains "per", "by" or "for each", you probably need `GROUP BY`.

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

Sometimes you need to filter, but there are two different things you might want to filter: the **input rows** ("only orders from the last year") or the **results of the aggregation** ("only countries with more than 50 customers"). The second is impossible with `WHERE`, because the count does not exist yet when `WHERE` runs. That is the reason `HAVING` exists.

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

Sometimes one report needs several numbers that each count a *different subset* of the same rows: all orders, cancelled orders, and the percentage between them. Without `FILTER` you would write a separate query per subset (and scan the table several times), or use awkward `CASE` tricks. `FILTER (WHERE ...)` attaches a condition to a single aggregate, so that aggregate only sees the matching rows while the others still see everything. One query, one pass over the data, many different numbers.

```sql
SELECT count(*)                                   AS all_orders,
       count(*) FILTER (WHERE status = 'cancelled') AS cancelled,
       round(100.0 * count(*) FILTER (WHERE status = 'cancelled') / count(*), 1) AS pct_cancelled
FROM orders;
```

This "pivot" trick (many conditional counts in one scan) is hugely useful for reports.

## ROLLUP / GROUPING SETS

Reports usually need more than one level of detail at once: the count per country *and status*, plus a subtotal per country, plus a grand total. With plain `GROUP BY` that means running several queries and gluing them together with `UNION ALL`. `ROLLUP` produces all of those levels in one query: it groups by the full column list, then drops columns from the right one at a time to create subtotals, ending with a grand total. `GROUPING SETS` is the general form, where you list exactly which combinations of groupings you want.

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
