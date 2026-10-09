---
hide:
  - toc
---

# 11. Set Operations, Upsert and MERGE

**You will learn:** combining result sets, and the "insert or update" patterns that every real application needs.

## Set operations

Both queries must return the same number of columns with compatible types.

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

## INSERT ... ON CONFLICT (upsert)

"Insert, and if the row already exists, do something else" - atomically. Doing `SELECT` then `INSERT`/`UPDATE` from the application is a **race condition** (two requests both see "not found" and both insert).

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

`EXCLUDED` refers to the row you tried to insert. Add `WHERE` to `DO UPDATE` to update only when something changed (avoids useless writes):

```sql
... ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name
    WHERE customers.name IS DISTINCT FROM EXCLUDED.name;
```

Do not use internal system columns such as `xmax` to decide whether an upsert inserted or updated a row. Their meaning is tied to PostgreSQL's storage implementation and can be surprising when rows are locked. If the application must distinguish the two outcomes, design an explicit API for it or use separate statements with application-level handling while preserving the required concurrency semantics.

### Counters

```sql
CREATE TABLE page_views (page text PRIMARY KEY, views bigint NOT NULL DEFAULT 0);
INSERT INTO page_views (page) VALUES ('/home')
ON CONFLICT (page) DO UPDATE SET views = page_views.views + 1;
```

Safe under concurrency, because the row is locked during the update.

## MERGE (PostgreSQL 15+)

SQL-standard synchronization of a target table from a source:

```sql
CREATE TEMP TABLE stock_feed (product_id bigint, qty int);
INSERT INTO stock_feed VALUES (1, 50), (2, 0), (9999, 5);

MERGE INTO products p
USING stock_feed f ON p.id = f.product_id
WHEN MATCHED AND f.qty = 0 THEN UPDATE SET stock = 0, tags = array_append(tags, 'soldout')
WHEN MATCHED THEN UPDATE SET stock = f.qty
WHEN NOT MATCHED THEN DO NOTHING;
```

The `WHEN` clauses are tested from top to bottom and at most one action runs for each candidate row, so put narrower conditions first. (`RETURNING` for `MERGE` arrived in PG 17.) `MERGE` is more flexible (multiple conditional actions, deletes); `ON CONFLICT` is simpler and has stronger guarantees for concurrent inserts of the same key. Use `ON CONFLICT` for single-row upserts, `MERGE` for bulk sync.

## Bulk loading

```sql
-- fastest: COPY (server-side) or \copy (client-side file, in psql)
\copy customers (email, name, country) FROM 'new_customers.csv' CSV HEADER
COPY (SELECT * FROM products) TO STDOUT WITH CSV HEADER;
```

One multi-row `INSERT` beats many single inserts; `COPY` beats both.

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
