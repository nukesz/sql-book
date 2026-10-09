---
hide:
  - toc
---

# 23. Operations: Migrations, Backups, Monitoring

**You will learn:** changing schemas safely, backing up and restoring, and what to watch in production.

## Schema migrations

Treat schema as code: numbered, versioned, reviewed scripts applied in order by a tool (Flyway, Liquibase, Sqitch, or built-in tooling such as Quarkus Flyway). Rules:

- Never edit an applied migration; add a new one.
- Run migrations with an owner role (not the application role).
- Make each migration **safe to run while the old application version is still running** (expand → migrate → contract).

### Expand / contract

To rename a column or change its meaning without downtime:

1. **Expand:** add the new column (nullable).
2. Deploy code that writes both and reads the new one (fallback to old).
3. **Backfill** old rows in small batches.
4. Make the new column `NOT NULL`/constrained; stop writing the old one.
5. **Contract:** drop the old column in a later release.

### Dangerous operations and safer versions

| Operation | Risk | Safer approach |
|---|---|---|
| `ALTER TABLE ... ADD COLUMN ... DEFAULT x` | PG 11+: fast; older versions rewrote the table | fine on modern versions |
| `ALTER COLUMN ... TYPE` | table rewrite under `ACCESS EXCLUSIVE` | add new column, backfill in batches, swap |
| `ADD CONSTRAINT ... CHECK/FOREIGN KEY` | full scan while holding a lock | `ADD CONSTRAINT ... NOT VALID`, then `VALIDATE CONSTRAINT` (weaker lock) |
| `SET NOT NULL` | full scan under lock | add `CHECK (col IS NOT NULL) NOT VALID`, validate, then `SET NOT NULL` (PG 12+ skips the scan) |
| `CREATE INDEX` | blocks writes | `CREATE INDEX CONCURRENTLY` |
| any DDL needing `ACCESS EXCLUSIVE` | lock queue stalls everything (chapter 17) | `SET lock_timeout = '3s'` and retry |

```sql
ALTER TABLE order_items ADD CONSTRAINT order_items_product_fk
    FOREIGN KEY (product_id) REFERENCES products (id) NOT VALID;      -- instant, new rows are checked
ALTER TABLE order_items VALIDATE CONSTRAINT order_items_product_fk;   -- scans, but doesn't block writes
```

### Batch backfills

```sql
-- repeat until 0 rows updated; each batch is its own short transaction
UPDATE customers SET segment = 'standard'
WHERE id IN (SELECT id FROM customers WHERE segment IS NULL LIMIT 5000);
```

Large single `UPDATE`s create huge transactions, bloat, replication lag and long locks.

## Backups

Two families:

**Logical** (SQL/data): `pg_dump` / `pg_restore`. Portable across versions, per database/table, slower for huge data.

```bash
pg_dump -h localhost -U learner -Fc -f shop.dump shop         # custom compressed format
createdb -h localhost -U learner shop_restored
pg_restore -h localhost -U learner -d shop_restored shop.dump
pg_dump -s shop > schema.sql                                   # schema only
pg_dumpall --globals-only > roles.sql                          # roles (not part of per-db dumps)
```

This restores under a new database name; the role needs permission to create databases. By contrast, `pg_restore --create -d postgres shop.dump` connects to a maintenance database and recreates the database name stored in the archive.

**Physical** (files): `pg_basebackup` plus continuous WAL archiving gives **point-in-time recovery (PITR)**: restore to any second before a mistake. Tools: pgBackRest, Barman, WAL-G, or your cloud provider's managed backups.

Rules:

- A backup you have not **restored** is a hope, not a backup. Schedule restore tests.
- Replication ≠ backup: a replica faithfully replays your `DROP TABLE`.
- Know your **RPO** (how much data loss is acceptable) and **RTO** (how long recovery may take); they drive the design.

## Replication and high availability (overview)

- **Streaming replication:** a standby replays the primary's WAL; can serve read-only queries (replicas lag slightly: read-your-writes isn't guaranteed there).
- **Failover** is handled by tooling (Patroni, cloud services), not by hand at 3 a.m.
- **Logical replication:** replicate selected tables, even across versions; useful for migrations and upgrades.

## Monitoring checklist

| What | Where |
|---|---|
| Slow/total-expensive queries | `pg_stat_statements`, slow query log |
| Active sessions, waiting, blocked | `pg_stat_activity`, `pg_blocking_pids()` |
| Long transactions / `idle in transaction` | `pg_stat_activity.xact_start` |
| Connection count vs `max_connections` | `pg_stat_activity` |
| Dead tuples, autovacuum activity | `pg_stat_user_tables` |
| Transaction id age | `age(datfrozenxid)` |
| Replication lag | `pg_stat_replication` |
| Cache hit ratio, I/O | `pg_stat_database`, `pg_statio_user_tables` |
| Disk space, WAL growth | OS + `pg_ls_waldir()`, inactive replication slots |
| Table/index size growth | `pg_total_relation_size()` |

Useful snapshot queries:

```sql
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;
SELECT datname, round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS cache_hit_pct FROM pg_stat_database WHERE datname = 'shop';
SELECT schemaname, relname, seq_scan, idx_scan, n_live_tup FROM pg_stat_user_tables ORDER BY seq_scan DESC;
```

## Upgrades

- **Minor** (17.1 → 17.2): binary swap and restart, always apply.
- **Major** (16 → 17): `pg_upgrade` (fast, in place) or logical replication (near-zero downtime). Test with a copy of production first; re-run `ANALYZE` afterwards. Extensions need compatible versions.
- Each major version is supported ~5 years; plan upgrades before end of life.

## Exercises

1. `pg_dump` the `shop` database in custom format, restore it into `shop_restored`, and compare row counts.
2. Add a foreign key to a table using `NOT VALID` then `VALIDATE`. In a second session, observe that writes are not blocked during `VALIDATE` (use `pg_sleep` inside a long transaction to experiment).
3. Rename `customers.phone` to `mobile` using expand/contract in four numbered SQL files. Which steps may be deployed independently?
4. Write a batch backfill loop in PL/pgSQL using a procedure with `COMMIT` per batch.
5. Build a one-page "health check" SQL script from the monitoring queries above and run it on your database.
6. Write down an RPO/RTO for the shop. Which backup approach does that imply?

??? note "Solutions"

    ```sql
    -- 4
    CREATE PROCEDURE backfill_segment() LANGUAGE plpgsql AS $$
    DECLARE n int;
    BEGIN
      LOOP
        UPDATE customers SET segment = 'standard' WHERE id IN (SELECT id FROM customers WHERE segment IS NULL LIMIT 5000);
        GET DIAGNOSTICS n = ROW_COUNT;
        EXIT WHEN n = 0;
        COMMIT;
      END LOOP;
    END $$;
    CALL backfill_segment();      -- must not be wrapped in an outer BEGIN ... COMMIT
    -- 3  1) add mobile  2) deploy app writing both, then backfill batches  3) deploy app reading mobile only  4) drop phone (later release)
    --    Steps 1 and 2 are backward compatible and independent; 4 only after no running version reads phone.
    ```

Next: [24. Quarkus Datasources and JDBC](24-quarkus-datasources.md)
