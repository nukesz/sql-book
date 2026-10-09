---
hide:
  - toc
---

# 13. Indexes

**You will learn:** what an index is, which kinds PostgreSQL offers, how to design them for your queries, and their costs.

## The problem

```sql
SELECT * FROM orders WHERE customer_id = 123;
```

Without an index PostgreSQL does a **sequential scan**: reads the whole table (20,000 rows here, millions in real life) and checks each row. An **index** is a separate sorted structure that maps column values to row locations, like a book's index.

```sql
\timing on
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 123;   -- Seq Scan
CREATE INDEX orders_customer_id_idx ON orders (customer_id);
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 123;   -- Index Scan / Bitmap Scan
```

(Chapter 14 teaches how to read `EXPLAIN` output.)

## B-tree: the default

`CREATE INDEX` builds a B-tree, good for `=`, `<`, `<=`, `>`, `>=`, `BETWEEN`, `IN`, `ORDER BY`, `LIKE 'prefix%'` (with the right collation or `text_pattern_ops`), and `IS NULL`.

Primary keys and `UNIQUE` constraints automatically create a unique B-tree index. **Foreign keys do not**: index referencing columns yourself (`orders.customer_id`, `order_items.product_id`, ...).

### Multicolumn indexes

```sql
CREATE INDEX orders_cust_status_created_idx ON orders (customer_id, status, created_at);
```

Column **order matters**: the index is sorted by the first column, then the second within it, etc. It can serve queries that filter on a *leftmost prefix*: `(customer_id)`, `(customer_id, status)`, `(customer_id, status, created_at)`; but not efficiently `status` alone. Rule of thumb: equality columns first, then the range/sort column last.

### Sorting

```sql
CREATE INDEX orders_created_idx ON orders (created_at DESC);
-- serves: SELECT * FROM orders ORDER BY created_at DESC LIMIT 20;   (no sort step!)
```

### Keyset pagination (instead of OFFSET)

```sql
-- page 1
SELECT id, created_at FROM orders ORDER BY created_at DESC, id DESC LIMIT 20;
-- next page: pass the last row's values
SELECT id, created_at FROM orders
WHERE (created_at, id) < ('2025-06-01 10:00+00', 12345)
ORDER BY created_at DESC, id DESC LIMIT 20;
-- index: (created_at DESC, id DESC) -> constant time per page, however deep
```

### Covering indexes (index-only scans)

```sql
CREATE INDEX orders_cust_incl_idx ON orders (customer_id) INCLUDE (status, created_at);
-- This query can use an Index Only Scan:
-- SELECT status, created_at FROM orders WHERE customer_id = 5;
```

An index-only scan avoids most heap access only when the visibility map says a heap page is visible to every transaction. Recently changed pages may still require heap checks; vacuum maintains the visibility map (chapter 16).

### Partial indexes

Index only the rows you query:

```sql
CREATE INDEX orders_open_idx ON orders (created_at) WHERE status IN ('new', 'paid');
CREATE UNIQUE INDEX one_new_order_per_customer ON orders (customer_id) WHERE status = 'new';
```

Smaller, faster, and the second form enforces a business rule.

### Expression indexes

```sql
CREATE INDEX customers_lower_email_idx ON customers (lower(email));
-- serves: WHERE lower(email) = 'ada@example.com'   (the query must use the same expression)
```

A function applied to a column in `WHERE` normally *prevents* using a plain index on that column: `WHERE date(created_at) = '2025-01-01'` can't use an index on `created_at`; write `WHERE created_at >= '2025-01-01' AND created_at < '2025-01-02'`.

## Other index types

| Type | Good for |
|---|---|
| **B-tree** | default; equality, ranges, sorting |
| **Hash** | equality only (rarely better than B-tree) |
| **GIN** | "contains" on composite values: `jsonb`, arrays, full-text search, `pg_trgm` |
| **GiST** | geometric/range types, nearest-neighbour, exclusion constraints |
| **SP-GiST** | partitioned search spaces (phone prefixes, IPs) |
| **BRIN** | huge append-only tables where values correlate with physical order (timestamps); tiny index |

```sql
CREATE INDEX products_tags_gin ON products USING gin (tags);        -- WHERE tags @> ARRAY['sale']
CREATE INDEX products_attrs_gin ON products USING gin (attributes); -- WHERE attributes @> '{"color":"red"}'
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX customers_name_trgm ON customers USING gin (name gin_trgm_ops);  -- WHERE name ILIKE '%son%'
```

## The costs

Indexes are not free:

- every `INSERT`/`UPDATE`/`DELETE` must maintain every index;
- they use disk and memory;
- more indexes → slower writes and slower vacuum.

Index for the queries you really run. Find unused ones:

```sql
SELECT relname, indexrelname, idx_scan FROM pg_stat_user_indexes ORDER BY idx_scan;
```

## Creating indexes in production

```sql
CREATE INDEX CONCURRENTLY orders_x ON orders (...);   -- doesn't block writes; slower; can't be in a transaction block
DROP INDEX CONCURRENTLY orders_x;
REINDEX INDEX CONCURRENTLY orders_x;
```

If `CONCURRENTLY` fails it leaves an `INVALID` index; drop it and retry.

## When the planner ignores your index

- The table is small, or the predicate matches a large fraction of rows (a seq scan is cheaper). Not a bug.
- Statistics are stale: `ANALYZE orders;`
- Type mismatch or function on the column (see above).
- Leading-column mismatch in a multicolumn index.
- `LIKE '%x%'` (leading wildcard): use trigram GIN.

## Exercises

1. Time `SELECT * FROM order_items WHERE product_id = 7` with and without an index on `product_id`. (Use `EXPLAIN ANALYZE`; compare "Execution Time".)
2. Create an index so `SELECT * FROM customers WHERE lower(email) = 'user10@example.com'` is fast.
3. Which index would you create for: `WHERE customer_id = ? AND status = 'paid' ORDER BY created_at DESC LIMIT 10`? Verify the plan has no `Sort` node.
4. Implement keyset pagination of `products` ordered by `(price, id)`. Fetch two pages.
5. Add a trigram index and query `WHERE name ILIKE '%mer 99%'`. Compare plans before/after.
6. List all indexes on `orders` with `\d orders`. Which ones are redundant (a prefix of another)?
7. Why is an index on a boolean column with 50/50 values usually useless? When would a *partial* index on it be great?

??? note "Solutions"

    ```sql
    -- 2
    CREATE INDEX customers_lower_email_idx ON customers (lower(email));
    -- 3
    CREATE INDEX orders_cust_status_created ON orders (customer_id, status, created_at DESC);
    -- 4
    SELECT id, price FROM products ORDER BY price, id LIMIT 10;
    SELECT id, price FROM products WHERE (price, id) > (<last_price>, <last_id>) ORDER BY price, id LIMIT 10;
    -- 6  An index on (customer_id) may be redundant if (customer_id, status, created_at) exists,
    --    but verify workload and plans before dropping it: the smaller index can still be cheaper to scan and cache.
    -- 7  Half the table matches: scanning the index + table is worse than a seq scan. A partial index shines when a rare value
    --    (e.g. status = 'new', 1% of rows) is queried often.
    ```

Next: [14. Reading Query Plans](14-explain.md)
