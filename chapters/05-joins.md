---
hide:
  - toc
---

# 5. Joins

**You will learn:** combining tables, every join type, and how to avoid the classic mistakes (duplicated rows, lost rows).

## Why joins

Normalization spreads facts across tables. Joins put them back together at query time.

```sql
SELECT o.id, o.status, c.name, c.country
FROM orders o
JOIN customers c ON c.id = o.customer_id
WHERE o.created_at > now() - interval '30 days';
```

`o` and `c` are table aliases. Qualify columns (`o.id`) whenever more than one table is involved.

Conceptually: take every pair of rows, keep those where the `ON` condition is true.

## Join types

| Join | Result |
|---|---|
| `INNER JOIN` (or `JOIN`) | only pairs that match |
| `LEFT JOIN` | all left rows; right side is `NULL` when no match |
| `RIGHT JOIN` | mirror of left (rarely used, just swap the tables) |
| `FULL JOIN` | all rows from both sides |
| `CROSS JOIN` | every combination (n × m rows) |

### INNER vs LEFT

Customers *with* orders vs all customers, including those with none:

```sql
SELECT c.id, count(o.id) AS orders
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.id
GROUP BY c.id
ORDER BY orders;
```

Note `count(o.id)`, not `count(*)`: for a customer with no orders `count(*)` would give 1 (the single NULL-padded row).

### Finding rows with *no* match (anti-join)

```sql
SELECT c.*
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.id
WHERE o.id IS NULL;
-- equivalent, often clearer:
SELECT * FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id);
```

### The LEFT JOIN + WHERE trap

```sql
-- Intended: all customers, with their *shipped* orders only
SELECT c.id, o.id FROM customers c
LEFT JOIN orders o ON o.customer_id = c.id
WHERE o.status = 'shipped';         -- WRONG: removes customers w/o orders, becomes an inner join

SELECT c.id, o.id FROM customers c
LEFT JOIN orders o ON o.customer_id = c.id AND o.status = 'shipped';   -- right
```

Filters on the *optional* side go into `ON`.

## Multi-table joins

```sql
SELECT o.id, c.name, p.name AS product, oi.quantity, oi.quantity * oi.unit_price AS line_total
FROM orders o
JOIN customers c   ON c.id = o.customer_id
JOIN order_items oi ON oi.order_id = o.id
JOIN products p    ON p.id = oi.product_id
WHERE o.id = 42;
```

### Revenue per category (joins + aggregation)

```sql
SELECT cat.name, sum(oi.quantity * oi.unit_price) AS revenue
FROM order_items oi
JOIN products p      ON p.id = oi.product_id
JOIN categories cat  ON cat.id = p.category_id
JOIN orders o        ON o.id = oi.order_id AND o.status <> 'cancelled'
GROUP BY cat.name
ORDER BY revenue DESC;
```

## The fan-out mistake

Joining a "one" side to a "many" side repeats the one-side rows. Summing a one-side column after joining many-side counts it multiple times:

```sql
-- If orders had a "shipping_cost" column, this would multiply it by the number of lines:
-- SELECT sum(o.shipping_cost) FROM orders o JOIN order_items oi ON oi.order_id = o.id;
```

Fix: aggregate the many side first (subquery/CTE), then join; or aggregate before joining.

## Self joins

Join a table to itself using aliases, e.g. a category with its parent:

```sql
SELECT child.name AS category, parent.name AS parent
FROM categories child
LEFT JOIN categories parent ON parent.id = child.parent_id;
```

## LATERAL: "for each row, run this subquery"

```sql
-- the 3 most recent orders for each of the first 5 customers
SELECT c.id, o.id AS order_id, o.created_at
FROM customers c
CROSS JOIN LATERAL (
    SELECT id, created_at FROM orders
    WHERE customer_id = c.id
    ORDER BY created_at DESC LIMIT 3
) o
WHERE c.id <= 5;
```

`LATERAL` allows the subquery on its right to refer to columns from rows already produced on its left. `CROSS JOIN LATERAL` drops a customer when the subquery returns no rows; use `LEFT JOIN LATERAL (...) o ON true` when the customer must remain. Top-N-per-group is its most common use. (Chapter 10 shows a window function alternative.)

## USING and NATURAL

`JOIN x USING (col)` is shorthand when both sides have the identically named column. Avoid `NATURAL JOIN`: it silently changes meaning if columns are added.

## Exercises

1. List each order of customer 1 with the customer's name and the order total.
2. Number of orders per customer, including customers with zero orders.
3. Customers who never placed an order.
4. Top 5 products by quantity sold (non-cancelled orders).
5. Each product with its category *and* its parent category name (two levels).
6. Revenue per country per month.
7. For each customer, the date of their most recent order using `LATERAL`.
8. Explain why `count(*)` is wrong in exercise 2.

??? note "Solutions"

    ```sql
    -- 1
    SELECT o.id, c.name, sum(oi.quantity * oi.unit_price) AS total
    FROM orders o JOIN customers c ON c.id = o.customer_id
    JOIN order_items oi ON oi.order_id = o.id
    WHERE c.id = 1 GROUP BY o.id, c.name;
    -- 2
    SELECT c.id, count(o.id) FROM customers c LEFT JOIN orders o ON o.customer_id = c.id GROUP BY c.id;
    -- 3
    SELECT c.* FROM customers c WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id);
    -- 4
    SELECT p.name, sum(oi.quantity) q FROM order_items oi
    JOIN products p ON p.id = oi.product_id
    JOIN orders o ON o.id = oi.order_id AND o.status <> 'cancelled'
    GROUP BY p.id, p.name ORDER BY q DESC LIMIT 5;
    -- 5
    SELECT p.name, c.name AS category, parent.name AS parent
    FROM products p JOIN categories c ON c.id = p.category_id
    LEFT JOIN categories parent ON parent.id = c.parent_id;
    -- 6
    SELECT c.country, date_trunc('month', o.created_at) m, sum(oi.quantity * oi.unit_price)
    FROM orders o JOIN customers c ON c.id = o.customer_id
    JOIN order_items oi ON oi.order_id = o.id
    GROUP BY 1, 2 ORDER BY 1, 2;
    -- 7
    SELECT c.id, last.created_at FROM customers c
    LEFT JOIN LATERAL (SELECT created_at FROM orders WHERE customer_id = c.id ORDER BY created_at DESC LIMIT 1) last ON true;
    -- 8  A customer with no orders yields one NULL-padded row, so count(*) reports 1 instead of 0.
    ```

Next: [6. Changing Data](06-modifying-data.md)
