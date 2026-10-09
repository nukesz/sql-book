-- Sample schema for "Direct SQL against PostgreSQL": a small web shop.

CREATE TABLE categories (
    id        int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name      text NOT NULL UNIQUE,
    parent_id int REFERENCES categories (id)
);

CREATE TABLE customers (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email      text NOT NULL UNIQUE,
    name       text NOT NULL,
    country    text NOT NULL,
    phone      text,                       -- nullable on purpose (NULL chapter)
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE products (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id int NOT NULL REFERENCES categories (id),
    name        text NOT NULL,
    price       numeric(10,2) NOT NULL CHECK (price >= 0),
    stock       int NOT NULL DEFAULT 0 CHECK (stock >= 0),
    attributes  jsonb NOT NULL DEFAULT '{}',
    tags        text[] NOT NULL DEFAULT '{}'
);

CREATE TABLE orders (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customers (id),
    status      text NOT NULL CHECK (status IN ('new', 'paid', 'shipped', 'cancelled')),
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE order_items (
    order_id   bigint NOT NULL REFERENCES orders (id),
    line_no    int NOT NULL,
    product_id bigint NOT NULL REFERENCES products (id),
    quantity   int NOT NULL CHECK (quantity > 0),
    unit_price numeric(10,2) NOT NULL,
    PRIMARY KEY (order_id, line_no)
);
