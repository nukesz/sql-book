---
hide:
  - toc
---

# 16. How PostgreSQL Stores Data: MVCC and Vacuum

**You will learn:** why readers don't block writers, why `UPDATE` creates new rows, what "bloat" is, and what vacuum does.

## MVCC: Multi-Version Concurrency Control

PostgreSQL does not overwrite the logical row version during an `UPDATE`. It writes a **new row version** (tuple) and marks the old one as expired; `DELETE` marks a version as expired. Each transaction sees the versions that are visible in *its snapshot*. Consequences:

- Ordinary `SELECT` queries do not take row locks, so they normally do not block row writers, and row writers normally do not block them. Explicit locks and table-level DDL can still block.
- Old versions pile up as **dead tuples** until cleaned.
- An `UPDATE` of a row is really "insert + delete".

### See it

Every row has hidden system columns:

```sql
SELECT ctid, xmin, xmax, id, stock FROM products WHERE id = 1;
UPDATE products SET stock = stock + 1 WHERE id = 1;
SELECT ctid, xmin, xmax, id, stock FROM products WHERE id = 1;     -- ctid changed: a new physical tuple
```

- `ctid`: physical location `(page, item)`.
- `xmin`: transaction id that created this version; `xmax`: transaction-related internal state used for deletion and locking. Treat both as diagnostic internals, not application data.

## Dead tuples and bloat

Old versions occupy space until vacuum removes them. If cleanup lags (or is blocked), tables and indexes grow: **bloat**. Symptoms: table size grows although row count doesn't; queries slow down.

```sql
SELECT relname, n_live_tup, n_dead_tup, last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC;

SELECT pg_size_pretty(pg_total_relation_size('order_items')) AS total,
       pg_size_pretty(pg_relation_size('order_items')) AS table_only;
```

Experiment:

```sql
CREATE TABLE bloat_demo AS SELECT g AS id, repeat('x', 100) AS pad FROM generate_series(1, 100000) g;
SELECT pg_size_pretty(pg_relation_size('bloat_demo'));
UPDATE bloat_demo SET pad = repeat('y', 100);               -- every row rewritten
SELECT pg_size_pretty(pg_relation_size('bloat_demo'));      -- roughly doubled
VACUUM bloat_demo;                                          -- space is reusable, file doesn't shrink
SELECT pg_size_pretty(pg_relation_size('bloat_demo'));
VACUUM FULL bloat_demo;                                     -- rewrites table, shrinks file, takes an exclusive lock
```

## VACUUM

- **`VACUUM`** marks space from dead tuples reusable; doesn't block normal reads/writes. Also updates the **visibility map** (needed for index-only scans) and freezes old transaction ids.
- **`VACUUM FULL`** rewrites the whole table, returning space to the OS, but takes an `ACCESS EXCLUSIVE` lock (blocks everything). Avoid in production; use `pg_repack` if you must compact online.
- **`ANALYZE`** refreshes planner statistics.
- **autovacuum** does both in the background, triggered when a table has changed enough. Don't turn it off. For big, hot tables tune it per table:

```sql
ALTER TABLE orders SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.01);
```

Default scale factor 0.2 means "vacuum after 20% of rows are dead", which on a 500M-row table is 100M dead rows.

### What blocks vacuum from cleaning

**Old snapshots.** A dead tuple can only be removed if no transaction might still need to see it. So:

- long-running transactions, including `idle in transaction` sessions,
- long queries on the primary, or standbys with `hot_standby_feedback`,
- forgotten replication slots and prepared transactions,

hold back cleanup for the *entire database*. Find culprits:

```sql
SELECT pid, state, xact_start, now() - xact_start AS age, left(query, 60)
FROM pg_stat_activity WHERE xact_start IS NOT NULL ORDER BY xact_start;
SELECT slot_name, active, restart_lsn FROM pg_replication_slots;
```

Set `idle_in_transaction_session_timeout` to kill forgotten transactions.

## HOT updates and fillfactor

If an `UPDATE` changes no indexed column **and** the new version fits in the same page, PostgreSQL does a cheap *HOT* (heap-only tuple) update without touching indexes. Leaving free space helps: `ALTER TABLE hot_table SET (fillfactor = 80);`. Another reason to avoid indexing frequently updated columns needlessly.

```sql
SELECT relname, n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relname = 'products';
```

## Transaction id wraparound (the one scary thing)

Transaction ids are 32-bit and wrap around. Vacuum *freezes* old rows to prevent this. If autovacuum is blocked for too long, PostgreSQL eventually refuses writes to protect data. Monitor `age(datfrozenxid)`:

```sql
SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;
```

Alert well before ~1 billion (limit ≈ 2 billion).

## Design consequences

- Queue/status-flip tables that are updated constantly create a lot of dead tuples; keep them small, vacuum aggressively, or delete in batches / partition (chapter 19).
- "Updating a counter in one row thousands of times per second" generates bloat and lock contention. Consider batching or an append-only events table with periodic aggregation.
- `DELETE` of millions of rows is not free: space is not returned. Partition + `DROP PARTITION` is instant.
- `TRUNCATE` is the instant way to empty a table.

## Exercises

1. Run the `bloat_demo` experiment and record the sizes after each step.
2. Open a transaction in session A (`BEGIN; SELECT count(*) FROM bloat_demo;` and leave it). In session B, `UPDATE` everything and `VACUUM VERBOSE bloat_demo`. Read the output: how many dead row versions "cannot be removed yet"? Commit A and vacuum again.
3. Watch `ctid`/`xmin`/`xmax` change across an update, and in a rolled-back update.
4. Check HOT update ratios for `products` and `orders` after some updates.
5. Find the biggest tables and indexes in your database by size.
6. Explain why `SELECT count(*)` on a big table is slow in PostgreSQL even with an index.

??? note "Solutions"

    ```sql
    -- 5
    SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) FROM pg_class
    WHERE relkind = 'r' AND relnamespace = 'public'::regnamespace ORDER BY pg_total_relation_size(oid) DESC;
    -- 6  Visibility is stored with row versions, so the engine must check which versions your snapshot can see.
    --    (Index-only scans help only when the visibility map is up to date.) Use estimates (reltuples) or a maintained counter if exactness isn't required.
    ```

Next: [17. Locking and Concurrency Patterns](17-locking.md)
