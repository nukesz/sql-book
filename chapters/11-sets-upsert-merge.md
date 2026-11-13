---
hide:
  - toc
---

# 11. Set Operations, Upsert and MERGE

**You will learn:** combining result sets, and the "insert or update" patterns that every real application needs.

## Set operations

So far we have combined data horizontally: joins add *columns* from another table to each row. **Set operations** work vertically instead—they stack the *rows* of one query on top of another. The mental model is ordinary set algebra: union, intersection, difference.

This is useful whenever the same kind of fact lives in more than one place. Customers who are in one group *or* another, ids that appear in both lists, rows present in one table but missing from another. A join cannot express "these rows plus those rows"; a set operation can.

The rule is simple but strict: both queries must return the **same number of columns**, in the same order, with **compatible types**. The column names come from the *first* query, and a single `ORDER BY` at the end sorts the combined result.

```sql
SELECT email FROM customers WHERE country = 'HU'
UNION            -- distinct union
SELECT email FROM customers WHERE phone IS NULL;

-- UNION ALL keeps duplicates and is cheaper (no dedup): prefer it when duplicates are impossible or fine.
SELECT 'order' AS kind, id, created_at FROM orders
UNION ALL
SELECT 'customer', id, created_at FROM customers
ORDER BY created_at DESC LIMIT 10;

SELECT customer_id FROM orders WHERE status = 'paid'
INTERSECT        -- in both
SELECT customer_id FROM orders WHERE status = 'cancelled';

SELECT id FROM customers
EXCEPT           -- in the first, not the second
SELECT customer_id FROM orders;
```

The four operators differ only in how they combine the two row sets:

- `UNION` returns every row from both sides and removes duplicates.
- `UNION ALL` returns every row from both sides and **keeps** duplicates. It is the cheap one: no deduplication, no sort. Prefer it unless you actually need distinct rows.
- `INTERSECT` returns rows that appear on **both** sides.
- `EXCEPT` returns rows from the **first** query that do not appear in the second.

`UNION`, `INTERSECT`, and `EXCEPT` all remove duplicates by default. That deduplication is real work—PostgreSQL has to sort or hash the whole result—so `UNION ALL` is usually the fastest option when you know duplicates cannot occur or do not matter. `INTERSECT ALL` and `EXCEPT ALL` also exist when you want multiset behaviour instead.

Two details are worth remembering. First, set operations treat `NULL` as *equal to itself*, unlike `=` (chapter 7), so `NULL` rows are matched and deduplicated normally. Second, `INTERSECT` binds more tightly than `UNION` and `EXCEPT`; when you mix operators, add parentheses to make the grouping obvious rather than relying on precedence.

A set operation is also a natural way to compare two sources: `EXCEPT` in both directions tells you what is missing from each side. But when the question is "which rows have no match?", `NOT EXISTS` is often clearer and handles `NULL` more predictably—we will compare the two in the exercises.

## INSERT ... ON CONFLICT (upsert)

Applications constantly need the same pattern: *insert this row, but if it already exists, update it instead*. The naive implementation is a `SELECT` to check, followed by an `INSERT` or `UPDATE` from the application. That is a **race condition**: two concurrent requests can both run the `SELECT`, both see "not found", and both try to insert—one of them fails, or you get duplicates if there is no constraint.

`INSERT ... ON CONFLICT` closes that gap by making the check and the write a **single atomic statement**. The database resolves the conflict itself, under the same lock that protects the row, so concurrent callers cannot slip between the check and the write.

```sql
-- needs a unique index / constraint on the conflict target
INSERT INTO customers (email, name, country)
VALUES ('ada@example.com', 'Ada L.', 'HU')
ON CONFLICT (email) DO UPDATE
    SET name = EXCLUDED.name,
        country = EXCLUDED.country
RETURNING id, name, country;

INSERT INTO customers (email, name, country)
VALUES ('ada@example.com', 'Ada', 'HU')
ON CONFLICT (email) DO NOTHING;             -- silently skip; RETURNING gives no row when skipped
```

Read the statement in three parts. The `INSERT` part proposes a row. `ON CONFLICT (email)` names the **conflict target**—the unique index or constraint that decides whether a row "already exists"; without such an index PostgreSQL cannot detect the conflict. The action after it says what to do when the conflict happens.

`EXCLUDED` is a special pseudo-table that refers to **the row you tried to insert**. That is how `DO UPDATE` can copy the proposed values into the existing row. `DO NOTHING` simply leaves the existing row untouched.

`RETURNING` is especially handy with upserts: `DO UPDATE` returns the final row, so the application gets the id whether the row was inserted or updated. `DO NOTHING` returns **no row** when the conflict was skipped, which is a useful signal but also a trap if you assumed you would always get one.

Two practical cautions. The conflict target must correspond to a unique constraint or unique index; otherwise the statement is rejected. And a single `INSERT ... ON CONFLICT` cannot affect the same row twice—if the `VALUES` list itself contains two rows with the same key, PostgreSQL raises an error instead of silently picking one.

### Updating only when needed

A `DO UPDATE` always writes a new row version, even if every value is unchanged. PostgreSQL does not modify a row in place: it writes the new version and leaves the old one behind as a **dead tuple**, whose space `VACUUM` later reclaims (chapter 16). When writes are frequent and most conflicts change nothing, that churn adds up, so add a `WHERE` to `DO UPDATE` so the update only happens when something actually differs:

```sql
... ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name
    WHERE customers.name IS DISTINCT FROM EXCLUDED.name;
```

`IS DISTINCT FROM` treats `NULL`s as comparable values, so it behaves correctly when either side is `NULL`—unlike `<>`, which would evaluate to `NULL` and skip a genuine change.

### Counters

The upsert is also the standard way to maintain an atomic counter. Incrementing a value is a read-modify-write, so doing it in application code has the same lost-update problem as the insert race; letting the database perform the arithmetic inside `ON CONFLICT` avoids it.

```sql
CREATE TABLE page_views (page text PRIMARY KEY, views bigint NOT NULL DEFAULT 0);
INSERT INTO page_views (page) VALUES ('/home')
ON CONFLICT (page) DO UPDATE SET views = page_views.views + 1;
```

On the first call the row is inserted with the default `0`. On every later call the conflict path runs, reads the current value, adds one, and writes it back—all as one statement. It is safe under concurrency because the conflicting row is locked during the update, so two increments cannot read the same old value and overwrite each other.

## MERGE (PostgreSQL 15+)

`MERGE` is the SQL-standard way to **synchronize a target table from a source**: compare the two, then insert, update, or delete depending on what matches. It is the tool for bulk synchronization—loading a nightly feed, reconciling a staging table, applying a batch of changes—where `ON CONFLICT` would require one statement per row.

The shape is always the same: a target, a source, a join condition that decides what "matches", and one or more `WHEN` clauses describing the action for each case.

```sql
CREATE TEMP TABLE stock_feed (product_id bigint, qty int);  -- scratch source, gone when the session ends
INSERT INTO stock_feed VALUES (1, 50), (2, 0), (9999, 5);

MERGE INTO products p
USING stock_feed f ON p.id = f.product_id
WHEN MATCHED AND f.qty = 0 THEN UPDATE SET stock = 0, tags = array_append(tags, 'soldout')
WHEN MATCHED THEN UPDATE SET stock = f.qty
WHEN NOT MATCHED THEN DO NOTHING;
```

Here `products` is the target, `stock_feed` is the source, and `p.id = f.product_id` is the match condition. For each source row PostgreSQL asks: did we find a target row? If yes, the `WHEN MATCHED` clauses apply; if no, the `WHEN NOT MATCHED` clause applies. The first clause also shows that a `WHEN` can carry its own condition (`AND f.qty = 0`), letting you handle special cases before the general one.

The order matters: `WHEN` clauses are tested **from top to bottom**, and **at most one action runs for each candidate row**. That is why the narrower condition (`f.qty = 0`) must come before the general `WHEN MATCHED`—otherwise the general update would consume every matched row and the sold-out branch would never run. (`RETURNING` for `MERGE` arrived in PG 17, so older versions cannot report the affected rows directly.)

Choosing between the two tools comes down to shape and concurrency. `MERGE` is more flexible: multiple conditional actions, inserts and updates and deletes in one statement, driven by a whole source set. `ON CONFLICT` is simpler and has stronger guarantees for **concurrent inserts of the same key**, because it is built around the unique index. A good rule of thumb: use `ON CONFLICT` for single-row upserts from an application, and `MERGE` for bulk sync jobs where one statement processes many rows.

## Bulk loading

When you need to load many rows, the cost is dominated by per-statement overhead and per-row work, not by the data itself. Three approaches, from slowest to fastest, illustrate the trade-off.

The slowest is one `INSERT` per row: every statement is parsed, planned, executed, and committed (or at least sent over the network) separately. A single **multi-row** `INSERT`—`INSERT INTO t VALUES (...), (...), (...)`—amortizes that overhead across many rows and is a big improvement for modest batches.

For large loads, `COPY` is the fastest path because it bypasses most of the normal statement machinery and streams rows directly into the table:

```sql
-- fastest: COPY (server-side) or \copy (client-side file, in psql)
\copy customers (email, name, country) FROM 'new_customers.csv' CSV HEADER
COPY (SELECT * FROM products) TO STDOUT WITH CSV HEADER;
```

The distinction between the two commands matters. `COPY` is a **server-side** command: the file path is resolved on the database server, so it only works where the server can see the file. `\copy` is a **psql meta-command** that runs `COPY` on the server but reads or writes the file on the **client**, which is usually what you want from your own machine. `CSV HEADER` says the first line contains column names, and the column list tells PostgreSQL which fields to map.

`COPY` is also the natural export tool: `COPY (SELECT ...) TO STDOUT` streams a query result out in CSV or text form. The general ranking to remember is: one multi-row `INSERT` beats many single inserts, and `COPY` beats both. For repeatable bulk loads, load into a staging table with `COPY`, validate and transform there, then merge into the real table with `MERGE`.

## Exercises

1. Which customers never placed an order? Write it with `EXCEPT`, then with `NOT EXISTS`.
2. Create `product_stats(product_id PK, units_sold bigint)`. Fill it with a single `INSERT ... SELECT`, then re-run the statement using `ON CONFLICT DO UPDATE` so it can be refreshed repeatedly.
3. Show that two concurrent "insert if not exists" calls are safe with `ON CONFLICT DO NOTHING`. (Open two psql sessions: `BEGIN` + insert the same email in both, and observe the second blocks until the first commits.)
4. Combine `UNION ALL` of orders and customers into an "activity feed" with `kind`, `id`, `at`.
5. Export the sales summary by country to CSV with `\copy (SELECT ...) TO 'out.csv' CSV HEADER`.

??? note "Solutions"

    ```sql
    -- 1
    SELECT id FROM customers EXCEPT SELECT customer_id FROM orders;
    SELECT id FROM customers c WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id);
    -- 2
    CREATE TABLE product_stats (product_id bigint PRIMARY KEY REFERENCES products(id), units_sold bigint NOT NULL);
    INSERT INTO product_stats
    SELECT product_id, sum(quantity) FROM order_items GROUP BY product_id
    ON CONFLICT (product_id) DO UPDATE SET units_sold = EXCLUDED.units_sold;
    -- 3  Session B's INSERT waits; when A commits, B does nothing (or updates, with DO UPDATE); when A rolls back, B inserts.
    -- 4
    SELECT 'order' AS kind, id, created_at AS at FROM orders UNION ALL SELECT 'customer', id, created_at FROM customers ORDER BY at DESC;
    -- 5
    \copy (SELECT c.country, count(*) FROM orders o JOIN customers c ON c.id = o.customer_id GROUP BY 1) TO 'out.csv' CSV HEADER
    ```

Next: [12. Transactions and Isolation](12-transactions.md)
