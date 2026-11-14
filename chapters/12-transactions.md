---
hide:
  - toc
---

# 12. Transactions and Isolation

**You will learn:** why transactions are the unit of correctness in a database, how PostgreSQL implements ACID, what each isolation level actually protects you from, and how to reproduce the main concurrency anomalies yourself with two psql sessions.

## Why transactions are the heart of a database

A file can store bytes. A database has to do something much harder: let many clients read and write the same data at the same time, survive crashes, and still leave the data in a state that makes sense. The transaction is the abstraction that makes this possible.

Think about placing an order. It is not one write; it is several: create the order, reserve stock, insert the order lines, maybe write an audit row. If the process dies after reserving stock but before creating the order, the shop has lost inventory it can never sell. If two customers buy the last item at the same time, both must not succeed. If a report reads the tables halfway through the operation, it must not see an order with no lines. These are not exotic edge cases; they are the normal failure modes of concurrent software.

A transaction groups those writes into one unit with four promises: either all of them become visible, or none of them do; the database moves from one valid state to another; concurrent transactions do not corrupt each other's view; and a committed change survives a crash. Constraints and transactions are how the database enforces the rules that application code must not be allowed to break.

This is why transactions are not an advanced feature you add at the end. They are the boundary between "the data is correct" and "the data is whatever the last failed request left behind." You also cannot avoid them: outside an explicit `BEGIN`, every statement still runs in its own transaction. The only choice is whether you understand where the boundaries are.

## What a transaction is

A transaction is a group of statements that succeed or fail **as a unit**.

```sql
BEGIN;

INSERT INTO orders (customer_id, status)
VALUES (1, 'new')
RETURNING id AS order_id \gset

UPDATE products
SET stock = stock - 1
WHERE id = 1 AND stock > 0;

INSERT INTO order_items (order_id, line_no, product_id, quantity, unit_price)
VALUES (:order_id, 1, 1, 1, 10.00);

COMMIT;      -- make all three statements permanent
-- or ROLLBACK; to undo all of them
```

`\gset` is a psql meta-command that stores the returned id in a psql variable; application code would keep the id returned by the driver instead. The important part is that the order, the stock change, and the line are one unit. A `COMMIT` makes them visible together; a `ROLLBACK`, an error, or a crash before commit leaves the database as if none of them happened. If you run this against the sample data while experimenting, replace `COMMIT` with `ROLLBACK`; the example is about the boundary, not about keeping the order.

`BEGIN` starts an explicit transaction. `COMMIT` (or `END`) makes its changes permanent and visible; `ROLLBACK` (or `ABORT`) discards them. If a statement inside the transaction fails, the transaction enters an **aborted** state: further statements fail with `current transaction is aborted, commands ignored until end of transaction block` until you issue `ROLLBACK` (or roll back to a savepoint). An error does not automatically end the transaction; it poisons it until you explicitly end it.

Outside an explicit transaction, PostgreSQL runs in **autocommit** mode: each statement is wrapped in its own transaction. That is still a transaction, just a very short one. If it fails, only that statement is undone.

Changes made inside a transaction are visible to that transaction immediately, but invisible to everyone else until commit. Other sessions do not block on ordinary reads; MVCC lets them read the last committed version of each row while your transaction is still working (chapter 16). We will demonstrate this in the lab.

### Savepoints

A savepoint marks a position inside a transaction that you can return to without abandoning the whole transaction:

```sql
BEGIN;
INSERT INTO orders (customer_id, status)
VALUES (1, 'new')
RETURNING id AS order_id \gset
SAVEPOINT before_items;
INSERT INTO order_items (order_id, line_no, product_id, quantity, unit_price)
VALUES (:order_id, 1, 1, 0, 10.00);          -- quantity 0 violates CHECK: statement fails
ROLLBACK TO SAVEPOINT before_items;          -- undo only the failed part
-- the order insert is still pending; you may continue
COMMIT;
```

`ROLLBACK TO SAVEPOINT` keeps the savepoint itself, so you can return to it again. `RELEASE SAVEPOINT` forgets it. After an error, `ROLLBACK TO SAVEPOINT` is the only statement that can rescue an aborted transaction; plain `ROLLBACK` discards everything.

Savepoints are useful for optional steps, retryable sub-operations, and procedural code (PL/pgSQL exception blocks use them internally). They are not free: each savepoint is a subtransaction and consumes resources. Use a few, not one per row in a million-row loop.

A savepoint does not commit anything. The enclosing transaction still owns the transaction's snapshot and the locks it acquired before the savepoint; changes after the savepoint are simply undone.

## ACID, concretely

ACID is a convenient checklist, but each letter maps to a different mechanism. Knowing the mechanism tells you what the database can and cannot guarantee.

**Atomicity: all or nothing.** PostgreSQL records changes in the write-ahead log (WAL) and makes them visible only at commit. If a statement fails, the transaction cannot commit and its changes are discarded; if the server crashes, recovery replays committed transactions and discards uncommitted ones. This covers errors, constraint violations, crashes, and power loss. It does not cover bad decisions: if you commit nonsense, it is atomically nonsense.

**Consistency: one valid state to another.** Declared constraints, foreign keys, `CHECK` rules, `UNIQUE` indexes, and triggers are enforced by the database. But PostgreSQL can only enforce rules you actually expressed. A business rule such as "an order must have at least one line" or "at least one doctor must be on call" is not automatically protected by ACID. You enforce it with constraints, transactions, locking, or serializable isolation. The "C" in ACID is therefore partly the database's job and partly yours.

Deferrable constraints blur the line between atomicity and consistency: a `DEFERRABLE` constraint can be checked at commit rather than at each statement, which is useful for cyclic foreign keys or swapping unique values. Use `SET CONSTRAINTS ALL DEFERRED;` inside the transaction when the constraint was declared deferrable (chapter 8).

**Isolation: concurrent transactions do not corrupt each other's view.** PostgreSQL uses MVCC: each transaction reads a snapshot of committed row versions. Which snapshot it gets, and which conflicts it detects, is the isolation level. Higher isolation is not free; it is paid for with aborts, retries, and sometimes waiting. We devote the rest of the chapter to this.

**Durability: committed means survives a crash.** With the default `synchronous_commit = on`, `COMMIT` returns only after the WAL record has been flushed to durable storage. If you turn `synchronous_commit` off (or `fsync` off) for speed, you trade durability for performance: after a crash you may lose the last committed transactions, though the database remains consistent. Replication adds another dimension: `synchronous_commit` can wait for a standby to receive or apply the WAL.

## Concurrency anomalies

When transactions overlap, their statements interleave in ways no one-at-a-time execution could produce. These interleavings have names, and the names are the vocabulary of isolation levels.

| Anomaly | Meaning |
|---|---|
| Dirty read | reading another transaction's *uncommitted* data |
| Non-repeatable read | the same row read twice gives different values because someone committed in between |
| Phantom read | the same query twice returns different *sets* of rows |
| Read skew | different rows are read at different times, producing a state that never existed |
| Lost update | two read-modify-write cycles overwrite one another |
| Write skew | two transactions each check a condition on overlapping data and then update *different* rows, jointly breaking an invariant |

**Dirty read.** You read a value that another transaction has changed but not committed. PostgreSQL never allows this: MVCC readers see only committed row versions. `READ UNCOMMITTED` is accepted for SQL compatibility but behaves as `READ COMMITTED`.

**Non-repeatable read.** You read a row, another transaction updates and commits it, and you read it again and get a different value. Your transaction now contains two contradictory observations of the same row. `READ COMMITTED` allows this; `REPEATABLE READ` prevents it by using one snapshot for the whole transaction.

**Phantom read.** You run a query, another transaction inserts or deletes a row that matches the query, and you run it again and get a different set of rows. This is non-repeatable read at the level of a *predicate*, not a single row. PostgreSQL's `REPEATABLE READ` prevents phantoms too, even though the SQL standard permits them at that level.

**Read skew.** You read different rows at different times and combine them into an impossible state. A classic example is a bank transfer: read account A before the debit and account B after the credit, and the total appears to be 10 too high. Each row was read only once, so this is not a non-repeatable read; it is a consistency problem across statements. `READ COMMITTED` allows it, and `REPEATABLE READ` prevents it because every statement in the transaction sees the same snapshot. A single query is already consistent at `READ COMMITTED`, since one statement has one snapshot; the danger is combining multiple statements.

**Lost update.** Two transactions read the same value, both compute a new value from it, and both write it back. The second write overwrites the first, so one update disappears. This is the most common concurrency bug in application code: read a stock level, subtract one, write it back. `READ COMMITTED` allows it. `REPEATABLE READ` prevents the silent overwrite by aborting the second writer, and atomic SQL or row locks prevent it in the first place.

**Write skew.** Two transactions read overlapping data, each checks an invariant, and each writes a *different* row. Individually, each transaction looks correct; together they break the rule. The standard example is a hospital rule "at least one doctor on call." Two doctors each see two on call, and each takes themselves off call. Neither wrote the row the other read, so simple row locks on the written rows do not help. `REPEATABLE READ` allows write skew. `SERIALIZABLE` prevents it, or you must explicitly lock the rows/predicate you checked.

A **serialization anomaly** is the general case: a group of transactions whose combined effect cannot be explained by any serial order. Write skew is the most instructive example.

## Isolation levels in PostgreSQL

SQL defines four levels: `READ UNCOMMITTED`, `READ COMMITTED`, `REPEATABLE READ`, and `SERIALIZABLE`. PostgreSQL implements three distinct behaviours because it never allows dirty reads.

| Level | Dirty | Non-repeatable | Phantom | Read skew | Lost update | Write skew |
|---|---|---|---|---|---|---|
| `READ COMMITTED` (default) | no | possible | possible | possible | possible | possible |
| `REPEATABLE READ` | no | no | no (in PG) | no | no (error) | possible |
| `SERIALIZABLE` | no | no | no | no | no | no |

"No (error)" for lost update under `REPEATABLE READ` means the second writer is aborted with `40001` instead of silently overwriting. That is prevention, but the application must retry.

### READ COMMITTED

Each **statement** sees a snapshot of data committed before the statement began. A single statement is internally consistent: a long `SELECT` does not see rows committed after it started. But two statements in the same transaction can see different data, which is why non-repeatable reads, phantoms, read skew, and lost updates are possible.

Writes have an important extra rule. If an `UPDATE` or `DELETE` targets a row that another transaction changed and committed after your snapshot, PostgreSQL waits for that transaction, then **re-evaluates the `WHERE` clause against the updated row** before deciding whether to modify it. This is why these statements are safe under concurrency:

```sql
UPDATE products SET stock = stock - 1 WHERE id = 1 AND stock > 0;
UPDATE accounts SET balance = balance - 10 WHERE id = 1 AND balance >= 10;
```

The condition and the arithmetic are evaluated on the latest committed row. If the row no longer matches, it is skipped. But a read-then-write sequence in application code is not safe, because the check and the write are separate statements and another transaction can slip between them.

### REPEATABLE READ

The whole **transaction** sees one snapshot, taken at its first query. Repeated reads return the same data, and phantoms do not occur.

Writes use "first updater wins": if you try to update or delete a row that was changed by a transaction that committed after your snapshot, you get:

```text
ERROR: could not serialize access due to concurrent update
SQLSTATE: 40001
```

The transaction is aborted and must be rolled back. This prevents lost updates, but it also means your application must be prepared to retry the whole transaction. `REPEATABLE READ` is *not* serializable: write skew is still possible, because the transactions read overlapping data and write different rows.

### SERIALIZABLE

`SERIALIZABLE` gives the same snapshot as `REPEATABLE READ` and adds **Serializable Snapshot Isolation (SSI)**. PostgreSQL tracks read/write dependencies between concurrent transactions and aborts one if the combined result could not have happened in some serial order. Internally it uses lightweight predicate locks (SIREAD locks) that track what was read without blocking other transactions.

Conflicts raise `40001` (`serialization_failure`), sometimes at the `UPDATE` and sometimes at `COMMIT`. Retry the entire transaction from the beginning. SSI can produce **false positives**: two transactions that would actually have been safe may still be aborted. That is the price of not locking everything, and it is why retry logic is not optional at this level.

`SERIALIZABLE` is the only level that protects invariants you did not encode as explicit locks. It is the right tool for cross-row and cross-table rules, but it works best with short transactions and a disciplined retry loop.

### Choosing a level

- **`READ COMMITTED` + atomic statements + short transactions** covers most OLTP work. Make the database perform the read-modify-write in one statement whenever possible.
- **`REPEATABLE READ`** is for multi-statement reads that need a stable view (reports, batch consistency) and as a simple guard against lost updates. Expect `40001` on conflicting writes.
- **`SERIALIZABLE`** is for invariants that span rows or tables, especially read-check-write patterns that can write disjoint rows. Always pair it with retries.
- **Read-only reporting** can use `BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE;`. A deferrable read-only transaction waits until it can obtain a snapshot that is guaranteed not to suffer serialization failures. It may wait, but it will not abort for serialization reasons.
- Do not raise the isolation level to hide a bad transaction design. But do not assume `READ COMMITTED` is serializable either.

Set the level explicitly when it matters:

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
-- or, before the first query:
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
-- what is the default?
SHOW default_transaction_isolation;
```

The default can also be changed per session, per role, or per database, but explicit `BEGIN ISOLATION LEVEL ...` documents the intent at the place where it matters.

### The retry rule

A transaction aborted with `40001` or `40P01` (deadlock) has not partially committed. It is rolled back. **Retry the whole business operation in a new transaction.** Retrying only the failed statement is wrong: the earlier reads and writes belonged to the old snapshot, and the transaction is already aborted. Use a bounded number of attempts, back off with jitter so concurrent losers do not retry in lockstep, and do not retry non-transient errors such as constraint violations. Chapter 25 develops this for application code.

## Lab: see it yourself (two psql windows, A and B)

Open two psql sessions. Run the setup once in either session, then follow the steps. Keep autocommit on in B (the default) unless a step says `BEGIN`.

```sql
UPDATE products SET stock = 40 WHERE id = 1;

CREATE TABLE IF NOT EXISTS accounts (id int PRIMARY KEY, balance numeric NOT NULL);
TRUNCATE accounts;
INSERT INTO accounts VALUES (1, 100), (2, 100);

CREATE TABLE IF NOT EXISTS doctors (name text PRIMARY KEY, on_call boolean NOT NULL);
TRUNCATE doctors;
INSERT INTO doctors VALUES ('alice', true), ('bob', true);
```

The `accounts` and `doctors` tables are learning aids; drop them when you are done.

### Dirty read: PostgreSQL says no

```sql
-- A
BEGIN;
UPDATE products SET stock = 5 WHERE id = 1;

-- B (autocommit)
SELECT stock FROM products WHERE id = 1;   -- 40, the last committed value

-- A
ROLLBACK;
```

B does not block and does not see `5`. Under MVCC, readers see committed versions; dirty reads are impossible in PostgreSQL. This is also why `READ UNCOMMITTED` is accepted but behaves as `READ COMMITTED`.

### Non-repeatable read

```sql
-- reset
UPDATE products SET stock = 40 WHERE id = 1;

-- A
BEGIN;                                     -- READ COMMITTED
SELECT stock FROM products WHERE id = 1;   -- 40

-- B
UPDATE products SET stock = 5 WHERE id = 1;

-- A
SELECT stock FROM products WHERE id = 1;   -- 5: the same transaction sees a new value
COMMIT;
```

Reset to `40` and repeat A with `BEGIN ISOLATION LEVEL REPEATABLE READ;`. A keeps seeing `40`. If A then tries to update the row after B commits, it gets `40001` rather than overwriting.

### Read skew

```sql
-- reset
UPDATE accounts SET balance = 100;

-- A
BEGIN;                                            -- READ COMMITTED
SELECT balance FROM accounts WHERE id = 1;        -- 100

-- B
BEGIN;
UPDATE accounts SET balance = balance - 10 WHERE id = 1;
UPDATE accounts SET balance = balance + 10 WHERE id = 2;
COMMIT;

-- A
SELECT balance FROM accounts WHERE id = 2;        -- 110
-- A has now seen 100 and 110: a total of 210 that never existed
COMMIT;
```

At `REPEATABLE READ`, A's second read returns `100`, because both reads use the same snapshot. Notice that a single `SELECT sum(balance)` would have been consistent at `READ COMMITTED`; the anomaly comes from combining multiple statements.

### Phantom read

```sql
-- A
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM products
WHERE category_id = (SELECT id FROM categories WHERE name = 'Fiction');  -- say 30

-- B
INSERT INTO products (category_id, name, price, stock)
VALUES ((SELECT id FROM categories WHERE name = 'Fiction'), 'Phantom', 1, 1);

-- A
SELECT count(*) FROM products
WHERE category_id = (SELECT id FROM categories WHERE name = 'Fiction');  -- still 30
COMMIT;

-- B
DELETE FROM products WHERE name = 'Phantom';
```

At `READ COMMITTED` the second count would include the new row. At `REPEATABLE READ` it does not, because the transaction snapshot is fixed. PostgreSQL's `REPEATABLE READ` prevents phantoms even though the SQL standard allows them at that level.

### Lost update

```sql
-- reset
UPDATE products SET stock = 40 WHERE id = 1;

-- A
BEGIN;
SELECT stock FROM products WHERE id = 1;   -- 40

-- B
BEGIN;
SELECT stock FROM products WHERE id = 1;   -- 40

-- A
UPDATE products SET stock = 39 WHERE id = 1;

-- B
UPDATE products SET stock = 39 WHERE id = 1;   -- waits for A

-- A
COMMIT;

-- B (now unblocks)
COMMIT;

-- either session
SELECT stock FROM products WHERE id = 1;       -- 39, not 38
```

Both transactions computed `39` from `40`; one decrement vanished. At `REPEATABLE READ`, B's `UPDATE` would fail with `40001` once A commits instead of overwriting. The fix is not necessarily a higher isolation level: an atomic update is simpler and faster.

```sql
-- reset, then run this in both sessions, interleaved
UPDATE products SET stock = 40 WHERE id = 1;
UPDATE products SET stock = stock - 1 WHERE id = 1 AND stock > 0;

-- final stock: 38
```

The row lock makes the second update wait; when it proceeds, `stock` is already `39`, so it writes `38`. The `AND stock > 0` condition is evaluated on the latest row. Under `REPEATABLE READ` the same statement may instead fail with `40001`, because the row changed after the transaction's snapshot; retry it in a new transaction. Three standard fixes, in order of preference:

1. **Atomic update:** `UPDATE ... SET stock = stock - 1 WHERE ...` (best when the logic fits in one statement).
2. **Pessimistic lock:** `SELECT ... FOR UPDATE` before the read-modify-write (chapter 17).
3. **Optimistic locking:** add a `version` column and update `WHERE id = ? AND version = ?`; zero rows updated means someone else got there first, so retry or report a conflict (chapters 17 and 25).

### Write skew

```sql
-- reset
UPDATE doctors SET on_call = true;

-- A
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM doctors WHERE on_call;   -- 2

-- B
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM doctors WHERE on_call;   -- 2

-- A
UPDATE doctors SET on_call = false WHERE name = 'alice';
COMMIT;

-- B
UPDATE doctors SET on_call = false WHERE name = 'bob';
COMMIT;

-- either session
SELECT count(*) FROM doctors WHERE on_call;   -- 0: the invariant is broken
```

Both transactions obeyed the rule at the moment they checked. They wrote different rows, so neither row lock conflicts. This is write skew, and `REPEATABLE READ` allows it.

Repeat the experiment with `SERIALIZABLE` in both sessions. One of the transactions gets `40001`, either on its `UPDATE` or at `COMMIT`. If the application retries, the retry sees only one doctor on call and can refuse to take the last one off call. Alternatively, lock the rows you read: `SELECT * FROM doctors WHERE on_call FOR UPDATE;` (without an aggregate) makes the second transaction wait or abort with `40001`, which protects the check-and-write for this fixed set of rows.

## Practical rules for application code

- **Draw the boundary around one business operation.** The transaction should cover every write that must succeed together. Do not put a transaction around each repository call; that commits partial work.
- **Keep transactions short.** Never wait for user input, call an external HTTP service, send email, or publish to a message broker inside a transaction. Network latency plus locks is how a small outage becomes a large one. Use the outbox pattern for external side effects (chapter 27).
- **Prefer atomic SQL.** A conditional `UPDATE ... WHERE ...` avoids the read-modify-write window entirely. Use `RETURNING` when you need the result.
- **Retry `40001` and `40P01`.** Retry the whole transaction with a fresh snapshot, bounded attempts, and backoff with jitter. Do not retry constraint violations, syntax errors, or bad input.
- **Do not leave transactions open.** An `idle in transaction` session holds locks, an old snapshot, and can block vacuum (chapter 16) and DDL. Set `idle_in_transaction_session_timeout` for application roles.
- **Handle commit failure.** `COMMIT` itself can fail (a deferred constraint, a serialization failure, a full disk). If it fails, the transaction is rolled back; do not report success to the user. A lost network response after commit is ambiguous, which is why business operations need idempotency keys (chapter 25).
- **Choose isolation deliberately.** Default `READ COMMITTED` plus atomic statements covers most needs. Use `REPEATABLE READ` for stable multi-statement reads. Use `SERIALIZABLE` for cross-row invariants and budget for retries.
- **Remember that DDL is transactional.** You can `BEGIN; ALTER TABLE ...; ROLLBACK;` in PostgreSQL, which is valuable for safe migrations. A few commands, such as `CREATE INDEX CONCURRENTLY`, cannot run inside a transaction block (chapters 8 and 26).

## Monitoring transactions

Long or forgotten transactions are a common production problem. Find them:

```sql
SELECT pid, usename, state, xact_start,
       now() - xact_start AS transaction_age,
       wait_event_type, wait_event,
       left(query, 60) AS last_query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start;
```

Look for `idle in transaction` and for increasing `transaction_age`. Lock waits and blocking sessions are covered in chapter 17. Useful timeouts:

```sql
SET idle_in_transaction_session_timeout = '30s';
SET statement_timeout = '5s';
SET lock_timeout = '1s';
```

Set these at the role or database level for applications; use `SET LOCAL` inside a specific transaction or job when the defaults do not fit.

## Exercises

1. Try to produce a dirty read in two sessions. What does B see while A has an uncommitted update? Roll back A and explain why PostgreSQL can make this guarantee.
2. Reproduce a phantom read with `products` and the `Fiction` category, first at `READ COMMITTED` and then at `REPEATABLE READ`. Which level prevents it, and why?
3. Reproduce read skew with two accounts and a transfer. Show the inconsistent total, then show that `REPEATABLE READ` gives a consistent snapshot. Why is a single `SELECT sum(balance)` already safe at `READ COMMITTED`?
4. Reproduce the lost update from the lab, then fix it with one atomic `UPDATE`. Confirm the final stock is `38`. Then try the same experiment under `REPEATABLE READ`: what changes?
5. In `REPEATABLE READ`, A reads product 1, B updates and commits it, then A tries to update it. What error appears? What must the application do, and why is retrying only the failed statement wrong?
6. Create `bank_accounts(id, balance CHECK (balance >= 0))` and write a money transfer as one transaction. Show that a failed second statement leaves the first undone. What does `COMMIT` do after the error?
7. Reproduce the on-call write skew under `REPEATABLE READ`, then under `SERIALIZABLE`. What does the retry see, and what should the application do? How could explicit locking prevent it?
8. Find sessions that are idle in a transaction. Set a timeout so they cannot hold locks forever. Why does this matter for vacuum?

??? note "Solutions"

    ```sql
    -- 1  B sees the last committed stock (40), not A's 5. Readers use committed row versions, so an uncommitted
    --    change is invisible. This is MVCC, not locking: B does not even have to wait.

    -- 2  At READ COMMITTED the second count includes B's inserted row; at REPEATABLE READ both counts are equal
    --    because the whole transaction uses the snapshot taken at its first query.
    BEGIN;  -- READ COMMITTED
    SELECT count(*) FROM products WHERE category_id = (SELECT id FROM categories WHERE name = 'Fiction');
    -- B: INSERT INTO products (category_id, name, price, stock)
    --    VALUES ((SELECT id FROM categories WHERE name = 'Fiction'), 'Phantom', 1, 1);
    SELECT count(*) FROM products WHERE category_id = (SELECT id FROM categories WHERE name = 'Fiction');  -- +1
    COMMIT;

    -- 3  A reads account 1 (100), B transfers 10 from 1 to 2 and commits, A reads account 2 (110): total 210.
    --    REPEATABLE READ keeps both reads on the same snapshot, so the total is 200. One SELECT is consistent
    --    at READ COMMITTED because a single statement has a single snapshot; the problem is combining statements.
    UPDATE accounts SET balance = 100;
    -- A: BEGIN; SELECT balance FROM accounts WHERE id = 1;        -- 100
    -- B: BEGIN; UPDATE accounts SET balance = balance - 10 WHERE id = 1;
    --           UPDATE accounts SET balance = balance + 10 WHERE id = 2; COMMIT;
    -- A: SELECT balance FROM accounts WHERE id = 2;                -- 110, total 210
    --    Repeat A with BEGIN ISOLATION LEVEL REPEATABLE READ; the second read is 100.

    -- 4  Both read 40 and write 39, so one decrement is lost. The atomic form locks the row and re-evaluates
    --    the condition on the latest version, so the two updates apply in sequence and the result is 38.
    UPDATE products SET stock = 40 WHERE id = 1;
    UPDATE products SET stock = stock - 1 WHERE id = 1 AND stock > 0;
    SELECT stock FROM products WHERE id = 1;                       -- 38
    -- Under REPEATABLE READ the second writer gets 40001 instead of overwriting; the application retries and
    -- then performs the decrement from the fresh snapshot.

    -- 5  ERROR: could not serialize access due to concurrent update (SQLSTATE 40001). Roll back and retry the
    --    whole transaction in a new one. The old transaction is aborted and its earlier reads used the old snapshot;
    --    retrying only the statement cannot make the transaction valid again.

    -- 6
    CREATE TABLE bank_accounts (
        id int PRIMARY KEY,
        balance numeric NOT NULL CHECK (balance >= 0)
    );
    INSERT INTO bank_accounts VALUES (1, 100), (2, 0);
    BEGIN;
    UPDATE bank_accounts SET balance = balance + 150 WHERE id = 2;   -- ok
    UPDATE bank_accounts SET balance = balance - 150 WHERE id = 1;   -- ERROR: CHECK violated
    ROLLBACK;
    SELECT * FROM bank_accounts;                                     -- unchanged: (1,100), (2,0)
    -- COMMIT after the error reports ROLLBACK and leaves the data unchanged; PostgreSQL refuses to commit
    -- an aborted transaction.

    -- 7  Under REPEATABLE READ both transactions commit and leave zero doctors on call. Under SERIALIZABLE one
    --    gets 40001; on retry it sees one doctor on call, so the application must reject taking the last doctor
    --    off call. To prevent it with locks: SELECT * FROM doctors WHERE on_call FOR UPDATE; (not an aggregate),
    --    then count and update inside the same transaction.

    -- 8
    SELECT pid, state, xact_start, now() - xact_start AS age, left(query, 60)
    FROM pg_stat_activity
    WHERE state LIKE 'idle in transaction%';
    SET idle_in_transaction_session_timeout = '30s';
    -- Old snapshots prevent vacuum from removing dead row versions (chapter 16) and the session keeps its locks.
    ```

Next: [13. Indexes](13-indexes.md)
