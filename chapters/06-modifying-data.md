---
hide:
  - toc
---

# 6. Changing Data

**You will learn:** `INSERT`, `UPDATE`, `DELETE`, `RETURNING`, and how to do it safely.

## Why writing is different from reading

A wrong `SELECT` costs you a second run. A wrong `UPDATE` or `DELETE` changes the stored data for every user of the database, and PostgreSQL executes exactly what you typed, however much it affects. The three statements themselves are small; the habits around them are the actual subject of this chapter.

> **Safety habit:** run changes inside a transaction so you can undo them.
> ```sql
> BEGIN;
> -- your UPDATE / DELETE
> SELECT ...;     -- verify
> ROLLBACK;       -- or COMMIT;
> ```
> Chapter 12 explains transactions fully. Use this habit from today.

## INSERT

One statement, three forms: literal values for one row, literal values for many rows, or rows produced by a query. The multi-row forms are not just shorter — every statement is a network round trip and its own bit of transaction bookkeeping, so one `INSERT` with 1000 rows beats 1000 single-row `INSERT`s by an order of magnitude.

```sql
INSERT INTO customers (email, name, country)
VALUES ('ada@example.com', 'Ada Lovelace', 'HU');

-- several rows in one statement (much faster than many single inserts)
INSERT INTO categories (name, parent_id)
VALUES ('Games', NULL), ('Sport', NULL);

-- from a query
INSERT INTO customers (email, name, country)
SELECT 'copy_' || email, name, country FROM customers WHERE country = 'NO';
```

Always list the column names. Omitted columns get their `DEFAULT` (or `NULL`). `id` is `GENERATED ALWAYS AS IDENTITY`, so you do not supply it.

`INSERT ... SELECT` inserts one row for every row the query returns — here a copy of each Norwegian customer. `||` is the string concatenation operator, so `'copy_' || email` produces `copy_ada@example.com`; `email` is `UNIQUE`, so the copies need a value of their own.

### RETURNING

PostgreSQL can hand back the affected rows, so you do not need a second query to learn the generated id:

```sql
INSERT INTO customers (email, name, country)
VALUES ('grace@example.com', 'Grace Hopper', 'US')
RETURNING id, created_at;
```

`RETURNING` works for `UPDATE` and `DELETE` too. In application code, this is *the* way to get generated keys.

## UPDATE

`UPDATE` assigns new values to the columns of the rows that `WHERE` selects, several columns in one comma-separated `SET`. Each new value may be computed from the old one, so the whole change happens inside the server in one statement. Reading a row into your application, computing there, and writing it back is both slower and a race against other sessions (chapter 12).

```sql
UPDATE products SET price = price * 1.05 WHERE category_id = 5;  -- new value from the old one: +5%

UPDATE products
SET stock = stock - 1,
    tags = array_append(tags, 'low')   -- tags is text[]; array_append returns a new array (chapter 15)
WHERE id = 10
RETURNING *;
```

**Forgetting `WHERE` updates every row.** psql will not warn you. This is why you start with `BEGIN`.

### UPDATE ... FROM (update using another table)

Often the new value lives in a second table — here, copying the current catalogue price onto the order lines. `FROM` lists the other table and `WHERE` joins the two, exactly as in a `SELECT`:

```sql
UPDATE order_items oi
SET unit_price = p.price
FROM products p
WHERE p.id = oi.product_id AND oi.order_id = 1;
```

Two things to know. `UPDATE ... FROM` is a PostgreSQL extension, so other databases spell this differently. And if the join matches a target row more than once, that row is updated only once, with values from an arbitrary one of the matches — no error. Check with a `SELECT` that the join is unique before you rely on it.

## DELETE

`DELETE` removes whole rows. There is no way to delete one column of a row — that is an `UPDATE` to `NULL` or to a default. A row other tables point at cannot simply disappear, so deletes in a normalized schema usually have to start at the children.

```sql
DELETE FROM order_items WHERE order_id = 5 RETURNING *;
DELETE FROM customers WHERE id = 1;      -- fails: orders reference it (foreign key)
```

Foreign keys decide what happens to referencing rows: `NO ACTION`/`RESTRICT` (error, the default), `CASCADE` (delete them too), `SET NULL`. See chapter 8.

### Removing every row

`DELETE FROM t` without a `WHERE` does work, but it marks every row dead one by one and leaves the space to be reclaimed later by `VACUUM` (chapter 16). `TRUNCATE` discards the table's files instead, so it costs about the same whether the table holds ten rows or ten million:

```sql
TRUNCATE order_items;      -- fast, not row-by-row; resets nothing else; can't be used with FK references without CASCADE
```

`TRUNCATE` takes an `ACCESS EXCLUSIVE` lock, does not run row-level `DELETE` triggers, and refuses to truncate a table referenced by a foreign key unless all related tables are included (or `CASCADE` is used). It is transactional in PostgreSQL, but it is still a production operation to use carefully.

## Habit: test your WHERE with a SELECT first

Most damaging statements are not wrong in their `SET` or their `DELETE` — they are wrong in their `WHERE`. Run the predicate as a `SELECT` first, unchanged. If the count is not the number you expected, you found the mistake while the data was still intact:

```sql
SELECT count(*) FROM products WHERE stock = 0;      -- how many will I touch?
DELETE FROM products WHERE stock = 0;
```

## Soft delete (design note)

Instead of removing rows, many systems set `deleted_at timestamptz`. It keeps history but every query must then remember `WHERE deleted_at IS NULL`, and unique constraints get awkward. Decide deliberately; partial indexes (chapter 13) help.

## Exercises

(Use `BEGIN ... ROLLBACK` for each.)

1. Insert a new category "Toys" under no parent and a product in it; return the new product id.
2. Raise the price of products with the tag `sale` by 10% and show the changed rows.
3. Set `stock` to 0 for every product that has never been ordered.
4. Delete all `cancelled` orders older than 300 days. What error do you get and why? How would you solve it?
5. Insert a copy of product 1 with the name `'Product 1 (copy)'`, in a single statement without typing its other values.
6. What happens if you run `UPDATE products SET price = -1 WHERE id = 1;`?

??? note "Solutions"

    ```sql
    -- 1
    BEGIN;
    INSERT INTO categories (name) VALUES ('Toys');
    INSERT INTO products (category_id, name, price)
    SELECT id, 'Robot', 19.90 FROM categories WHERE name = 'Toys'
    RETURNING id;
    ROLLBACK;
    -- 2
    UPDATE products SET price = round(price * 1.10, 2) WHERE 'sale' = ANY(tags) RETURNING id, price;
    -- 3
    UPDATE products p SET stock = 0 WHERE NOT EXISTS (SELECT 1 FROM order_items oi WHERE oi.product_id = p.id);
    -- 4  FK violation from order_items. Delete the items first (in the same transaction):
    DELETE FROM order_items WHERE order_id IN (SELECT id FROM orders WHERE status='cancelled' AND created_at < now() - interval '300 days');
    DELETE FROM orders WHERE status='cancelled' AND created_at < now() - interval '300 days';
    -- 5
    INSERT INTO products (category_id, name, price, stock, attributes, tags)
    SELECT category_id, 'Product 1 (copy)', price, stock, attributes, tags FROM products WHERE id = 1;
    -- 6  CHECK constraint violation: price >= 0.
    ```

Next: [7. Data Types and NULL](07-types-and-null.md)
