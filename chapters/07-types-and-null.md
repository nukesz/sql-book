---
hide:
  - toc
---

# 7. Data Types and NULL

**You will learn:** which PostgreSQL types to choose, and how to think about `NULL` without being bitten.

## Why the type matters

Beyond the usual guarantees, the type decides which operators and functions a column gets: dates subtract into days, `timestamptz` knows the instant, arrays can be searched element by element, `jsonb` can be indexed by key. Keep the same data in `text` and you get string comparison, which sorts `'10'` before `'9'`.

It is also the hardest decision to revisit: changing a type means an `ALTER TABLE` that rewrites the table under a strong lock.

## Numbers

Whole numbers are `integer`, `bigint` for anything that keeps growing, `smallint` where the range is genuinely small. Exact decimals are `numeric`. `real` and `double precision` are binary floating point: good for measurements, never for money.

```sql
-- counts and ids: the integer family
SELECT count(*) FROM orders;
SELECT id, stock FROM products WHERE stock < 5;

-- money: numeric arithmetic stays exact
SELECT name, price, round(price * 1.27, 2) AS gross FROM products LIMIT 5;

-- measurements: float is fine, and fast
SELECT sqrt(2::float8), pi();
```

`numeric(p,s)` is `p` digits with `s` after the decimal point, so `numeric(10,2)` holds up to 99999999.99 and rounds the rest. Plain `numeric` takes whatever you give it. For money use `numeric(12,2)`, or integer cents plus a currency code.

Two behaviours to know: integer division truncates, and overflow is an error rather than a wrap-around.

```sql
SELECT 7 / 2;            -- 3   (integer division)
SELECT 7 / 2.0;          -- 3.5 (2.0 is numeric, so the result is numeric)
SELECT 2147483647 + 1;   -- ERROR: integer out of range

-- why money is never a float
SELECT 0.1::float8 + 0.2::float8 = 0.3::float8 AS float_equal,       -- false
       0.1::numeric + 0.2::numeric = 0.3::numeric AS numeric_equal;  -- true
```

## Text

Use `text` for every string. `varchar(n)` performs identically and only adds a limit to regret later; `char(n)` pads with spaces. A length that is a real business rule belongs in a `CHECK`, where it can be changed.

```sql
-- the everyday functions
SELECT name, length(name), upper(country) FROM customers LIMIT 3;
SELECT name || ' <' || email || '>' AS contact FROM customers LIMIT 3;

-- splitting a column apart in the query
SELECT split_part(email, '@', 2) AS domain, count(*) FROM customers GROUP BY 1 ORDER BY 2 DESC;
```

Literals use single quotes, and a quote inside one is doubled: `'it''s'`. Positions start at 1, as in `substring('postgres' from 1 for 4)`. Comparison and sorting follow the **collation**, so `ORDER BY name` can differ between servers.

## Boolean

`boolean` holds true, false or `NULL`. A boolean column or expression is already a condition, so `WHERE active` needs no `= true`.

```sql
SELECT name, stock > 0 AS in_stock FROM products LIMIT 5;
SELECT bool_or(stock = 0) AS anything_sold_out FROM products;
SELECT count(*) FILTER (WHERE price > 100) AS expensive FROM products;
```

Prefer it to `int` flags or `'Y'`/`'N'` columns, which need a `CHECK` to mean as much.

## Dates and times

`date` is a calendar day, `timestamptz` an absolute instant, `interval` a duration. Despite the name, `timestamptz` stores no zone: it keeps the instant (internally UTC) and renders it in the session's zone. Plain `timestamp` is a wall-clock reading that means a different instant to every reader, so keep it for genuinely zone-free values such as opening hours.

```sql
-- recent activity
SELECT id, created_at FROM orders WHERE created_at >= now() - interval '7 days';

-- a report per month
SELECT date_trunc('month', created_at) AS month, count(*)
FROM orders GROUP BY 1 ORDER BY 1;

-- whole days
SELECT current_date, current_date + 30 AS due_date;

-- the same instant, rendered in another zone
SHOW timezone;
SELECT now(), now() AT TIME ZONE 'Asia/Tokyo';
```

Adding an `interval` to a `timestamptz` does calendar arithmetic, daylight saving included.

## uuid

A 16-byte identifier that can be generated anywhere, including in the client before the row is inserted. Reach for it when ids must be unguessable or unique across several systems; otherwise `bigint` identity stays the better default, because sequential keys keep indexes smaller and faster.

```sql
SELECT gen_random_uuid();
```

## A fixed set of values

Either a `text` column with a `CHECK`, as `orders.status` does, or a dedicated `enum` type:

```sql
INSERT INTO orders (customer_id, status) VALUES (1, 'paid');

INSERT INTO orders (customer_id, status) VALUES (1, 'payed');
-- ERROR: new row for relation "orders" violates check constraint "orders_status_check"
```

The `CHECK` is visible in `\d orders` and changed with an `ALTER TABLE`. An `enum` sorts in declaration order and reads a little cleaner, but adding a value means `ALTER TYPE ... ADD VALUE` and removing one is awkward. For a list that may change, the `CHECK` is the easier life.

## jsonb and arrays

Use `jsonb` when the fields differ from row to row and a column each would be mostly `NULL`. Use an array when a row holds a list of the same kind of value. Both are real types with their own operators and indexes, which a comma-separated string is not. Chapter 15 covers them properly.

```sql
-- one key out of a jsonb document
SELECT name, attributes->>'color' AS color FROM products LIMIT 5;

-- rows whose tag list contains 'sale'
SELECT name FROM products WHERE 'sale' = ANY(tags);
```

## Casting

PostgreSQL converts on its own when nothing is lost — mixing `integer` with `numeric` promotes the expression to `numeric`, as in `7 / 2.0` above. Anything else you ask for explicitly, with `::` or the standard `CAST(... AS ...)`; the two spellings are the same thing.

```sql
-- two spellings of the same explicit cast
SELECT price::int, CAST(price AS text) FROM products LIMIT 1;

-- a quoted literal becomes whatever type you cast it to, which is also how you parse
SELECT '2026-01-01'::date + 7, '3 days'::interval;

-- numeric to integer rounds, it does not truncate
SELECT 19.90::int;       -- 20

-- a cast that cannot work fails loudly
SELECT 'abc'::int;       -- ERROR: invalid input syntax for type integer: "abc"
```

A cast either converts exactly, converts by a stated rule such as rounding, or fails. It never hands back a zero for input it could not read.

## Putting it together

The `products` table from `data/01-schema.sql` uses most of the above:

```sql
CREATE TABLE products (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- ids only ever grow
    category_id int NOT NULL REFERENCES categories (id),          -- same type as categories.id
    name        text NOT NULL,                                    -- no length limit to regret later
    price       numeric(10,2) NOT NULL CHECK (price >= 0),        -- exact, two decimal places
    stock       int NOT NULL DEFAULT 0 CHECK (stock >= 0),
    attributes  jsonb NOT NULL DEFAULT '{}',                      -- per-category extras (chapter 15)
    tags        text[] NOT NULL DEFAULT '{}'                      -- a real list, not 'a,b,c'
);
```

`id` is `bigint` but `category_id` is `int`: a foreign key takes the type of the column it references, and there will not be two billion categories. Both `attributes` and `tags` default to an empty value and are `NOT NULL`, so no query has to tell "no tags" from "unknown tags". In `customers` the opposite choice is made for `phone text`, which is nullable on purpose — the rest of this chapter is about that difference.

## NULL

`NULL` means **unknown / missing**, not zero, not empty string.

Being unknown, it is equal to nothing — not even to another `NULL` — and it spreads through nearly every expression it enters.

### Three-valued logic

Conditions have three outcomes, not two: true, false, unknown. Any comparison with `NULL` yields unknown, and `WHERE` keeps a row only when the condition is **true**. So unknown acts like false in a filter, except that `NOT unknown` is still unknown.

```sql
SELECT NULL = NULL;           -- NULL   (not true!)
SELECT NULL <> 1;             -- NULL
SELECT NULL IS NULL;          -- true
SELECT 1 IS DISTINCT FROM NULL;      -- true  (null-safe inequality)
SELECT NULL IS NOT DISTINCT FROM NULL;  -- true  (null-safe equality)

SELECT true  AND NULL;   -- NULL
SELECT false AND NULL;   -- false
SELECT true  OR  NULL;   -- true
SELECT NOT NULL::boolean; -- NULL
```

### Traps

Both of these follow from that rule. Both read as correct, return the wrong rows, and raise no error.

```sql
-- customers with phone NOT equal to '+36100000001': silently excludes NULL phones!
SELECT count(*) FROM customers WHERE phone <> '+36100000001';
SELECT count(*) FROM customers WHERE phone IS DISTINCT FROM '+36100000001';   -- includes them

-- NOT IN with a NULL in the list returns nothing:
SELECT 1 WHERE 1 NOT IN (2, NULL);       -- zero rows!
-- Use NOT EXISTS instead of NOT IN with subqueries that may contain NULL.
```

Other NULL facts:

- Arithmetic with NULL gives NULL: `price + NULL` is NULL.
- Aggregates ignore NULLs (except `count(*)`).
- `ORDER BY` puts NULLs last in ascending order (`NULLS FIRST`/`NULLS LAST` to control it).
- `UNIQUE` allows multiple NULLs (use `UNIQUE NULLS NOT DISTINCT` in PG 15+ to change that).
- `coalesce(a, b, ...)` returns the first non-NULL; `nullif(a, b)` returns NULL when `a = b` (handy to avoid division by zero: `x / nullif(y, 0)`).

### Design rule

Make columns `NOT NULL` unless "unknown" is a genuine state. Fewer NULLs means fewer surprises.

## Exercises

1. Why does `SELECT count(*) FROM customers WHERE phone = NULL;` return 0?
2. How many customers have a phone, and how many do not? Check that the two add up to the total.
3. Compute `1/3` as an integer, as a float, and as a `numeric(10,4)`.
4. Show the current time in Tokyo and in UTC.
5. What does `SELECT * FROM products WHERE tags <> '{}'` do for rows where `tags` is NULL? (Our schema forbids NULL tags; why is that good?)
6. Safely compute `revenue / orders` per country where `orders` may be 0.
7. Predict then run: `SELECT 5 NOT IN (1, 2, NULL);`

??? note "Solutions"

    ```sql
    -- 1  = NULL is never true; use IS NULL.
    -- 2
    SELECT count(*) FILTER (WHERE phone IS NOT NULL), count(*) FILTER (WHERE phone IS NULL), count(*) FROM customers;
    -- 3
    SELECT 1/3, 1/3.0::float8, round(1/3.0, 4);
    -- 4
    SELECT now() AT TIME ZONE 'Asia/Tokyo', now() AT TIME ZONE 'UTC';
    -- 6  revenue / nullif(orders, 0)
    -- 7  NULL (unknown), so a WHERE using it matches no rows.
    ```

Next: [8. Constraints and DDL](08-ddl-constraints.md)
