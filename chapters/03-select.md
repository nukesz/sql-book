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

### Comparison operators

| Operator | Meaning | Example |
|---|---|---|
| `=` | equal to (exact match) | `WHERE status = 'paid'` |
| `<>` (or `!=`) | not equal | `WHERE country <> 'US'` |
| `<`, `<=`, `>`, `>=` | less/greater than | `WHERE price >= 400` |
| `BETWEEN a AND b` | in a range, inclusive on both ends | `WHERE price BETWEEN 100 AND 200` |
| `IN (...)` | equal to any value in a list | `WHERE country IN ('HU', 'DE')` |
| `IS NULL` / `IS NOT NULL` | missing value check | `WHERE phone IS NULL` |

- Strings use single quotes: `'paid'`. Double quotes denote an identifier (a column or table name).
- `=` on strings is case-sensitive in Postgres: `'Paid'` does not equal `'paid'`.
- `NULL` means "unknown", so `= NULL` never matches anything. Use `IS NULL` (chapter 7 explains why).
- `IN (...)` is shorthand for several `OR`s: `country = 'HU' OR country = 'DE'`.

### Combining conditions

`AND` requires both conditions, `OR` requires either, and `NOT` negates one (`WHERE NOT (price > 400)`).

`AND` binds tighter than `OR`, so use parentheses when mixing them:

```sql
WHERE status = 'new' OR status = 'paid' AND total > 100     -- new (any total), or paid with total > 100
WHERE (status = 'new' OR status = 'paid') AND total > 100   -- probably what you meant
```

Date/time arithmetic uses an `interval`, a typed duration. For example, `now() - interval '7 days'` means the instant seven days ago. Chapter 7 explains time types in detail.

### Pattern matching

Use `=` for an exact match and `LIKE` for a pattern:

```sql
WHERE email = 'user1@example.com'      -- exact: only this one value
WHERE email LIKE 'user1%@example.com'  -- pattern: user1@..., user10@..., user123@...
```

`LIKE` has two wildcards: `%` matches any number of characters (including none), `_` matches exactly one.

| Pattern | Matches |
|---|---|
| `'abc%'` | starts with `abc` |
| `'%abc'` | ends with `abc` |
| `'%abc%'` | contains `abc` |
| `'a_c'` | `abc`, `a1c`, but not `ac` or `abbc` |

`NOT LIKE` negates, `ILIKE` ignores case (Postgres only), and `~` / `~*` match a POSIX regex (case-sensitive / insensitive).

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
SELECT price::int, CAST(price AS text) FROM products; -- type casts, two spellings
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
