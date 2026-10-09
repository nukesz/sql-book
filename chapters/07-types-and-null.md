---
hide:
  - toc
---

# 7. Data Types and NULL

**You will learn:** which PostgreSQL types to choose, and how to think about `NULL` without being bitten.

## Choosing types

| Need | Use | Avoid |
|---|---|---|
| Whole numbers | `integer`, `bigint` (ids, counters), `smallint` | |
| Money / exact decimals | `numeric(p,s)` | `real`/`double precision` (binary floating point: `0.1 + 0.2 <> 0.3`) |
| Text | `text` (no performance penalty vs `varchar(n)`) | `char(n)` (space padded) |
| True/false | `boolean` | `int` flags |
| Date only | `date` | |
| Moment in time | `timestamptz` | `timestamp` (no zone) for events |
| Durations | `interval` | |
| Unique ids | `uuid` | |
| Structured/flexible | `jsonb` (chapter 15) | `json` (keeps text, slower) |
| Lists | arrays, `text[]` | comma-joined strings |
| Fixed set of values | `CHECK (x IN (...))` or `enum` | |

Money: store `numeric(12,2)`, or integer minor units (cents) plus a currency code. Never float.

### Floating point demonstration

```sql
SELECT 0.1::float8 + 0.2::float8 = 0.3::float8 AS float_equal,   -- false
       0.1::numeric + 0.2::numeric = 0.3::numeric AS numeric_equal; -- true
```

### Time zones: `timestamptz`

`timestamptz` stores an absolute instant (internally UTC) and displays it in the session `TimeZone`. `timestamp` stores a wall-clock reading with no zone. For "when did it happen", use `timestamptz`.

```sql
SHOW timezone;
SELECT now(), now() AT TIME ZONE 'Asia/Tokyo';
SET timezone = 'America/New_York';
SELECT now();
RESET timezone;
```

### Integer pitfalls

```sql
SELECT 7 / 2;            -- 3   (integer division)
SELECT 7 / 2.0;          -- 3.5
SELECT 7 % 2;            -- 1
SELECT 2147483647 + 1;   -- ERROR: integer out of range  (use bigint for growing counters)
```

### Strings

```sql
SELECT 'it''s';                       -- escape a quote by doubling it
SELECT 'abc' || 'def', length('héllo'), substring('postgres' from 1 for 4);
SELECT lower('ABC'), trim('  x  '), replace('a-b', '-', '_'), split_part('a,b,c', ',', 2);
```

Comparisons and sorting depend on the **collation**; `ORDER BY name` may sort differently on different servers.

## NULL

`NULL` means **unknown / missing**, not zero, not empty string.

### Three-valued logic

Any comparison with `NULL` yields `NULL` (unknown), and `WHERE` keeps only rows where the condition is **true**.

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
