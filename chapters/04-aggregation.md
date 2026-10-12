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

Other useful ones: `string_agg(name, ', ')` joins text values, `array_agg(x)` collects values into an array, and `bool_or(x)` is true when any input is true.

The **median** (the middle value when sorted) is not a plain aggregate like `avg`. PostgreSQL has a special syntax for it, `percentile_cont`, called an **ordered-set aggregate**: you tell it *which* percentile you want (0.5 = the 50th, i.e. the median) and *how to sort* the values.

```sql
SELECT avg(price)                                       AS average,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY price) AS median
FROM products;
```

If the number of values is even, it interpolates between the two middle ones.

Why the odd syntax? Normal aggregates such as `avg(price)` or `max(price)` give the same result no matter what order the rows arrive in. A median does not: it is "the value in the middle", which only exists once the values are sorted. So the call is split in two parts:

```sql
percentile_cont(0.5) WITHIN GROUP (ORDER BY price)
--              ^^^                      ^^^^^
--  which percentile (0 to 1)     which column, sorted how
```

- The argument in `percentile_cont(...)` is **not** a column but a fraction: `0.5` is the median, `0.9` the 90th percentile.
- `WITHIN GROUP (ORDER BY ...)` holds the column and the sort order. It is required.

Only a few functions work this way: `percentile_cont` (interpolates between values), `percentile_disc` (returns an actual value from the data) and `mode()` (the most frequent value).

Don't confuse it with `string_agg(name, ', ' ORDER BY name)`: that is a normal aggregate with an optional `ORDER BY` that only controls the order of the joined text.

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
SELECT count(*)                                     AS all_orders,
       count(*) FILTER (WHERE status = 'cancelled') AS cancelled,
       round(100.0 * count(*) FILTER (WHERE status = 'cancelled') / count(*), 1) AS pct_cancelled
FROM orders;
```

This "pivot" trick (many conditional counts in one scan) is hugely useful for reports.

## ROLLUP / GROUPING SETS

A report often wants totals at several levels at once. Say you count orders per status and month, but you also want a total for each status and one overall total. A plain `GROUP BY` gives only the most detailed level. `ROLLUP` adds the extra total rows for you, in the same query.

```sql
SELECT status,
       date_trunc('month', created_at) AS month,
       count(*) AS orders
FROM orders
GROUP BY ROLLUP (status, date_trunc('month', created_at))
ORDER BY status, month;
```

This is the same query as the two-column `GROUP BY` example above, with `ROLLUP (...)` around the grouping columns. The result looks like this (numbers are made up; `month` is the first day of the month, as `date_trunc` returns it):

```text
  status   |         month          | orders
-----------+------------------------+--------
 cancelled | 2025-10-01 00:00:00+00 |    214
 cancelled | 2025-11-01 00:00:00+00 |    245
 cancelled |                        |    459
 paid      | 2025-10-01 00:00:00+00 |   1310
 paid      | 2025-11-01 00:00:00+00 |   1275
 paid      |                        |   2585
           |                        |   3044
```

In `psql`, `NULL` is shown as an empty cell.

There are three kinds of rows:

- **Detail rows** (status and month filled in): the normal `GROUP BY` result.
- **Subtotal rows** (status filled in, month `NULL`): all months of that status added together.
- **Grand total row** (both `NULL`): everything.

`NULL` here means "all values". `ROLLUP (a, b)` works from the right: it groups by `(a, b)`, then by `(a)`, then by nothing at all.

**Caution:** a `NULL` in these columns can also be real data if the column allows `NULL` (like `phone` in `customers`). To tell the two apart, use `GROUPING(month)`, which returns `1` when the `NULL` is a subtotal marker and `0` when it comes from a row.

`GROUPING SETS` is the general form: instead of the fixed "drop from the right" pattern, you list exactly which groupings you want. You will rarely need it at first.

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
    -- 7  No rows match -> the sum of nothing is NULL, not 0.
    SELECT coalesce(sum(stock), 0) FROM products WHERE price > 10000;
    ```

Next: [5. Joins](05-joins.md)
