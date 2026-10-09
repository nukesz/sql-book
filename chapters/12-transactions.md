---
hide:
  - toc
---

# 12. Transactions and Isolation

**You will learn:** ACID, how to use transactions, what isolation levels actually protect you from, and how to demonstrate it yourself with two psql sessions.

## What is a transaction?

A group of statements that succeed or fail **as a unit**.

```sql
BEGIN;
UPDATE products SET stock = stock - 1 WHERE id = 1 AND stock > 0;
INSERT INTO order_items (order_id, line_no, product_id, quantity, unit_price)
VALUES (1, 99, 1, 1, 10.00);
COMMIT;      -- make both permanent   (or ROLLBACK; to undo both)
```

Outside an explicit `BEGIN`, every statement is its own transaction (autocommit). If any statement inside a transaction errors, the transaction is **aborted**: all further statements fail until you `ROLLBACK`.

### Savepoints

```sql
BEGIN;
INSERT ...;
SAVEPOINT s1;
INSERT ... ;               -- fails?
ROLLBACK TO SAVEPOINT s1;  -- undo only back to s1; transaction continues
COMMIT;
```

## ACID

- **Atomicity:** all or nothing.
- **Consistency:** a correct transaction takes the database from one valid state to another. PostgreSQL enforces declared constraints, but it cannot enforce business rules you never expressed in constraints, locking, or transaction logic.
- **Isolation:** concurrent transactions don't see each other's half-done work (to a degree you choose).
- **Durability:** once committed, survives a crash (the write-ahead log is flushed).

## Concurrency anomalies

When transactions overlap, these can happen:

| Anomaly | Meaning |
|---|---|
| Dirty read | reading another transaction's *uncommitted* data |
| Non-repeatable read | same row read twice gives different values (someone committed in between) |
| Phantom read | same query twice returns different *sets* of rows |
| Lost update | two read-modify-write cycles overwrite one another |
| Write skew | two transactions each check a condition on overlapping data and then update *different* rows, jointly breaking an invariant |

## Isolation levels in PostgreSQL

| Level | Dirty | Non-repeatable | Phantom | Write skew |
|---|---|---|---|---|
| `READ COMMITTED` (default) | no | possible | possible | possible |
| `REPEATABLE READ` | no | no | no (in PG) | possible |
| `SERIALIZABLE` | no | no | no | no |

(PostgreSQL never allows dirty reads; `READ UNCOMMITTED` behaves as `READ COMMITTED`.)

- **READ COMMITTED:** each *statement* sees a snapshot of data committed before the statement began.
- **REPEATABLE READ:** the whole *transaction* sees one snapshot taken at its first statement. Updating a row changed by someone else since then fails with `could not serialize access due to concurrent update`; **your application must retry**.
- **SERIALIZABLE:** behaves as if transactions ran one at a time. Conflicts raise error `40001` (serialization_failure) - again, retry the entire transaction.

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
-- or: SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;  (first statement in the transaction)
```

## Lab: see it yourself (two psql windows, A and B)

### Non-repeatable read (READ COMMITTED)

```sql
-- A
BEGIN;
SELECT stock FROM products WHERE id = 1;      -- say 40
-- B
UPDATE products SET stock = 5 WHERE id = 1;   -- autocommit
-- A
SELECT stock FROM products WHERE id = 1;      -- 5   <- changed within A's transaction
COMMIT;
```

Repeat with `BEGIN ISOLATION LEVEL REPEATABLE READ;` in A: it keeps seeing 40.

### Lost update

```sql
-- A and B both run (READ COMMITTED), interleaved:
BEGIN;
SELECT stock FROM products WHERE id = 1;       -- both read 40
-- application computes 40 - 1 = 39
UPDATE products SET stock = 39 WHERE id = 1;   -- both write 39: one decrement is lost
COMMIT;
```

Three fixes:

1. **Atomic update:** `UPDATE products SET stock = stock - 1 WHERE id = 1 AND stock > 0;` (best when possible; the row lock serializes writers).
2. **Pessimistic lock:** `SELECT ... FOR UPDATE` (next chapter).
3. **Optimistic locking:** add a `version` column; `UPDATE ... SET ..., version = version + 1 WHERE id = ? AND version = ?`; zero rows updated means someone else got there first, so retry.

### Write skew (needs SERIALIZABLE)

Rule: "at least one on-call doctor." Two doctors both check "2 on call" and both set themselves off-call, leaving zero. Neither transaction wrote the row the other read. Only `SERIALIZABLE` (or explicit locking of the checked rows) prevents this.

## Practical rules

- Keep transactions **short**; never wait for user input or call external services inside one.
- Pick the lowest level that is correct. Default `READ COMMITTED` + atomic statements + row locks covers most needs; use `SERIALIZABLE` where invariants span rows, and **always** code a retry loop for `40001` and `40P01` (deadlock).
- Long-open transactions are harmful: they hold back vacuum (chapter 16) and keep locks.
- Check `SELECT * FROM pg_stat_activity WHERE state = 'idle in transaction';` for forgotten transactions.

## Exercises

1. Reproduce the non-repeatable read lab in both isolation levels.
2. Reproduce the lost update, then fix it with the atomic form. Check the final stock to confirm both decrements were applied.
3. In `REPEATABLE READ`, have A read product 1, B update and commit it, then A try to update it. What error appears? What should the app do?
4. Create a table `accounts(id, balance CHECK (balance >= 0))` and write a money transfer as one transaction. Show that a failed second statement leaves the first undone.
5. Reproduce the on-call write skew with two sessions under `REPEATABLE READ`, then under `SERIALIZABLE`.

??? note "Solutions"

    ```sql
    -- 4
    CREATE TABLE accounts (id int PRIMARY KEY, balance numeric NOT NULL CHECK (balance >= 0));
    INSERT INTO accounts VALUES (1, 100), (2, 0);
    BEGIN;
    UPDATE accounts SET balance = balance + 150 WHERE id = 2;   -- ok
    UPDATE accounts SET balance = balance - 150 WHERE id = 1;   -- ERROR: CHECK violated, transaction aborted
    ROLLBACK;
    SELECT * FROM accounts;                                      -- unchanged
    -- 3  ERROR: could not serialize access due to concurrent update (SQLSTATE 40001) -> retry whole transaction.
    ```

Next: [13. Indexes](13-indexes.md)
