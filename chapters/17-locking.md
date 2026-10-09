---
hide:
  - toc
---

# 17. Locking and Concurrency Patterns

**You will learn:** row locks, table locks, deadlocks, and practical patterns: work queues, safe counters, advisory locks.

## Row-level locks

Writers lock the rows they change until commit/rollback. A second writer touching the same row **waits**.

```sql
-- session A
BEGIN; UPDATE products SET stock = stock - 1 WHERE id = 1;
-- session B
UPDATE products SET stock = stock - 1 WHERE id = 1;     -- blocks until A commits or rolls back
```

### Explicit row locks

```sql
SELECT * FROM products WHERE id = 1 FOR UPDATE;          -- I intend to modify; others can't update/lock it
SELECT * FROM products WHERE id = 1 FOR NO KEY UPDATE;   -- same but allows FK-referencing inserts (what UPDATE takes)
SELECT * FROM products WHERE id = 1 FOR SHARE;           -- others can read-lock, not modify
```

Typical pattern (read-modify-write with application logic in between):

```sql
BEGIN;
SELECT stock FROM products WHERE id = 1 FOR UPDATE;      -- others wait here
-- app decides
UPDATE products SET stock = stock - 1 WHERE id = 1;
COMMIT;
```

When the logic is simple, a single atomic `UPDATE ... WHERE stock > 0` is simpler and faster (chapter 12).

### NOWAIT and SKIP LOCKED

```sql
SELECT * FROM products WHERE id = 1 FOR UPDATE NOWAIT;        -- error immediately if locked
SELECT * FROM products WHERE id = 1 FOR UPDATE SKIP LOCKED;   -- ignore locked rows
SET lock_timeout = '2s';                                      -- give up waiting after 2 s
```

## Work queue with SKIP LOCKED

The standard way to build a job queue in PostgreSQL, with many workers and no double-processing:

```sql
CREATE TABLE jobs (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payload jsonb NOT NULL,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'done')),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX jobs_pending_idx ON jobs (id) WHERE status = 'pending';

-- each worker:
WITH next AS (
    SELECT id FROM jobs WHERE status = 'pending'
    ORDER BY id LIMIT 1
    FOR UPDATE SKIP LOCKED
)
UPDATE jobs SET status = 'running' FROM next WHERE jobs.id = next.id
RETURNING jobs.*;
```

Two workers running this concurrently will get different jobs. (Add `started_at` and a reaper to retry stuck "running" jobs; delete or partition finished jobs to limit bloat.)

## Table-level locks

Every statement takes a table lock, usually a weak one that doesn't conflict with normal work:

| Statement | Lock mode | Blocks |
|---|---|---|
| `SELECT` | `ACCESS SHARE` | only `ACCESS EXCLUSIVE` |
| `INSERT/UPDATE/DELETE` | `ROW EXCLUSIVE` | schema changes, not other DML |
| `CREATE INDEX` | `SHARE` | writes (not reads) |
| `CREATE INDEX CONCURRENTLY` | several weaker locks across phases | allows normal DML, but can wait for transactions and conflicts with some maintenance/DDL |
| most `ALTER TABLE`, `DROP`, `VACUUM FULL`, `TRUNCATE` | `ACCESS EXCLUSIVE` | **everything**, even `SELECT` |

### The lock queue trap

An `ALTER TABLE` waiting for `ACCESS EXCLUSIVE` queues behind a long-running query, and **everything arriving after it queues behind the ALTER**, so a tiny migration can stall your whole application. Protect migrations:

```sql
SET lock_timeout = '3s';
ALTER TABLE orders ADD COLUMN note text;     -- fails fast instead of piling up; retry later
```

## Deadlocks

Two transactions each hold a lock the other needs:

```sql
-- A: BEGIN; UPDATE accounts SET balance = balance - 1 WHERE id = 1;
-- B: BEGIN; UPDATE accounts SET balance = balance - 1 WHERE id = 2;
-- A: UPDATE accounts SET balance = balance + 1 WHERE id = 2;   -- waits for B
-- B: UPDATE accounts SET balance = balance + 1 WHERE id = 1;   -- waits for A -> deadlock
-- after deadlock_timeout (1 s) PostgreSQL aborts one: ERROR: deadlock detected (SQLSTATE 40P01)
```

Prevention:

- **Always lock rows in a consistent order** (e.g. by ascending id): `SELECT ... WHERE id IN (...) ORDER BY id FOR UPDATE`.
- Keep transactions short.
- Retry on `40P01`.

## Inspecting locks

```sql
SELECT pid, pg_blocking_pids(pid) AS blocked_by, state, wait_event_type, wait_event, left(query, 60)
FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0;

SELECT locktype, relation::regclass, mode, granted, pid FROM pg_locks WHERE NOT granted;

SELECT pg_cancel_backend(1234);       -- cancel current query (requires suitable privilege)
SELECT pg_terminate_backend(1234);    -- end the connection; its open transaction rolls back
```

Inspect first and prefer cancellation. Terminating another backend is disruptive and should be an operational last resort.

## Advisory locks

Application-defined locks on arbitrary numbers, not tied to any table. Great for "only one instance runs this job" or per-entity serialization:

```sql
SELECT pg_try_advisory_lock(42);             -- true if acquired (session-level; release with pg_advisory_unlock(42))
SELECT pg_advisory_xact_lock(hashtext('customer:123'));   -- released automatically at transaction end
```

Beware session-level advisory locks with connection pools (the lock stays with a pooled connection); prefer the `_xact_` variants.

## Optimistic concurrency

Instead of locking, detect conflicts:

```sql
UPDATE products SET price = 19.99, version = version + 1 WHERE id = 1 AND version = 7;
-- affected rows = 0  -> someone else changed it first: reload and retry, or report a conflict
```

Great for user-edit flows (long "think time") where holding a lock is impossible.

## Exercises

1. Reproduce a row-lock wait with two sessions; look at `pg_stat_activity` from a third.
2. Reproduce a deadlock and read the server log message.
3. Build the `jobs` queue, insert 20 jobs, and run the worker query in two sessions inside transactions; confirm they get different jobs. What happens without `SKIP LOCKED`?
4. In session A: `BEGIN; SELECT count(*) FROM orders;` (holds `ACCESS SHARE`). In B: `ALTER TABLE orders ADD COLUMN x int;` (waits). In C: `SELECT 1 FROM orders LIMIT 1;`. What happens to C? Fix with `lock_timeout`.
5. Implement a "claim a seat" operation (`seats(id, taken_by)`) safely: `UPDATE ... WHERE taken_by IS NULL RETURNING id`. Why is it race-free?
6. Add a `version` column to `products` and demonstrate optimistic locking between two sessions.

??? note "Solutions"

    ```sql
    -- 3  Without SKIP LOCKED the second worker blocks on the first worker's row until it commits (and then re-checks the row;
    --    since its status is no longer 'pending', it moves on or returns nothing). Throughput collapses to one worker at a time.
    -- 4  C blocks too (queued behind the waiting ALTER) even though A only reads: the lock queue trap.
    -- 5  CREATE TABLE seats (id int PRIMARY KEY, taken_by int);
    --    UPDATE seats SET taken_by = 7 WHERE id = (SELECT id FROM seats WHERE taken_by IS NULL ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED) RETURNING id;
    --    The UPDATE locks the row and re-evaluates the WHERE after any wait; only one session can flip NULL -> value.
    ```

Next: [18. Views, Functions and Triggers](18-views-functions-triggers.md)
