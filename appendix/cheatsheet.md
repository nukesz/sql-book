---
hide:
  - toc
---

# Cheat Sheet

## psql

| | |
|---|---|
| `\dt` `\d t` `\d+ t` | tables / describe / detailed |
| `\dn` `\du` `\df` `\dv` `\di` | schemas, roles, functions, views, indexes |
| `\x` `\timing` | expanded output, timing |
| `\i file` `\copy` | run script, client-side COPY |
| `\set ON_ERROR_STOP on` | stop scripts on first error |
| `\watch 2` | re-run last query every 2 s |
| `\e` | edit query in `$EDITOR` |

## Query skeleton

```sql
SELECT   ...          -- 5 (then DISTINCT 6)
FROM     ... JOIN ... -- 1
WHERE    ...          -- 2
GROUP BY ...          -- 3
HAVING   ...          -- 4
ORDER BY ...          -- 7
LIMIT n;              -- 8
```

## Joins

`INNER` matches only · `LEFT` keeps left · `FULL` keeps both · `CROSS` all pairs · anti-join = `LEFT JOIN ... WHERE r.id IS NULL` or `NOT EXISTS` · filter the optional side in `ON`.

## NULL

`= NULL` never true → `IS NULL` · `IS DISTINCT FROM` null-safe · `coalesce`, `nullif` · prefer `NOT EXISTS` over `NOT IN`.

## Upsert & friends

```sql
INSERT ... ON CONFLICT (key) DO UPDATE SET col = EXCLUDED.col RETURNING *;
INSERT ... ON CONFLICT DO NOTHING;
UPDATE t SET ... FROM other WHERE ... RETURNING *;
WITH moved AS (DELETE ... RETURNING *) INSERT INTO archive SELECT * FROM moved;
```

## Windows

```sql
row_number() OVER (PARTITION BY g ORDER BY x DESC)
sum(x) OVER (ORDER BY d ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)
lag(x) OVER (ORDER BY d)
```

## Transactions & locking

```sql
BEGIN; ... COMMIT;  -- ROLLBACK;
BEGIN ISOLATION LEVEL SERIALIZABLE;   -- retry on 40001
SELECT ... FOR UPDATE [NOWAIT | SKIP LOCKED];
SET LOCAL lock_timeout = '3s';
```

## Indexes

| Need | Index |
|---|---|
| equality / range / sort | B-tree (equality columns first, range/sort last) |
| JSONB `@>`, arrays, full text | GIN |
| `ILIKE '%x%'` | GIN + `gin_trgm_ops` |
| huge append-only time column | BRIN |
| subset of rows | partial index (`WHERE ...`) |
| `lower(col)` etc. | expression index |
| avoid table fetch | `INCLUDE (cols)` |
| production | `CREATE INDEX CONCURRENTLY` |

## Diagnose

```sql
EXPLAIN (ANALYZE, BUFFERS) <query>;
SELECT * FROM pg_stat_activity WHERE state <> 'idle';
SELECT pg_blocking_pids(pid) FROM pg_stat_activity;
SELECT * FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
SELECT relname, n_dead_tup, last_autovacuum FROM pg_stat_user_tables;
SELECT pg_size_pretty(pg_total_relation_size('t'));
```

## Common SQLSTATEs

`23505` unique · `23503` foreign key · `23502` not null · `23514` check · `40001` serialization (retry) · `40P01` deadlock (retry) · `57014` canceled/timeout · `42P01` undefined table · `42501` insufficient privilege.

## Golden rules

1. Parameters, never string concatenation.
2. Constraints in the database.
3. `timestamptz`, `numeric` for money, `text` for strings.
4. Index foreign keys and the columns you filter/sort by; verify with `EXPLAIN`.
5. Short transactions; retry on 40001/40P01.
6. Atomic statements beat read-modify-write.
7. Measure before optimizing.
8. Test your restores.
9. Bound pools, queries, lock waits, retries, and result sizes.
10. Retry the whole transaction in a fresh transaction, and only for transient failures.
11. Use idempotency keys when a write may be repeated after an uncertain outcome.
12. Store business changes and outbox events in one transaction; consumers must tolerate duplicates.
13. Expand → migrate → switch → contract for rolling schema changes.
14. Test concurrency, migrations, failover, and recovery against real PostgreSQL.
