-- Deterministic-ish sample data. Exact numbers may differ slightly between
-- PostgreSQL versions, so exercises never depend on exact random values.
SELECT setseed(0.42);

INSERT INTO categories (name) VALUES ('Books'), ('Electronics'), ('Home');

INSERT INTO categories (name, parent_id)
SELECT v.n, c.id
FROM (VALUES ('Fiction', 'Books'), ('Science', 'Books'),
             ('Phones', 'Electronics'), ('Laptops', 'Electronics'),
             ('Kitchen', 'Home'), ('Garden', 'Home')) AS v(n, p)
JOIN categories c ON c.name = v.p;

INSERT INTO customers (email, name, country, phone, created_at)
SELECT 'user' || g || '@example.com',
       'Customer ' || g,
       (ARRAY['HU','DE','US','NO','JP','BR'])[1 + floor(random() * 6)::int],
       CASE WHEN random() < 0.7 THEN '+36' || (100000000 + g) ELSE NULL END,
       now() - make_interval(days => floor(random() * 730)::int)
FROM generate_series(1, 1000) g;

INSERT INTO products (category_id, name, price, stock, attributes, tags)
SELECT (SELECT id FROM categories WHERE parent_id IS NOT NULL
        ORDER BY id OFFSET (g % 6) LIMIT 1),
       'Product ' || g,
       round((5 + random() * 495)::numeric, 2),
       floor(random() * 100)::int,
       jsonb_build_object(
           'color',    (ARRAY['red','green','blue','black'])[1 + floor(random() * 4)::int],
           'weight_g', 50 + floor(random() * 2000)::int),
       CASE WHEN g % 5 = 0 THEN ARRAY['sale','popular']
            WHEN g % 3 = 0 THEN ARRAY['new']
            ELSE '{}'::text[] END
FROM generate_series(1, 200) g;

INSERT INTO orders (customer_id, status, created_at)
SELECT 1 + floor(random() * 1000)::int,
       (ARRAY['new','paid','shipped','shipped','shipped','cancelled'])[1 + floor(random() * 6)::int],
       now() - make_interval(days => floor(random() * 365)::int,
                             mins => floor(random() * 1440)::int)
FROM generate_series(1, 20000);

INSERT INTO order_items (order_id, line_no, product_id, quantity, unit_price)
SELECT o.id, l, p.id, 1 + floor(random() * 3)::int, p.price
FROM orders o
CROSS JOIN LATERAL generate_series(1, 1 + (o.id % 4)::int) AS l
JOIN products p ON p.id = 1 + ((o.id * 7 + l * 13) % 200);

ANALYZE;
