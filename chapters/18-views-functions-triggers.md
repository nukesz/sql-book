---
hide:
  - toc
---

# 18. Views, Functions and Triggers

**You will learn:** packaging SQL for reuse: views, materialized views, functions, procedures, triggers, and when *not* to use them.

## Views

A view is a **named query**. No data is stored; the query runs each time (and is inlined into the caller's query).

```sql
CREATE VIEW order_totals AS
SELECT o.id AS order_id, o.customer_id, o.status, o.created_at,
       sum(oi.quantity * oi.unit_price) AS total
FROM orders o JOIN order_items oi ON oi.order_id = o.id
GROUP BY o.id;

SELECT * FROM order_totals WHERE customer_id = 5;
CREATE OR REPLACE VIEW ...;     -- may add columns at the end, not remove/retype
```

Uses: hide join complexity, give a stable interface when tables change, and restrict access (expose some columns/rows only; `security_barrier`, chapter 20).

Simple views are *updatable* (`INSERT`/`UPDATE` pass through to the table).

## Materialized views

Store the result physically; refresh on demand. A cache you control.

```sql
CREATE MATERIALIZED VIEW daily_sales AS
SELECT created_at::date AS day, count(*) AS orders FROM orders GROUP BY 1;

CREATE UNIQUE INDEX ON daily_sales (day);
REFRESH MATERIALIZED VIEW daily_sales;                 -- locks out readers while it runs
REFRESH MATERIALIZED VIEW CONCURRENTLY daily_sales;    -- needs a unique index; readers keep working
```

Fits dashboards/reporting where slightly stale data is fine. Schedule refreshes with cron/`pg_cron`.

## Functions

### SQL functions

```sql
CREATE FUNCTION order_total(p_order_id bigint) RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT coalesce(sum(quantity * unit_price), 0) FROM order_items WHERE order_id = p_order_id
$$;

SELECT id, order_total(id) FROM orders LIMIT 5;
```

Volatility labels help the planner: `IMMUTABLE` (same input → same output forever; required for expression indexes), `STABLE` (constant within a statement; reads DB), `VOLATILE` (default; may change anything, e.g. `random()`).

Table-returning:

```sql
CREATE FUNCTION top_products(n int) RETURNS TABLE (id bigint, name text, units bigint)
LANGUAGE sql STABLE AS $$
    SELECT p.id, p.name, sum(oi.quantity) FROM products p JOIN order_items oi ON oi.product_id = p.id
    GROUP BY p.id ORDER BY 3 DESC LIMIT n
$$;
SELECT * FROM top_products(3);
```

### PL/pgSQL (procedural)

When you need variables, loops, conditionals, error handling:

```sql
CREATE FUNCTION place_item(p_order bigint, p_product bigint, p_qty int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_price numeric;
    v_line_no int;
BEGIN
    IF p_qty <= 0 THEN
        RAISE EXCEPTION 'quantity must be positive' USING ERRCODE = 'check_violation';
    END IF;

    -- Serialize line-number allocation for this order.
    PERFORM 1 FROM orders WHERE id = p_order FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'order % does not exist', p_order USING ERRCODE = 'foreign_key_violation';
    END IF;

    UPDATE products SET stock = stock - p_qty WHERE id = p_product AND stock >= p_qty
    RETURNING price INTO v_price;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'not enough stock for product %', p_product USING ERRCODE = 'check_violation';
    END IF;

    SELECT coalesce(max(line_no), 0) + 1 INTO v_line_no
    FROM order_items WHERE order_id = p_order;

    INSERT INTO order_items (order_id, line_no, product_id, quantity, unit_price)
    VALUES (p_order, v_line_no, p_product, p_qty, v_price);
END $$;
```

(The function runs inside the caller's transaction. If the exception escapes, the surrounding transaction is aborted until it is rolled back. Locking the order row prevents two calls for the same order from choosing the same next line number.)

### Procedures

`CREATE PROCEDURE ... ; CALL name(...)`. Unlike functions, a procedure invoked by a top-level `CALL` may `COMMIT`/`ROLLBACK` inside, which is useful for batch jobs. Transaction control is not allowed when `CALL` itself runs inside an explicit transaction block.

## Triggers

Code that runs automatically on `INSERT`/`UPDATE`/`DELETE`.

```sql
ALTER TABLE products ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();

CREATE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

CREATE TRIGGER products_set_updated_at
BEFORE UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

- `BEFORE` triggers can modify `NEW` or cancel the operation (return `NULL`); `AFTER` triggers see the final row.
- `FOR EACH ROW` vs `FOR EACH STATEMENT`; transition tables (`REFERENCING NEW TABLE AS ...`) enable efficient set-based statement triggers.
- Audit log example: `AFTER INSERT OR UPDATE OR DELETE` writing `to_jsonb(OLD)` / `to_jsonb(NEW)` into an `audit` table.

### Judgement: where should logic live?

| Good fit | Poor fit |
|---|---|
| invariants that must hold for every writer (constraints, audit, `updated_at`) | complex business workflows (hard to test, version, debug) |
| set-based data processing close to the data | anything calling external services |
| performance-critical multi-step operations (avoids round trips) | "hidden" side effects that surprise application developers |

Triggers are invisible to the code that fires them, so use sparingly and document them. Prefer constraints > generated columns > views > functions > triggers, roughly in that order.

## Listen / Notify

Lightweight pub/sub built into PostgreSQL:

```sql
LISTEN order_created;                              -- in the consumer session
NOTIFY order_created, '{"id": 42}';                -- or SELECT pg_notify('order_created', '...');
```

Handy to wake workers instead of polling; not durable (messages are lost if nobody is listening).

## Exercises

1. Create the `order_totals` view and use it to find the 10 biggest orders.
2. Create `daily_sales` as a materialized view, add a unique index, and do a concurrent refresh while another session reads it.
3. Write an SQL function `customer_lifetime_value(bigint)` and use it for the top 5 customers.
4. Create the `set_updated_at` trigger and prove `updated_at` changes on update but only for the changed row.
5. Write an audit trigger on `products` storing `(changed_at, operation, old_row jsonb, new_row jsonb)`.
6. Make `place_item` fail on insufficient stock and confirm the failed call leaves stock and items unchanged.

??? note "Solutions"

    ```sql
    -- 1
    SELECT * FROM order_totals ORDER BY total DESC LIMIT 10;
    -- 3
    CREATE FUNCTION customer_lifetime_value(p_id bigint) RETURNS numeric LANGUAGE sql STABLE AS $$
      SELECT coalesce(sum(oi.quantity * oi.unit_price), 0) FROM orders o JOIN order_items oi ON oi.order_id = o.id
      WHERE o.customer_id = p_id AND o.status <> 'cancelled' $$;
    SELECT id, customer_lifetime_value(id) v FROM customers ORDER BY v DESC LIMIT 5;
    -- 5
    CREATE TABLE product_audit (changed_at timestamptz DEFAULT now(), operation text, old_row jsonb, new_row jsonb);
    CREATE FUNCTION audit_products() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO product_audit (operation, old_row, new_row)
      VALUES (TG_OP, CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END, CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
      RETURN NULL;
    END $$;
    CREATE TRIGGER products_audit AFTER INSERT OR UPDATE OR DELETE ON products FOR EACH ROW EXECUTE FUNCTION audit_products();
    ```

Next: [19. Partitioning](19-partitioning.md)
