---
hide:
  - toc
---

# 26. Flyway and Zero-Downtime Migrations

**You will learn:** how Quarkus and Flyway version a schema, why a migration must work during a rolling deployment, how to backfill large tables safely, and how to recover from migration failures without rewriting history.

## Why migrations are application code

Application version B may require a column that version A does not know about. During a rolling deployment, both versions can run at the same time. A schema change is safe only when it respects that overlap.

A migration tool records which changes ran, in which order, and with which checksum. Flyway stores this history in `flyway_schema_history`. It does not make an unsafe `ALTER TABLE` safe; it makes execution repeatable and visible.

## Quarkus setup

Add the Flyway extension alongside the PostgreSQL JDBC extension:

```xml
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-flyway</artifactId>
</dependency>
```

The default location is usually:

```
src/main/resources/db/migration/
```

Versioned files follow this shape:

```
V1__create_shop_schema.sql
V2__add_product_version.sql
V3__create_idempotency_keys.sql
```

The version determines order; the description documents intent. Use names that explain the business change, not names such as `fix.sql`.

```properties
quarkus.flyway.locations=db/migration
quarkus.flyway.validate-at-start=true
quarkus.flyway.migrate-at-start=false
```

Validation checks that applied versioned migrations still match their recorded checksums. In production, running migrations as a separate deployment step is often safer than `migrate-at-start=true` on every application replica: it avoids multiple instances racing to change the schema and separates migration failure from application startup.

## Never edit an applied migration

After `V3` has reached a shared environment, treat it as immutable. Editing it creates different histories with the same version and causes checksum failures.

If `V3` is wrong, add `V4` that moves the schema from the current state to the desired state. This **forward-fix** principle provides one auditable path for every environment.

Development databases that only you use can be rebuilt, but do not normalize that habit into production procedures.

## Transactional and non-transactional migrations

PostgreSQL supports transactional DDL:

```sql
BEGIN;
ALTER TABLE products ADD COLUMN version bigint NOT NULL DEFAULT 0;
COMMIT;
```

If a statement fails, Flyway can roll back the migration. This is a major safety advantage.

Some operations cannot run inside a transaction block, notably `CREATE INDEX CONCURRENTLY`:

```sql
CREATE INDEX CONCURRENTLY orders_customer_created_idx
ON orders (customer_id, created_at DESC);
```

Such a migration must be configured as non-transactional using the mechanism supported by your Flyway version, for example a companion script configuration file:

```properties
# V12__index_orders.sql.conf
executeInTransaction=false
```

A non-transactional migration can fail after making partial changes. Make the recovery procedure explicit and check for an invalid index before retrying.

## Expand, migrate, contract

Renaming `customers.phone` directly breaks application versions still selecting it. Use compatible stages.

### 1. Expand

Add the new representation without removing the old one:

```sql
ALTER TABLE customers ADD COLUMN mobile text;
```

Deploy code that can read the new column with a fallback and writes both columns:

```sql
SELECT coalesce(mobile, phone) AS mobile
FROM customers
WHERE id = ?;
```

When updating, write both representations in one SQL statement and one transaction. Two unrelated application calls can fail between writes and make the columns disagree.

### 2. Migrate data

Backfill existing rows in small committed batches:

```sql
WITH batch AS (
    SELECT id
    FROM customers
    WHERE mobile IS NULL
      AND phone IS NOT NULL
    ORDER BY id
    LIMIT 5000
    FOR UPDATE SKIP LOCKED
)
UPDATE customers c
SET mobile = c.phone
FROM batch
WHERE c.id = batch.id;
```

Repeat until zero rows change. Each batch is a short transaction, limiting locks, WAL volume, replication lag, and dead tuples. `SKIP LOCKED` permits multiple controlled workers, though one worker is often simpler.

### 3. Switch

Verify the backfill and deploy code that reads only `mobile`. Stop writing `phone`, but leave it in place while old application instances drain.

### 4. Contract

In a later release:

```sql
ALTER TABLE customers DROP COLUMN phone;
```

The delay is the safety mechanism. Expand and contract in the same deployment is not zero-downtime compatibility.

## Adding constraints to existing data

A new constraint has two questions:

1. Do new writes obey it?
2. Does all historical data already obey it?

`NOT VALID` separates those concerns:

```sql
ALTER TABLE order_items
ADD CONSTRAINT order_items_product_fk
FOREIGN KEY (product_id) REFERENCES products (id)
NOT VALID;
```

New writes are checked immediately. After cleaning historical violations:

```sql
ALTER TABLE order_items
VALIDATE CONSTRAINT order_items_product_fk;
```

Validation scans the table with a less disruptive lock than adding and validating the constraint in one step.

For `NOT NULL` on a large table:

```sql
ALTER TABLE customers
ADD CONSTRAINT customers_mobile_present
CHECK (mobile IS NOT NULL) NOT VALID;

ALTER TABLE customers
VALIDATE CONSTRAINT customers_mobile_present;

ALTER TABLE customers
ALTER COLUMN mobile SET NOT NULL;

ALTER TABLE customers
DROP CONSTRAINT customers_mobile_present;
```

On supported PostgreSQL versions, the validated check allows `SET NOT NULL` to avoid another full validation scan. Test this workflow on your actual version.

## Defaults and volatile work

Modern PostgreSQL can add a column with a constant default without rewriting every row:

```sql
ALTER TABLE products
ADD COLUMN version bigint NOT NULL DEFAULT 0;
```

Do not generalize this to every expression or type change. A volatile default, column type conversion, or generated value may rewrite the table. Inspect documentation and test with production-like size.

## Lock management

Even fast DDL may need an `ACCESS EXCLUSIVE` lock briefly. A long transaction can make it wait, and the waiting DDL can form a lock queue.

Protect deployment availability:

```sql
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';
ALTER TABLE orders ADD COLUMN external_reference text;
```

In a normal transactional Flyway migration, `SET LOCAL` keeps these values scoped to that transaction. Failing quickly is better than freezing application traffic. A deployment job can retry later with bounded attempts after the blocker is understood.

Do not set an arbitrarily large timeout just to force a migration through. First inspect the lock holder and choose a safe time.

## Startup ownership

Choose exactly one production migration owner:

- a deployment job before application rollout;
- a dedicated migration task;
- one explicitly elected application instance.

The migration role owns schema changes. The runtime application role should normally lack `CREATE`, `ALTER`, and `DROP`. This limits damage from bugs and injection.

## Testing migrations

An empty database proves only that all migrations can build the current schema. It does not prove that an upgrade works with old data.

Test both:

1. **from empty:** apply every migration in order;
2. **from previous production:** restore or construct the previous schema and representative data, then apply only new migrations.

Also test:

- rows containing old `NULL`s and unusual values;
- enough data to expose lock and rewrite duration;
- old and new application versions against the expanded schema;
- migration interruption and rerun behavior;
- indexes and constraints after migration.

## Exercises

1. Place these actions into expand, migrate, switch, and contract: add `mobile`, backfill, deploy dual-write code, stop reading `phone`, drop `phone`.
2. Explain why editing `V7` after production deployment is worse than adding `V8`.
3. Add a foreign key to a large table using `NOT VALID`. When are new rows checked?
4. A backfill updates ten million rows in one transaction. List four production effects and redesign it.
5. Explain why `CREATE INDEX CONCURRENTLY` needs special Flyway handling and what may remain after failure.
6. Design two migration test paths: an empty installation and an upgrade from the previous release.
7. Decide whether migrations run at application startup or in a deployment job for a five-replica service. State the trade-off.

??? note "Solutions"

    1. Expand: add `mobile`, then deploy compatible dual-write/read-fallback code. Migrate: backfill. Switch: deploy code reading and writing only `mobile`, then wait for old replicas to drain. Contract: drop `phone` in a later release.
    2. Applied migrations are shared history. Editing one changes its checksum and gives environments different schemas for the same version. A new migration records the correction consistently.
    3. New and changed rows are checked as soon as the `NOT VALID` constraint exists. `VALIDATE CONSTRAINT` checks historical rows.
    4. Effects include long locks, large WAL, replication lag, bloat, a long rollback, and delayed vacuum. Update ordered batches in separate short transactions, measure progress, and throttle if replicas or latency suffer.
    5. PostgreSQL forbids it in a transaction block. Configure that script as non-transactional. Failure may leave an invalid index that must be inspected and dropped before retry.
    6. Empty installation applies all scripts. Upgrade testing first creates/restores the previous released schema with representative edge-case data, then applies only the new scripts and runs compatibility checks.
    7. A deployment job gives one owner, clearer failure reporting, and controlled ordering before rollout. Startup migration is simpler for small systems but couples every replica's startup to schema authority and failure.

Next: [27. Outbox Messaging and External Side Effects](27-outbox-messaging.md)
