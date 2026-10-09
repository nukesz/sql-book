---
hide:
  - toc
---

# 6. Changing Data

**You will learn:** `INSERT`, `UPDATE`, `DELETE`, `RETURNING`, and how to do it safely.

> **Safety habit:** run changes inside a transaction so you can undo them.
> ```sql
> BEGIN;
> -- your UPDATE / DELETE
> SELECT ...;     -- verify
> ROLLBACK;       -- or COMMIT;
> ```
> Chapter 12 explains transactions fully. Use this habit from today.

## INSERT

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

### RETURNING

PostgreSQL can hand back the affected rows, so you do not need a second query to learn the generated id:

```sql
INSERT INTO customers (email, name, country)
VALUES ('grace@example.com', 'Grace Hopper', 'US')
RETURNING id, created_at;
```

`RETURNING` works for `UPDATE` and `DELETE` too. In application code, this is *the* way to get generated keys.

## UPDATE

```sql
UPDATE products SET price = price * 1.05 WHERE category_id = 3;
UPDATE products
SET stock = stock - 1,
    tags = array_append(tags, 'low')
WHERE id = 10
RETURNING *;
```

`tags` is a `text[]` array. `array_append(tags, 'low')` returns a new array with one element added; arrays are covered fully in chapter 15.

**Forgetting `WHERE` updates every row.** psql will not warn you. This is why you start with `BEGIN`.

### UPDATE ... FROM (update using another table)

```sql
UPDATE order_items oi
SET unit_price = p.price
FROM products p
WHERE p.id = oi.product_id AND oi.order_id = 1;
```

## DELETE

```sql
DELETE FROM order_items WHERE order_id = 5 RETURNING *;
DELETE FROM customers WHERE id = 1;      -- fails: orders reference it (foreign key)
```

Foreign keys decide what happens to referencing rows: `NO ACTION`/`RESTRICT` (error, the default), `CASCADE` (delete them too), `SET NULL`. See chapter 8.

### Removing every row

```sql
TRUNCATE order_items;      -- fast, not row-by-row; resets nothing else; can't be used with FK references without CASCADE
```

`TRUNCATE` takes an `ACCESS EXCLUSIVE` lock, does not run row-level `DELETE` triggers, and refuses to truncate a table referenced by a foreign key unless all related tables are included (or `CASCADE` is used). It is transactional in PostgreSQL, but it is still a production operation to use carefully.

## Habit: test your WHERE with a SELECT first

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
