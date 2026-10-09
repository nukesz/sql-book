---
hide:
  - toc
---

# 2. Relational Basics

**You will learn:** the theory every later chapter builds on: tables, keys, relationships, and what SQL really is.

## Tables, rows, columns

A **table** models a relation: an unordered collection of **rows** (tuples), where each **column** (attribute) has a fixed **type**. In relational theory a relation is a set, but SQL commonly uses **bag (multiset) semantics**: duplicate rows can exist unless a key or `UNIQUE` constraint prevents them, and a query keeps duplicates unless you request `DISTINCT`. Two consequences people forget:

- Rows have **no inherent order**. Without `ORDER BY`, the order is unspecified, even if it looks stable today.
- Each row should be **identifiable**, which is the job of keys.

## Keys

- **Primary key (PK):** uniquely identifies a row; never `NULL`. One per table. Can be *composite*: `order_items` uses `(order_id, line_no)`.
- **Natural vs surrogate key:** `email` is a natural key (meaningful, but people change email addresses); `id` is a surrogate (meaningless, stable). Common practice: surrogate PK plus a `UNIQUE` constraint on the natural key (see `customers`).
- **Foreign key (FK):** a column whose values must exist in another table's key. It enforces *referential integrity*: you cannot create an order for a customer that does not exist, nor delete a customer who still has orders (by default).
- **Unique constraint:** no two rows may share the value(s).

## Relationships

| Kind | Modelled as | Example |
|---|---|---|
| one-to-many | FK on the "many" side | one customer → many orders |
| many-to-many | link table with two FKs (no direct FK between the two tables) | orders ↔ products via `order_items` |
| one-to-one | FK that is also `UNIQUE` | user ↔ profile |
| hierarchy | FK to the same table | `categories.parent_id` |

## Normalization in one page

**Normalization** is the practice of structuring tables so that each fact is stored in exactly one place. The reason is practical: when the same fact lives in several rows, the copies can disagree.

Take the sample database. Customers and their orders live in two tables, linked by a foreign key:

`customers`

| id | name | email |
|---|---|---|
| 1 | Ada | ada@example.com |
| 2 | Bob | bob@example.com |

`orders`

| id | order_date | customer_id |
|---|---|---|
| 1 | 2024-01-05 | 1 |
| 2 | 2024-02-11 | 1 |
| 3 | 2024-03-02 | 2 |

Each fact has one home: Ada's email is in exactly one row. Now imagine the same data squeezed into a single wide table instead:

| order_id | order_date | customer_name | customer_email |
|---|---|---|---|
| 1 | 2024-01-05 | Ada | ada@example.com |
| 2 | 2024-02-11 | Ada | ada@example.com |
| 3 | 2024-03-02 | Bob | bob@example.com |

Ada's email is now stored twice, which causes three classic problems (*anomalies*):

- **Update:** Ada changes her email. If you fix only one row, the data now contradicts itself.
- **Insert:** you cannot record a new customer until they place an order, because the customer only exists inside order rows.
- **Delete:** deleting Bob's only order also erases everything you knew about Bob.

The two-table design avoids all three: changing an email is a single `UPDATE`, a customer can exist without orders, and deleting an order leaves the customer intact. Splitting data like this is what normalization means.

The **normal forms** (1NF, 2NF, 3NF, ...) are a checklist of rules for spotting this kind of duplication. Each form removes one specific kind of redundancy, and each builds on the previous one. In practice, a design that reaches 3NF is good enough for most applications.

### 1NF: one value per cell

Every column holds a single atomic value, and there are no repeating groups.

**Bad:** a list packed into one column.

| order_id | products |
|---|---|
| 1 | Keyboard, Mouse |
| 2 | Monitor |

You cannot count orders per product, join to `products`, or enforce that the products exist. Searching for `Mouse` means string matching. Numbered columns (`product1`, `product2`, `product3`) are the same smell: the fourth product has nowhere to go, and every query must check all the columns.

**Good:** one row per fact, in a link table.

| order_id | line_no | product |
|---|---|---|
| 1 | 1 | Keyboard |
| 1 | 2 | Mouse |
| 2 | 1 | Monitor |

This is the shape of `order_items` in the sample database. PostgreSQL arrays and `jsonb` columns can hold several values, but use them deliberately for data you never join or constrain (chapter 15), not as a shortcut around a link table.

### 2NF: the whole key

This applies when the primary key is composite: every non-key column must depend on the *whole* key, not just part of it. A table with a single-column key is automatically in 2NF.

**Bad:** the key is `(order_id, product_id)`, but `product_name` depends only on `product_id`.

| order_id | product_id | product_name | quantity |
|---|---|---|---|
| 1 | 10 | Keyboard | 1 |
| 2 | 10 | Keyboard | 3 |
| 2 | 11 | Mouse | 2 |

The name of product 10 is stored once per order line. Renaming it means updating many rows, and a product that was never ordered cannot be stored at all.

**Good:** move the partial dependency into its own table.

`products`

| id | name |
|---|---|
| 10 | Keyboard |
| 11 | Mouse |

`order_items`

| order_id | product_id | quantity |
|---|---|---|
| 1 | 10 | 1 |
| 2 | 10 | 3 |
| 2 | 11 | 2 |

`quantity` depends on the whole key (this product in this order), so it stays. `name` depends only on the product, so it moves.

### 3NF: nothing but the key

Non-key columns depend on *only* the key, not on each other: "the key, the whole key, and nothing but the key".

**Bad:** `city` and `country` depend on `postal_code`, not directly on the customer.

| id | name | postal_code | city | country |
|---|---|---|---|---|
| 1 | Ada | 10115 | Berlin | Germany |
| 2 | Bob | 10115 | Berlin | Germany |
| 3 | Eve | 75001 | Paris | France |

The chain is `id → postal_code → city`. Fixing a misspelled city means touching every customer with that code, and rows can disagree (one says `Berlin`, another `Berlín`).

**Good:** the dependent columns move to their own table.

`customers`

| id | name | postal_code |
|---|---|---|
| 1 | Ada | 10115 |
| 2 | Bob | 10115 |
| 3 | Eve | 75001 |

`postal_codes`

| postal_code | city | country |
|---|---|---|
| 10115 | Berlin | Germany |
| 75001 | Paris | France |

### Quick test

Ask of each non-key column: *what determines this value?*

| If the answer is... | Then the table is... |
|---|---|
| "a list of things in one cell" | not in 1NF |
| "only part of the composite key" | not in 2NF |
| "another non-key column" | not in 3NF |
| "the whole key and only the key" | fine |

### When to stop

3NF is the practical target for transactional data. Higher forms (BCNF, 4NF, 5NF) deal with rarer dependency patterns and seldom matter in everyday design. In the other direction, **denormalization** (storing redundant data on purpose) is a legitimate tool for read performance or reporting, but it is a decision you make knowingly, not an accident.

Look at `order_items.unit_price`. It duplicates `products.price`, so isn't that a violation? No. It is the price *at the time of purchase*, a different fact, since the product price can change later. Deliberate denormalization for correct history is normal; accidental duplication is the bug.

## What SQL is

- **Declarative:** you say *what* result you want, the planner decides *how* (indexes, join order, ...). Chapter 14 shows how to see its decisions.
- **Set-based:** think in whole sets of rows, not loops. `UPDATE products SET price = price * 1.1` is one statement, not a loop.
- **Three-valued logic:** conditions evaluate to true, false, **or unknown** (`NULL`). Chapter 7.

Statement families:

| Family | Statements | Purpose |
|---|---|---|
| DQL | `SELECT` | read |
| DML | `INSERT`, `UPDATE`, `DELETE`, `MERGE` | change data |
| DDL | `CREATE`, `ALTER`, `DROP` | change structure |
| DCL | `GRANT`, `REVOKE` | permissions |
| TCL | `BEGIN`, `COMMIT`, `ROLLBACK` | transactions |

## PostgreSQL vocabulary

- **Database** → contains **schemas** (namespaces; default `public`) → contain tables, views, functions, etc.
- **Role:** users and groups are both roles.
- **Cluster:** one running server instance hosting many databases.
- Unquoted identifiers are folded to lower case. `Customers` and `customers` are the same table, but `"Customers"` is different. **Always use lower_snake_case and never quote identifiers.**

## Exercises

1. Which tables in the sample DB have a composite primary key? Why is that the right choice?
2. Draw (on paper) the FK arrows between the five tables. Which relationship is many-to-many, and which table makes it possible?
3. `orders` does not store a `total`. Is that a normalization decision? What are the pros and cons of adding one?
4. Why might `customers.email` be `UNIQUE` while `customers.name` is not?
5. Try `SELECT * FROM Customers;` and `SELECT * FROM "Customers";`. Explain the difference.

??? note "Solutions"

    1. `order_items (order_id, line_no)`. A line only exists in the context of an order; the pair identifies it naturally.
    2. `orders.customer_id → customers`, `order_items.order_id → orders`, `order_items.product_id → products`, `products.category_id → categories`, `categories.parent_id → categories`.

        Orders ↔ products is many-to-many, but there is **no direct FK between them**. The relationship is *indirect*, through the link table `order_items`, which holds two one-to-many relationships:

        - one order → many `order_items` rows (`order_items.order_id → orders`)
        - one product → many `order_items` rows (`order_items.product_id → products`)

        Read across, that means an order can contain many products, and a product can appear in many orders. A single FK column cannot express this: an FK on `orders` would allow only one product per order, and an FK on `products` would allow only one order per product. So a third table stores one row per (order, product) pair. Every many-to-many relationship is built this way.
    3. A stored total is *derived* data (redundant). Pro: fast reads. Con: can drift out of sync with items, so you need to update it in the same transaction or compute it with a view. Computing on read (chapter 4) is the safe default.
    4. Emails identify an account; names can legitimately repeat.
    5. The first works (folded to `customers`); the second fails: no table named exactly `Customers`.

Next: [3. Querying with SELECT](03-select.md)
