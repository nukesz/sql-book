---
hide:
  - toc
---

# 15. JSONB, Arrays, Dates and Text Search

**You will learn:** PostgreSQL's richer data types and when to use them instead of extra tables.

## JSONB

`jsonb` stores JSON in a parsed binary form: indexable, queryable, validated. Use it for *genuinely* flexible/sparse attributes (product specs, API payloads), not as a way to avoid designing tables. Anything you join on, filter heavily, or need constraints for deserves a real column.

```sql
SELECT attributes FROM products LIMIT 3;

SELECT attributes -> 'color'        AS color_json,   -- jsonb value ("red", with quotes)
       attributes ->> 'color'       AS color_text,   -- text
       (attributes ->> 'weight_g')::int AS weight
FROM products;

-- filter
SELECT count(*) FROM products WHERE attributes ->> 'color' = 'red';
SELECT count(*) FROM products WHERE attributes @> '{"color": "red"}';   -- containment: GIN-indexable
SELECT count(*) FROM products WHERE attributes ? 'weight_g';            -- key exists
```

Update and build:

```sql
UPDATE products SET attributes = attributes || '{"warranty_months": 24}' WHERE id = 1;     -- merge/add key
UPDATE products SET attributes = jsonb_set(attributes, '{color}', '"purple"') WHERE id = 1; -- set path
UPDATE products SET attributes = attributes - 'warranty_months' WHERE id = 1;              -- remove key

SELECT jsonb_build_object('id', id, 'name', name, 'price', price) FROM products LIMIT 2;
SELECT jsonb_agg(jsonb_build_object('id', id, 'name', name)) FROM products WHERE category_id = 3;  -- rows to JSON array
```

Unpack:

```sql
SELECT key, value FROM products, jsonb_each(attributes) WHERE id = 1;
SELECT jsonb_array_elements('[1,2,3]'::jsonb);
```

Index:

```sql
CREATE INDEX products_attrs_gin ON products USING gin (attributes);                 -- supports @>, ?
CREATE INDEX products_color_idx ON products ((attributes ->> 'color'));             -- btree on one key
```

Constraint example: `CHECK (jsonb_typeof(attributes) = 'object')`.

Shaping JSON directly in SQL is extremely handy for APIs: one query can return a complete nested document (`jsonb_agg` + `jsonb_build_object` in a `LATERAL` subquery), saving round-trips and mapping code.

## Arrays

```sql
SELECT tags FROM products WHERE cardinality(tags) > 0 LIMIT 3;
SELECT name FROM products WHERE 'sale' = ANY(tags);
SELECT name FROM products WHERE tags @> ARRAY['sale','popular'];     -- contains all (GIN-indexable)
SELECT name FROM products WHERE tags && ARRAY['new','sale'];         -- overlaps any
SELECT unnest(tags) AS tag, count(*) FROM products GROUP BY tag ORDER BY 2 DESC;  -- tag popularity
UPDATE products SET tags = array_append(tags, 'clearance') WHERE id = 3;
SELECT array_agg(name ORDER BY name) FROM products WHERE category_id = 3;
```

Arrays suit small, simple lists you never join on. If elements have their own attributes or relationships, make a table.

## Dates and times

```sql
SELECT now(), current_date, now()::date, now() - interval '1 day 2 hours';
SELECT date_trunc('week', now()), date_trunc('month', now());           -- round down
SELECT extract(year FROM now()), extract(dow FROM now());                -- parts (dow: 0 = Sunday)
SELECT age(now(), '2000-01-01');                                         -- human interval
SELECT to_char(now(), 'YYYY-MM-DD HH24:MI'), '2025-03-01'::date + 30;
SELECT '2025-01-31'::date + interval '1 month';                          -- 2025-02-28 (clamped)
```

### Ranges

Ranges model periods and make overlaps trivial:

```sql
SELECT tstzrange('2025-01-01', '2025-02-01') @> '2025-01-15'::timestamptz;      -- contains
SELECT daterange('2025-01-01', '2025-01-10') && daterange('2025-01-05', '2025-01-20');  -- overlaps

CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE TABLE room_bookings (
    room int, during tstzrange,
    EXCLUDE USING gist (room WITH =, during WITH &&)    -- no overlapping bookings per room, guaranteed
);
```

PostgreSQL ranges are lower-inclusive and upper-exclusive (`[start, end)`) by default, so a booking ending at 10:00 does not overlap one starting at 10:00. `@>` means "contains", `&&` means "overlaps", and the exclusion constraint rejects two rows where both the room is equal and the periods overlap.

### Day-bucket gotcha

`created_at::date` uses the **session time zone**. For reports, be explicit: `(created_at AT TIME ZONE 'UTC')::date`.

## Full-text search

```sql
SELECT to_tsvector('english', 'The quick brown foxes jumped'),
       to_tsquery('english', 'fox & jump');
SELECT to_tsvector('english', 'The quick brown foxes jumped') @@ to_tsquery('english', 'fox & jump');  -- true

ALTER TABLE products ADD COLUMN search tsvector
    GENERATED ALWAYS AS (to_tsvector('english', name)) STORED;
CREATE INDEX products_search_idx ON products USING gin (search);
SELECT name FROM products WHERE search @@ websearch_to_tsquery('english', 'product 12');
```

Handles stemming, stop words and ranking (`ts_rank`). For typo-tolerant "contains" matching use `pg_trgm` (chapter 13).

## Generated columns, enums, UUIDs

```sql
ALTER TABLE order_items ADD COLUMN line_total numeric(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED;
CREATE TYPE order_status AS ENUM ('new', 'paid', 'shipped', 'cancelled');   -- alternative to CHECK; changing is harder
SELECT gen_random_uuid();
```

## Exercises

1. How many products are red and heavier than 1000 g?
2. Add a `"warranty_months"` key to all products of category 3 and read it back as an integer.
3. Build, in one query, a JSON document per category: `{"category": ..., "products": [{"id":..,"name":..,"price":..}, ...]}`.
4. List the 5 most common tags.
5. Create `room_bookings` as above; insert two overlapping bookings and observe the error.
6. Orders per ISO week for the last 8 weeks (`date_trunc('week', ...)`).
7. Index and query: find products with *both* `sale` and `popular` tags; confirm with `EXPLAIN` that the GIN index can be used (set `enable_seqscan = off` for the experiment, as the table is small).

??? note "Solutions"

    ```sql
    -- 1
    SELECT count(*) FROM products WHERE attributes ->> 'color' = 'red' AND (attributes ->> 'weight_g')::int > 1000;
    -- 2
    UPDATE products SET attributes = attributes || '{"warranty_months": 12}' WHERE category_id = 3;
    SELECT (attributes ->> 'warranty_months')::int FROM products WHERE category_id = 3 LIMIT 3;
    -- 3
    SELECT jsonb_build_object('category', c.name,
           'products', coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'price', p.price)) FILTER (WHERE p.id IS NOT NULL), '[]'))
    FROM categories c LEFT JOIN products p ON p.category_id = c.id GROUP BY c.id, c.name;
    -- 4
    SELECT tag, count(*) FROM products, unnest(tags) AS tag GROUP BY tag ORDER BY 2 DESC LIMIT 5;
    -- 5
    INSERT INTO room_bookings VALUES (1, tstzrange('2025-01-01','2025-01-05')), (1, tstzrange('2025-01-04','2025-01-08'));
    -- ERROR: conflicting key value violates exclusion constraint
    -- 6
    SELECT date_trunc('week', created_at) w, count(*) FROM orders WHERE created_at >= date_trunc('week', now()) - interval '7 weeks' GROUP BY 1 ORDER BY 1;
    -- 7
    CREATE INDEX ON products USING gin (tags);
    SET enable_seqscan = off;
    EXPLAIN SELECT * FROM products WHERE tags @> ARRAY['sale','popular'];
    ```

Next: [16. How PostgreSQL Stores Data: MVCC and Vacuum](16-mvcc-vacuum.md)
