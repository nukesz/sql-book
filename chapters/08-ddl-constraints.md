---
hide:
  - toc
---

# 8. Constraints and DDL

**You will learn:** what DDL is, how to create and alter tables, and how constraints make bad data impossible.

## What DDL means

**DDL** stands for **Data Definition Language**: the SQL statements that define and change the *structure* of the database — tables, columns, constraints, indexes and schemas — rather than the rows inside them. The core three are `CREATE` (make an object), `ALTER` (change it) and `DROP` (remove it). Changing rows with `INSERT`, `UPDATE` or `DELETE` is a different job, called **DML**.

A constraint belongs to the structure, so it is declared with DDL and then enforced by the database on every future write. The rest of this chapter uses DDL to create and change a table, then examines each kind of constraint.

## Why constraints: let the database enforce the rules

Application code has bugs, there may be more than one application, and people run ad-hoc scripts. A constraint is the only validation that **cannot be bypassed**.

## CREATE TABLE

A table definition lists the columns and the rules every row must satisfy:

```sql
CREATE TABLE reviews (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id  bigint NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    customer_id bigint NOT NULL REFERENCES customers (id),
    rating      int NOT NULL CHECK (rating BETWEEN 1 AND 5),
    body        text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (product_id, customer_id)          -- one review per customer per product
);
```

Read it as five decisions:

- **Generated id:** PostgreSQL fills `id` with the next number; callers never supply it.
- **References:** `product_id` and `customer_id` must point at existing rows. Deleting a referenced product deletes its reviews; deleting a referenced customer is blocked.
- **Value rules:** `rating` must be present and between 1 and 5. `body` is optional.
- **Default:** `created_at` is filled with the current time when it is omitted.
- **Uniqueness:** `(product_id, customer_id)` may appear only once, so one customer can review a product once.

Most constraints can be written next to the column or as a table constraint at the end. `UNIQUE (product_id, customer_id)` has to be at the table level because it spans two columns.

### Copying a table's shape

`CREATE TABLE ... (LIKE other_table)` creates a new **empty** table with the same columns and types as an existing one:

```sql
CREATE TABLE orders_archive (LIKE orders);                 -- columns only
CREATE TABLE orders_archive (LIKE orders INCLUDING ALL);   -- also constraints, indexes, defaults
```

Without `INCLUDING ALL`, the copy has the same shape but none of the constraints, indexes, or defaults, and no rows. It is a snapshot, not a link: later `ALTER TABLE orders` does not change `orders_archive`. This is handy for an archive table that should mirror the source's columns.

## The constraint toolbox

Each rule in the example comes from a small set of constraint types:

| Constraint | In `reviews` | Guarantees |
|---|---|---|
| `NOT NULL` | `rating int NOT NULL` | a value is present |
| `DEFAULT expr` | `created_at ... DEFAULT now()` | value used when omitted (not a constraint, but related) |
| `PRIMARY KEY` | `id ... PRIMARY KEY` | `UNIQUE` + `NOT NULL`, one per table |
| `UNIQUE` | `UNIQUE (product_id, customer_id)` | no duplicate values or pairs (creates an index) |
| `CHECK (cond)` | `CHECK (rating BETWEEN 1 AND 5)` | a row-level rule |
| `FOREIGN KEY` | `REFERENCES products (id)` | the referenced row exists (`REFERENCES` is the shorthand) |
| `EXCLUDE` | — not used here | no two rows "overlap" (e.g. room bookings; advanced) |

`CHECK` rejects a row only when the condition is **false**. If the condition is `NULL`, the row passes — so `CHECK (rating BETWEEN 1 AND 5)` does not stop a `NULL` rating. That is what `NOT NULL` is for (chapter 7).

Name constraints for readable errors and easier changes:

```sql
ALTER TABLE reviews ADD CONSTRAINT reviews_body_length_check CHECK (length(body) <= 2000);
```

A constraint name must be unique within its table. `PRIMARY KEY` and `UNIQUE` also create an index, and an index name must be unique within the schema. Because names appear in error messages, a useful convention is `<table>_<columns>_<kind>`, such as `reviews_rating_check`.

### Foreign key actions

```sql
REFERENCES products (id) ON DELETE CASCADE      -- delete children with parent
                         ON DELETE SET NULL     -- set the child column to NULL (must be nullable)
                         ON DELETE SET DEFAULT  -- set the child column to its DEFAULT
                         ON DELETE RESTRICT     -- immediate error; cannot be deferred
                         ON DELETE NO ACTION    -- error at statement end (the default)
                         ON UPDATE CASCADE
```

`NO ACTION` and `RESTRICT` both refuse the delete. `RESTRICT` checks immediately; `NO ACTION` checks at the end of the statement, or of the transaction if the constraint is `DEFERRABLE`.

`CASCADE` is convenient and dangerous: one `DELETE` can remove thousands of rows. Use it when the child cannot exist without the parent (items of an order, reviews of a deleted product), not for business entities whose history you want to keep.

> **Important:** A foreign key is only a check; it does **not** create an index on the child column that holds the reference. The parent's key is already indexed by its `PRIMARY KEY`; the missing one is on the child. Without that index, deleting the parent must scan the whole child table to find the rows that point at it, and joins that start from the parent have no index to use. In `reviews`, index both `product_id` and `customer_id`:
>
> ```sql
> CREATE INDEX reviews_product_id_idx ON reviews (product_id);
> CREATE INDEX reviews_customer_id_idx ON reviews (customer_id);
> ```
>
> The sample schema has the same gap on `orders.customer_id`. Chapter 13 covers indexes in depth.

## ALTER TABLE

```sql
ALTER TABLE customers ADD COLUMN birthday date;
ALTER TABLE customers ALTER COLUMN country SET DEFAULT 'HU';
ALTER TABLE customers RENAME COLUMN birthday TO birth_date;
ALTER TABLE products ALTER COLUMN price TYPE numeric(12,2);
ALTER TABLE customers DROP COLUMN birth_date;
ALTER TABLE reviews RENAME TO product_reviews;
DROP TABLE product_reviews;            -- add IF EXISTS for scripts
```

DDL is **transactional** in PostgreSQL: you can `BEGIN; ALTER ...; ROLLBACK;`. This is a superpower for safe migrations (few other databases offer it). A few statements, such as `CREATE INDEX CONCURRENTLY`, are exceptions and cannot run inside a transaction block.

### Adding NOT NULL to an existing column

Suppose `customers.segment` already exists and is nullable. Backfill the missing values, then enforce:

```sql
BEGIN;
UPDATE customers SET segment = 'standard' WHERE segment IS NULL;  -- backfill
ALTER TABLE customers ALTER COLUMN segment SET DEFAULT 'standard'; -- future inserts
ALTER TABLE customers ALTER COLUMN segment SET NOT NULL;           -- then enforce
COMMIT;
```

`SET NOT NULL` fails while any row is `NULL`. On a large table the backfill is the expensive part: the `UPDATE` rewrites every row it touches and holds row locks, so batch it, and `SET NOT NULL` then scans the whole table under a lock. Chapter 23 covers doing this without downtime, including how a `NOT VALID` check can be validated in the background before `SET NOT NULL`.

If the column is **new**, do not add it nullable and backfill — add it with a constant default in one statement:

```sql
ALTER TABLE customers ADD COLUMN status text NOT NULL DEFAULT 'active';
```

The constant is recorded once and the table is not rewritten, so there is no backfill or scan. A volatile default such as `DEFAULT random()` forfeits this shortcut and forces a full rewrite.

## Identity, sequences, UUIDs

- `GENERATED ALWAYS AS IDENTITY` is the modern auto-increment (preferred over `serial`), and is what `reviews.id` uses. Values come from a sequence; **sequences have gaps** (rolled-back inserts still consume numbers). Never rely on gap-free ids.
- `uuid` keys (`gen_random_uuid()`) are good when ids are generated by clients or must not be guessable; random UUIDs index less efficiently than sequential ids. `uuidv7()` exists from PG 18.

## Schemas

Tables live in **schemas**: namespaces inside a database that group objects and keep names from colliding. The sample database uses the default schema, `public`, so the table we call `products` is really `public.products`.

Create another schema and a table in it:

```sql
CREATE SCHEMA reporting;

CREATE TABLE reporting.daily_sales (
    day   date PRIMARY KEY,
    total numeric
);
```

The full name of an object is `schema.object`, so this table can always be addressed explicitly:

```sql
SELECT * FROM reporting.daily_sales;
```

For unqualified names, PostgreSQL consults the **search path**: an ordered list of schemas to try. `SHOW search_path;` prints that list. `SHOW` is not a query over your data; it reports the current value of a server setting:

```sql
SHOW search_path;           -- "$user", public
```

The default tries a schema named after the current user first (if it exists), then `public`. The first schema that contains the name wins, which is why `products` resolves to `public.products` when no user-specific schema exists. You can change the order for the current session:

```sql
SET search_path TO reporting, public;
SELECT * FROM daily_sales;   -- resolved to reporting.daily_sales
SHOW search_path;            -- reporting, public
```

Explicit schema names are clearer and safer in application code and migrations; chapter 20 explains the security side of `search_path`.

Use schemas to separate concerns (`reporting` for reporting tables, `audit` for history) and to grant access per group. In psql, `\dn` lists the schemas in the current database; chapter 20 covers the permissions side.

## Exercises

1. Create `reviews` as above. Insert a valid review and try to violate each constraint (rating 6, duplicate review, nonexistent product). Read the error messages.
2. Delete a product that has reviews. What happens with `ON DELETE CASCADE`? What would happen with `RESTRICT`?

3. Consider the rule "`orders.created_at` must not be in the future." Why is `CHECK (created_at <= now())` a poor way to enforce it? Where could that rule live instead?
4. Add a nullable `email_verified_at timestamptz` to `customers`.
5. `customers.status` already exists and is nullable. Write the transaction that makes it `NOT NULL DEFAULT 'active'` on a table with existing rows.
6. Suppose `status` is a **new** column instead. What single statement adds it correctly, and why does it need no backfill?
7. Prove that DDL is transactional: begin, drop `reviews`, check it's gone, roll back, check it's back.

??? note "Solutions"

    ```sql
    -- 2
    -- CASCADE removes the product's reviews along with the product.
    -- RESTRICT (or NO ACTION) makes the DELETE fail while reviews still reference it.
    -- To try it yourself, create the tables first, insert a product and a review,
    -- then DELETE the product. To see RESTRICT, drop the existing FK on
    -- reviews.product_id and re-add it with ON DELETE RESTRICT:
    --   ALTER TABLE reviews DROP CONSTRAINT reviews_product_id_fkey;
    --   ALTER TABLE reviews ADD CONSTRAINT reviews_product_id_fkey
    --     FOREIGN KEY (product_id) REFERENCES products (id) ON DELETE RESTRICT;
    -- 3
    -- CHECK constraints are expected to describe a rule that remains true for the row.
    -- now() changes while the row does not, and PostgreSQL checks the expression only on
    -- INSERT/UPDATE, not as time passes. Validate this rule in the write path instead, or
    -- store the relevant business deadline and compare two row values.
    -- 4
    -- A nullable column needs no backfill:
    ALTER TABLE customers ADD COLUMN email_verified_at timestamptz;

    -- 5
    -- status already exists and is nullable: backfill, then enforce.
    BEGIN;
    UPDATE customers SET status = 'active' WHERE status IS NULL;     -- backfill
    ALTER TABLE customers ALTER COLUMN status SET DEFAULT 'active';  -- future inserts
    ALTER TABLE customers ALTER COLUMN status SET NOT NULL;          -- enforce
    COMMIT;

    -- 6
    -- For a new column, use one statement. The constant default is recorded
    -- once and the table is not rewritten, so no backfill is needed.
    ALTER TABLE customers ADD COLUMN status text NOT NULL DEFAULT 'active';
    -- 7
    BEGIN; DROP TABLE reviews; \dt
    ROLLBACK; \dt
    ```

Next: [9. Subqueries and CTEs](09-subqueries-ctes.md)
