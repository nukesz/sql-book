---
hide:
  - toc
---

# 3. Querying with SELECT

**You will learn:** projecting columns, filtering, sorting, paging, expressions, and the real order in which a query is evaluated.

## The basic shape

```sql
SELECT   column_list
FROM     table
WHERE    condition
ORDER BY sort_columns
LIMIT    n OFFSET m;
```

```sql
SELECT id, name, price FROM products;
SELECT * FROM products;               -- fine in psql, avoid in application code
SELECT name, price * 1.27 AS price_with_vat FROM products;
```

`AS` gives a column an alias. Avoid `SELECT *` in application code: it breaks when columns are added and fetches more than needed.

## Filtering with WHERE

```sql
SELECT * FROM products WHERE price > 400;
SELECT * FROM products WHERE price BETWEEN 100 AND 200;      -- inclusive
SELECT * FROM customers WHERE country IN ('HU', 'DE');
SELECT * FROM customers WHERE country <> 'US';
SELECT * FROM products WHERE price > 400 AND stock < 10;
SELECT * FROM orders WHERE status = 'new' OR status = 'paid';
```

Use parentheses when mixing `AND`/`OR`; `AND` binds tighter.

Date/time arithmetic uses an `interval`, a typed duration. For example, `now() - interval '7 days'` means the instant seven days ago. Chapter 7 explains time types in detail.

### Pattern matching

```sql
SELECT * FROM customers WHERE email LIKE 'user1%@example.com';  -- % any chars, _ one char
SELECT * FROM customers WHERE name ILIKE 'customer 1%';         -- case-insensitive (Postgres)
SELECT * FROM customers WHERE email ~ '^user[0-9]{3}@';         -- POSIX regex
```

## Sorting and paging

```sql
SELECT name, price FROM products ORDER BY price DESC, name ASC LIMIT 10;
SELECT name, price FROM products ORDER BY price DESC LIMIT 10 OFFSET 20;   -- page 3
```

`OFFSET` still has to walk past the skipped rows, so it gets slow for deep pages. Chapter 13 shows keyset pagination, the better pattern. Always add `ORDER BY` with `LIMIT`, or *which* rows you get is arbitrary.

## DISTINCT

```sql
SELECT DISTINCT country FROM customers;
SELECT DISTINCT ON (country) country, name, created_at     -- Postgres extension:
FROM customers ORDER BY country, created_at DESC;          -- newest customer per country
```

`DISTINCT` removes duplicate result rows after the selected expressions are computed. PostgreSQL's `DISTINCT ON (country)` keeps the **first** row in each country according to `ORDER BY`, so the ordering must start with the same expression. Add a unique tie-breaker when ties matter:

```sql
SELECT DISTINCT ON (country) country, name, created_at
FROM customers
ORDER BY country, created_at DESC, id DESC;
```

## Expressions and functions

```sql
SELECT upper(name), length(name), name || ' <' || email || '>' FROM customers LIMIT 3;
SELECT round(price, 0), ceil(price), floor(price) FROM products LIMIT 3;
SELECT CASE WHEN price < 50 THEN 'cheap'
            WHEN price < 250 THEN 'mid'
            ELSE 'premium' END AS tier, name
FROM products;
SELECT price::int, CAST(price AS text);        -- type casts, two spellings
SELECT coalesce(phone, 'n/a') FROM customers;  -- first non-NULL value
```

## Logical order of evaluation

You *write* `SELECT` first, but the database *logically* evaluates:

1. `FROM` (and joins)
2. `WHERE`
3. `GROUP BY`
4. `HAVING`
5. `SELECT` (compute expressions, aliases)
6. `DISTINCT`
7. `ORDER BY`
8. `LIMIT` / `OFFSET`

Consequences: you **cannot** use a `SELECT` alias in `WHERE` (it does not exist yet), but you can in `ORDER BY`. (The physical execution may differ; this is the logical contract.)

```sql
SELECT price * 2 AS double FROM products WHERE double > 100;   -- ERROR
SELECT price * 2 AS double FROM products WHERE price * 2 > 100 ORDER BY double;  -- OK
```

## Exercises

1. List the 5 most expensive products (name, price).
2. Find customers from Norway (`NO`) with no phone number. (Hint: chapter 7 explains why `= NULL` fails; try `IS NULL`.)
3. Products priced from 50 through 100, inclusive. Write it once with comparisons and once with `BETWEEN`.
4. Show each product's name and a `tier` (`cheap` < 100, `mid` < 300, else `premium`).
5. Orders created in the last 7 days that are not cancelled, newest first.
6. For each country, the most recently created customer (`DISTINCT ON`).
7. Why does this return an error? `SELECT price AS p FROM products WHERE p > 10;`

??? note "Solutions"

    ```sql
    -- 1
    SELECT name, price FROM products ORDER BY price DESC LIMIT 5;
    -- 2
    SELECT * FROM customers WHERE country = 'NO' AND phone IS NULL;
    -- 3
    SELECT name, price FROM products WHERE price >= 50 AND price <= 100;
    SELECT name, price FROM products WHERE price BETWEEN 50 AND 100;
    -- 4
    SELECT name, CASE WHEN price < 100 THEN 'cheap' WHEN price < 300 THEN 'mid' ELSE 'premium' END AS tier FROM products;
    -- 5
    SELECT * FROM orders WHERE created_at >= now() - interval '7 days' AND status <> 'cancelled' ORDER BY created_at DESC;
    -- 6
    SELECT DISTINCT ON (country) country, name, created_at FROM customers ORDER BY country, created_at DESC;
    -- 7  WHERE is evaluated before SELECT, so alias p does not exist yet.
    ```

Next: [4. Aggregation and Grouping](04-aggregation.md)
