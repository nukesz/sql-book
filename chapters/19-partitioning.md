---
hide:
  - toc
---

# 19. Partitioning

**You will learn:** splitting a huge table into parts, why that helps, and what it costs.

## Why partition?

A partitioned table looks like one table but is stored as many child tables. Benefits for *very large* tables (think hundreds of millions of rows or hundreds of GB):

- **Partition pruning:** queries that filter on the partition key touch only relevant partitions.
- **Cheap data retention:** `DROP`/`DETACH` an old partition instead of `DELETE`-ing millions of rows (no bloat, no long vacuum).
- Smaller indexes per partition, and maintenance (vacuum, reindex) per partition.

It is **not** a general performance trick. For tables that fit comfortably in memory, a good index beats partitioning. Don't partition "just in case".

## Declarative partitioning

```sql
CREATE TABLE events (
    id         bigint GENERATED ALWAYS AS IDENTITY,
    occurred_at timestamptz NOT NULL,
    kind       text NOT NULL,
    payload    jsonb,
    PRIMARY KEY (id, occurred_at)            -- the partition key must be part of any PK/unique constraint
) PARTITION BY RANGE (occurred_at);

CREATE TABLE events_2026_01 PARTITION OF events FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE events_2026_02 PARTITION OF events FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE events_default PARTITION OF events DEFAULT;     -- catches rows outside every range

INSERT INTO events (occurred_at, kind) VALUES ('2026-01-15', 'login'), ('2026-02-03', 'logout');
SELECT tableoid::regclass, * FROM events;                     -- which partition holds each row?
```

Strategies:

| Strategy | Use for |
|---|---|
| `RANGE` | time series, id ranges |
| `LIST` | discrete values (country, tenant) |
| `HASH` | even spread when there's no natural range (`FOR VALUES WITH (MODULUS 4, REMAINDER 0)`) |

Indexes created on the parent are created on every partition automatically: `CREATE INDEX ON events (kind, occurred_at);`

## Pruning in action

```sql
EXPLAIN SELECT * FROM events WHERE occurred_at >= '2026-02-01' AND occurred_at < '2026-02-10';
-- only events_2026_02 appears in the plan
EXPLAIN SELECT * FROM events WHERE kind = 'login';   -- no key filter: scans all partitions
```

Pruning only works when the query's `WHERE` constrains the partition key with values the planner can compare.

## Retention: the killer feature

```sql
ALTER TABLE events DETACH PARTITION events_2026_01;     -- instant; table remains as a standalone table
DROP TABLE events_2026_01;                              -- or archive it first (pg_dump, move to cheap storage)
-- PG 14+: DETACH PARTITION ... CONCURRENTLY avoids blocking
```

Create next month's partition ahead of time (cron job or `pg_partman` extension), or the `DEFAULT` partition fills up.

## Gotchas

- Unique constraints/PKs must include the partition key; there are no globally unique indexes across partitions beyond that.
- Foreign keys *to* a partitioned table are supported (PG 12+); many partitions make plans and planning time heavier. Keep partition counts in the tens to low hundreds, not thousands.
- Queries without the partition key scan everything: choose the key by your dominant access pattern.
- Migrating an existing big table into a partitioned one needs a plan: create new partitioned table, copy in batches, swap names in a transaction (or attach the old table as a partition).

## Alternatives to consider first

- A better index, partial index, or BRIN index on a naturally ordered column (`created_at`).
- Archiving old rows into a separate table.
- Read replicas for reporting load.

## Exercises

1. Create `events` as above, insert 100k random events in 2026-01 and 2026-02 using `generate_series`, and confirm with `tableoid::regclass` the rows spread.
2. Show with `EXPLAIN` that a one-day query scans one partition only, and a `kind`-only query scans all.
3. Detach January, count rows, then re-attach it (`ATTACH PARTITION ... FOR VALUES FROM ... TO ...`).
4. Insert an event for `2027-05-05`. Where does it land? What would happen without a default partition?
5. Make a `LIST`-partitioned `customers_by_country` table and think about which queries would improve or worsen.
6. Compare: delete 1 month of data from a normal 100k-row table vs dropping a partition. (Measure with `\timing` and `pg_relation_size`.)

??? note "Solutions"

    ```sql
    -- 1
    INSERT INTO events (occurred_at, kind)
    SELECT '2026-01-01'::timestamptz + random() * interval '58 days', (ARRAY['login','logout','click'])[1 + floor(random()*3)::int]
    FROM generate_series(1, 100000);
    SELECT tableoid::regclass, count(*) FROM events GROUP BY 1;
    -- 3
    ALTER TABLE events ATTACH PARTITION events_2026_01 FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
    -- 4  Lands in events_default. Without it: ERROR: no partition of relation "events" found for row.
    ```

Next: [20. Security: Roles, Row-Level Security and SQL Injection](20-security.md)
