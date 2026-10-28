---
hide:
  - toc
---

# 1. Getting Started

**You will learn:** how to start PostgreSQL, connect with `psql`, and load the sample database used throughout the book.

## Why "direct SQL"?

ORMs and query builders are convenient, but they hide the database. Every ORM eventually emits SQL, and when something is slow, wrong, or deadlocked, you debug *that SQL*. Learning SQL directly gives you:

- the full power of the database (window functions, CTEs, JSONB, locking, ...), not just what the ORM exposes;
- the ability to read query plans and fix performance;
- the ability to reason about correctness under concurrency (transactions!).

This book assumes nothing at the start and goes deep by the end. Skip what you already know.

## Starting PostgreSQL

Any PostgreSQL 14+ works. The easiest way is the `docker-compose.yml` in the repository root:

```bash
podman compose up -d
```

First start creates the `shop` database and loads `data/01-schema.sql` and `data/02-seed.sql` automatically. To reset everything to the initial state:

```bash
podman compose down -v && podman compose up -d
```

### Without Podman

Docker works the same way: replace `podman` with `docker` in every command in this chapter. If you have neither, install PostgreSQL directly and set up the database by hand:

1. **Install PostgreSQL 14 or newer** from [postgresql.org/download](https://www.postgresql.org/download/) (Windows/macOS installers), or with a package manager: `brew install postgresql@17` (macOS), `sudo apt install postgresql` (Debian/Ubuntu). Make sure the `psql` client is installed too; the installers include it. During a Windows/macOS install you choose a password for the superuser `postgres`; remember it.
2. **Open a terminal in the repository root** (the folder containing `data/`). On Windows, use the "SQL Shell (psql)" from the Start menu or add PostgreSQL's `bin` folder to your `PATH`.
3. **Create the role and database** the book expects. Connect as the superuser (`sudo -u postgres psql` on Linux, otherwise `psql -U postgres`) and run:

   ```sql
   CREATE ROLE learner LOGIN PASSWORD 'learner';
   CREATE DATABASE shop OWNER learner;
   ```

   Then leave psql with `\q`.
4. **Load the schema and the data**, in this order:

   ```bash
   psql -h localhost -U learner -d shop -f data/01-schema.sql
   psql -h localhost -U learner -d shop -f data/02-seed.sql
   ```

   Enter the password `learner` when asked. `-f` means "run the SQL commands in this file". Seeding may take a few seconds.
5. **Check it worked:** `psql -h localhost -U learner -d shop -c "SELECT count(*) FROM orders;"` should print `20000`.

To start over, connect as the superuser and run `DROP DATABASE shop;`, then repeat steps 3 and 4.

From here on, use the "local psql" form from the next section: `psql -h localhost -U learner -d shop`. Skip the `podman exec` command.

## Connecting with psql

`psql` is the official command-line client. Use the one in the container (nothing to install):

```bash
podman exec -it direct-sql-pg psql -U learner -d shop
```

or a local one: `psql -h localhost -U learner -d shop` (password `learner`).

Any other client (DBeaver, DataGrip, IntelliJ, pgAdmin) works too; every example in the book is plain SQL.

### Essential psql commands

Backslash commands are psql features, *not* SQL:

| Command | Meaning |
|---|---|
| `\dt` | list tables |
| `\d products` | describe a table (columns, indexes, constraints) |
| `\d+ products` | describe with more detail |
| `\dn`, `\du`, `\df`, `\dv` | schemas, roles, functions, views |
| `\x` | toggle expanded (vertical) output |
| `\timing` | show how long each statement takes |
| `\i file.sql` | run a script (in the container: `\i /book/chapters/x.sql`) |
| `\?` / `\h SELECT` | help on psql / on an SQL command |
| `\q` | quit |

SQL statements end with `;`. Without it psql waits for more input.

## First queries

```sql
SELECT version();
SELECT now();
SELECT 1 + 1 AS two;
SELECT count(*) FROM orders;
```

## The sample database

A small web shop:

```
customers 1 ──< orders 1 ──< order_items >── 1 products >── 1 categories
                                                               ^       |
                                                               |_______|
                                                               parent
```

`1 ──<` means "one-to-many": one customer can have many orders. `order_items` holds the lines of an order: each row says "this order contains this product". A category may point to another category through `parent_id`, which creates the category tree.

- `customers` (1,001) - email, country, optional phone; one of them never ordered
- `categories` (9) - a two-level tree via `parent_id`
- `products` (200) - price, stock, `attributes jsonb`, `tags text[]`
- `orders` (20,000) - status: `new`, `paid`, `shipped`, `cancelled`
- `order_items` (~50,000) - one row per order line

Run `\d customers` and `\d order_items` and look at the output: column names, their types, and some extra rules attached to them. Don't worry about terms you don't know yet (primary key, foreign key, `NOT NULL`); [chapter 2](02-relational-basics.md) explains them.

## Exercises

1. Start the database and connect with psql.
2. List all tables. Describe `products`. Which columns are `NOT NULL`?
3. Count the rows in every table.
4. Turn on `\timing` and `\x`; run `SELECT * FROM customers LIMIT 2;` in both modes.
5. What is the PostgreSQL server version?

??? note "Solutions"

    ```sql
    -- 2
    \dt
    \d products
    -- 3
    SELECT count(*) FROM customers;   -- and so on for each table
    -- 5
    SHOW server_version;
    ```

Next: [2. Relational Basics](02-relational-basics.md)
