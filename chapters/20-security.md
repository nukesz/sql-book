---
hide:
  - toc
---

# 20. Security: Roles, Row-Level Security and SQL Injection

**You will learn:** least-privilege roles, row-level security for multi-tenancy, and how to prevent SQL injection.

## Roles and privileges

Users and groups are both **roles**.

```sql
CREATE ROLE readonly NOLOGIN;                           -- a group-like role
GRANT CONNECT ON DATABASE shop TO readonly;
GRANT USAGE ON SCHEMA public TO readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly;   -- future tables too

CREATE ROLE reporter LOGIN PASSWORD 'change-me' IN ROLE readonly;
CREATE ROLE app LOGIN PASSWORD 'change-me';
GRANT SELECT, INSERT, UPDATE, DELETE ON orders, order_items TO app;
GRANT SELECT ON customers, products TO app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app;
```

Column-level: `GRANT SELECT (id, name, country) ON customers TO reporter;` hides `email`/`phone`.

Check: `\dp orders` shows privileges; `SET ROLE reporter; SELECT ...; RESET ROLE;` to test as that user.

### Least privilege

- Applications connect as a dedicated role with only the DML rights they need, **not** as the owner/superuser.
- Migrations run as a different role (the owner) than the running application.
- Revoke the default `CREATE` on `public` schema for ordinary users (default since PG 15): `REVOKE CREATE ON SCHEMA public FROM PUBLIC;`
- Passwords: use `scram-sha-256` authentication (`pg_hba.conf`) and TLS in real deployments.

## Row-level security (RLS)

Restrict *which rows* a role can see or change, enforced inside the database; ideal for multi-tenant apps.

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

-- app sets who is calling for the current transaction
CREATE POLICY own_orders ON orders
    USING (customer_id = nullif(current_setting('app.customer_id', true), '')::bigint)
    WITH CHECK (customer_id = nullif(current_setting('app.customer_id', true), '')::bigint);

-- in the application, per request/transaction:
BEGIN;
SET LOCAL app.customer_id = '42';          -- or: SELECT set_config('app.customer_id', '42', true);
SELECT * FROM orders;                      -- only customer 42's orders
COMMIT;
```

- `USING` filters visible/updatable existing rows; `WITH CHECK` validates new/changed rows.
- Table **owners and superusers bypass RLS** unless `ALTER TABLE ... FORCE ROW LEVEL SECURITY`. Test with a non-owner role.
- Use `SET LOCAL` (transaction-scoped), so a pooled connection never leaks a previous user's value.
- RLS adds predicates to every query: index the policy columns.
- A custom setting is context, not authentication. Set it only from identity already verified by the application, never from an untrusted request parameter. If users can issue arbitrary SQL as the policy role, they can change the setting themselves.

## SQL injection

Occurs when user input is **concatenated into SQL text**, so data becomes code.

```java
// DANGEROUS (any language)
String sql = "SELECT * FROM customers WHERE email = '" + email + "'";
// email = ' OR '1'='1      -> returns everyone
// email = '; DROP TABLE customers; --
```

### The fix: parameterized queries

The SQL text and the values travel **separately**; the database never parses values as SQL.

```java
PreparedStatement ps = conn.prepareStatement("SELECT * FROM customers WHERE email = ?");
ps.setString(1, email);
```

In psql you can see the idea with:

```sql
PREPARE find_customer(text) AS SELECT * FROM customers WHERE email = $1;
EXECUTE find_customer('user1@example.com');
```

Rules:

1. **Always** use parameters (`$1`, `?`, named parameters) for values: all ORMs/drivers support it.
2. Parameters can't replace **identifiers** (table/column names) or keywords (`ORDER BY` direction). For those, map user choices to a fixed whitelist in code (`"price"` → `price`), or quote with `format('%I', ident)` / `quote_ident()`.
3. Inside PL/pgSQL `EXECUTE`, use `USING` for values and `format('%I')` for identifiers: `EXECUTE format('SELECT count(*) FROM %I WHERE id = $1', tbl) USING v;`
4. The database role used by the application should have only the privileges it needs: injection damage is bounded.
5. Don't build `LIKE` patterns by concatenating raw input: escape `%` and `_` if the user shouldn't control wildcards.

## SECURITY DEFINER

Functions normally run with the caller's privileges. `SECURITY DEFINER` runs with the owner's, a controlled escalation (like `sudo`):

```sql
CREATE FUNCTION my_orders() RETURNS SETOF public.orders
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
    SELECT *
    FROM public.orders
    WHERE customer_id = nullif(current_setting('app.customer_id', true), '')::bigint
$$;

REVOKE ALL ON FUNCTION my_orders() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION my_orders() TO app;
```

Always pin `search_path`, schema-qualify sensitive objects, restrict `EXECUTE`, and keep the owner minimally privileged. Otherwise a caller may hijack unqualified names or gain more authority than intended. `SECURITY DEFINER` is not a shortcut around careful RLS and privilege design.

## Other practical points

- Don't log parameter values containing secrets/PII; consider `log_statement` settings carefully.
- Encrypt sensitive columns at the application layer if the database admin shouldn't read them; `pgcrypto` offers primitives.
- Back up, and **test restoring** (chapter 23).

## Exercises

1. Create `reporter` as above. Log in as it (or `SET ROLE reporter`) and try `SELECT` on `orders` and `DELETE`.
2. Give a role access to only `customers(id, name, country)` and verify `SELECT email` is denied.
3. Enable RLS on `orders` with the policy above. As a non-owner role, set `app.customer_id` and confirm filtering. Then try to insert an order for another customer and see `WITH CHECK` fail.
4. Using PREPARE/EXECUTE, show that passing `' OR '1'='1` returns nothing instead of everything.
5. Write a PL/pgSQL function `count_rows(tbl text)` that is safe against injection via `format('%I')`; test with `'orders; drop table x'`.
6. Name three reasons an application should not connect as `postgres`.

??? note "Solutions"

    ```sql
    -- 3
    CREATE ROLE tenant_app LOGIN PASSWORD 'x';
    GRANT SELECT, INSERT ON orders TO tenant_app;
    SET ROLE tenant_app; BEGIN; SET LOCAL app.customer_id = '42'; SELECT count(*) FROM orders;
    INSERT INTO orders (customer_id, status) VALUES (7, 'new');   -- ERROR: new row violates row-level security policy
    ROLLBACK; RESET ROLE;
    -- 5
    CREATE FUNCTION count_rows(tbl text) RETURNS bigint LANGUAGE plpgsql AS $$
    DECLARE n bigint; BEGIN EXECUTE format('SELECT count(*) FROM %I', tbl) INTO n; RETURN n; END $$;
    -- 6  Superuser bypasses RLS and all permissions; a bug/injection can destroy everything; no audit separation between app/admin.
    ```

Next: [21. Performance Tuning Workshop](21-tuning-workshop.md)
