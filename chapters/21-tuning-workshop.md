---
hide:
  - toc
---

# 21. Performance Tuning Workshop

**You will learn:** a repeatable method for finding and fixing slow queries, and the classic anti-patterns.

## The method

1. **Measure, don't guess.** Find what is actually slow/expensive.
2. **Look at the plan** (`EXPLAIN (ANALYZE, BUFFERS)`).
3. **Change one thing** (index, rewrite, statistics, config) and re-measure.
4. **Verify** the improvement under realistic data volume and concurrency.

### Find the worst queries

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;      -- needs shared_preload_libraries = 'pg_stat_statements' + restart
SELECT calls, round(total_exec_time) AS total_ms, round(mean_exec_time::numeric, 2) AS mean_ms, rows, left(query, 80)
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
```

Sort by *total* time first: a 5 ms query called a million times beats a 5 s query run twice a day. Also useful: `log_min_duration_statement = 250` logs anything slower than 250 ms.

(With the compose file, enable it with `command: postgres -c shared_preload_libraries=pg_stat_statements`.)

## Make the dataset realistic

Tiny tables hide problems. Scale up a copy for experimentation:

```sql
INSERT INTO orders (customer_id, status, created_at)
SELECT 1 + floor(random() * 1000)::int, 'shipped', now() - make_interval(days => floor(random() * 365)::int)
FROM generate_series(1, 2000000);
ANALYZE orders;
```

## Anti-patterns and fixes

### 1. Functions on indexed columns

```sql
WHERE date(created_at) = '2026-01-15'              -- no index use
WHERE created_at >= '2026-01-15' AND created_at < '2026-01-16'   -- index-friendly
```

### 2. Leading wildcard / case-insensitive search

`WHERE email ILIKE '%foo%'` → `pg_trgm` GIN index; or `lower(email)` expression index for exact match.

### 3. Implicit casts

`WHERE varchar_col = 123` or comparing `bigint` to `numeric` can disable an index. Match types, and watch parameter types sent by drivers.

### 4. OFFSET pagination

Use keyset pagination (chapter 13).

### 5. N+1 queries

Application loops: one query for 100 orders, then 100 queries for their items. Each is cheap, the total (round trips!) is not. Fix with a join, `WHERE order_id = ANY($1)`, or `jsonb_agg` shaping (chapter 15).

### 6. `SELECT *` and wide rows

More I/O and kills index-only scans. Select needed columns.

### 7. `OR` across different columns

`WHERE a = 1 OR b = 2` may force a seq scan; try `UNION ALL` of two indexed queries, or a bitmap-OR (the planner may do it by itself with indexes on both).

### 8. `COUNT(*)` for pagination totals

Exact counts on big tables scan. Options: skip the total, cap it (`SELECT count(*) FROM (SELECT 1 FROM t WHERE ... LIMIT 1001) x`), or approximate.

### 9. `NOT IN (subquery)` and correlated subqueries over big sets

Use `NOT EXISTS` / joins (chapters 7, 9).

### 10. Missing FK indexes

Deletes in the parent table (and joins) scan the child table. Index every foreign key column you join or delete on.

### 11. Huge `IN (...)` lists / too many round trips

Send an array parameter: `WHERE id = ANY($1::bigint[])`, or load ids into a temp table and join.

### 12. One row at a time inserts

Batch with multi-row `INSERT`, `COPY`, or driver batching. Wrap batches in one transaction.

### 13. Over-indexing

Every index slows writes (chapter 13). Remove unused ones (`pg_stat_user_indexes.idx_scan = 0` over a long period).

### 14. Transaction scope too big

Long transactions → lock waits, bloat (chapters 16-17).

## Configuration basics

Defaults are conservative. Common starting points (tune to your hardware):

| Setting | Idea |
|---|---|
| `shared_buffers` | ~25% of RAM |
| `effective_cache_size` | ~50-75% of RAM (planner hint, not an allocation) |
| `work_mem` | per sort/hash **per node per query**: 4-64 MB; beware concurrency × nodes |
| `maintenance_work_mem` | 256 MB-1 GB for index builds/vacuum |
| `random_page_cost` | 1.1 on SSDs (default 4 assumes spinning disks) |
| `max_connections` | keep modest; use a pooler (PgBouncer / app pool) |

Change with `ALTER SYSTEM SET ...; SELECT pg_reload_conf();` or in `postgresql.conf`. Config is rarely the fix for a *bad query*; start with the query.

## Workshop

Using the scaled-up dataset, for each task capture `EXPLAIN (ANALYZE, BUFFERS)` before and after.

1. `SELECT * FROM orders WHERE date(created_at) = current_date - 3;` Make it fast without changing its meaning.
2. `SELECT * FROM orders WHERE customer_id = 77 ORDER BY created_at DESC LIMIT 10;` Which single index makes this instant (no sort, tiny read)?
3. Dashboard: orders per status for the last 30 days. Try an index on `(created_at)`, then consider `(created_at) INCLUDE (status)` for an index-only scan (VACUUM first).
4. `SELECT * FROM customers WHERE name ILIKE '%mer 4%'` Fix with `pg_trgm`.
5. Top-10 customers by revenue joined across `orders` and `order_items`: where is time spent? Would a materialized view be justified, and how stale could it be?
6. A report runs `SELECT count(*) FROM orders WHERE status = 'new'` every second. Propose three approaches (partial index, approximate count, cached counter) and discuss their trade-offs.
7. Write a loop-free query that replaces this application pseudo-code: `for c in customers: last = SELECT max(created_at) FROM orders WHERE customer_id = c.id`.

??? note "Solutions"

    ```sql
    -- 1
    CREATE INDEX ON orders (created_at);
    SELECT * FROM orders WHERE created_at >= current_date - 3 AND created_at < current_date - 2;
    -- 2
    CREATE INDEX ON orders (customer_id, created_at DESC);
    -- 4
    CREATE EXTENSION pg_trgm; CREATE INDEX ON customers USING gin (name gin_trgm_ops);
    -- 6  Partial index (WHERE status='new') makes the count a small index scan; cached counter (trigger/event table) is O(1) but adds write contention;
    --    approximation is fine if humans only need ~numbers.
    -- 7
    SELECT c.id, max(o.created_at) FROM customers c LEFT JOIN orders o ON o.customer_id = c.id GROUP BY c.id;
    ```

Next: [22. Using SQL from an Application (Quarkus/Java example)](22-from-applications.md)
