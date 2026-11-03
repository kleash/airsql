-- AirSQL's demo shop, for the pictures in the README and AirSQL Help (docs/assets/screenshots): a made-up homeware
-- shop whose customers, products and orders are all invented (e-mail addresses at example.com, .net and .org). Two
-- databases: shop, and shop_staging, a copy that has drifted (for Compare). The screenshot test loads this into the
-- lab's MySQL 8.4 and drops both databases when done:
--   AIRSQL_LAB=1 AIRSQL_SCREENSHOTS=1 ./test.sh --filter DemoScreenshots
-- By hand: docker exec -i airsql-lab-mysql84-1 mysql -uairsql -pairsql-pass < scripts/demo-shop.sql, and afterwards
-- DROP DATABASE shop; DROP DATABASE shop_staging;
SET NAMES utf8mb4;
SET time_zone = '+00:00';
DROP DATABASE IF EXISTS shop;
DROP DATABASE IF EXISTS shop_staging;
CREATE DATABASE shop CHARACTER SET utf8mb4;
USE shop;

CREATE TABLE categories (
    id SMALLINT UNSIGNED NOT NULL PRIMARY KEY,
    name VARCHAR(40) NOT NULL,
    UNIQUE KEY name (name)
);

CREATE TABLE products (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    sku VARCHAR(16) NOT NULL,
    name VARCHAR(100) NOT NULL,
    category_id SMALLINT UNSIGNED NOT NULL,
    price DECIMAL(8,2) NOT NULL,
    stock INT NOT NULL DEFAULT 0,
    details JSON NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE KEY sku (sku),
    CONSTRAINT products_category FOREIGN KEY (category_id) REFERENCES categories (id),
    CONSTRAINT price_positive CHECK (price > 0)
);

CREATE TABLE customers (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    email VARCHAR(255) NOT NULL,
    city VARCHAR(60) NOT NULL,
    country CHAR(2) NOT NULL,
    tier ENUM('standard', 'silver', 'gold') NOT NULL DEFAULT 'standard',
    newsletter BOOLEAN NOT NULL DEFAULT FALSE,
    created_at DATETIME NOT NULL,
    UNIQUE KEY email (email),
    KEY country (country)
);

CREATE TABLE orders (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    customer_id INT UNSIGNED NOT NULL,
    status ENUM('pending', 'paid', 'shipped', 'delivered', 'refunded', 'cancelled') NOT NULL DEFAULT 'pending',
    ordered_at DATETIME NOT NULL,
    shipped_at DATETIME NULL,
    total DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    note VARCHAR(255) NULL,
    KEY status_ordered (status, ordered_at),
    CONSTRAINT orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id)
);

CREATE TABLE order_items (
    order_id INT UNSIGNED NOT NULL,
    line TINYINT UNSIGNED NOT NULL,
    product_id INT UNSIGNED NOT NULL,
    quantity SMALLINT UNSIGNED NOT NULL,
    unit_price DECIMAL(8,2) NOT NULL,
    PRIMARY KEY (order_id, line),
    KEY product (product_id),
    CONSTRAINT items_order FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE,
    CONSTRAINT items_product FOREIGN KEY (product_id) REFERENCES products (id)
);

CREATE TABLE reviews (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    product_id INT UNSIGNED NOT NULL,
    customer_id INT UNSIGNED NOT NULL,
    rating TINYINT UNSIGNED NOT NULL,
    title VARCHAR(120) NOT NULL,
    written_at DATETIME NOT NULL,
    CONSTRAINT reviews_product FOREIGN KEY (product_id) REFERENCES products (id),
    CONSTRAINT reviews_customer FOREIGN KEY (customer_id) REFERENCES customers (id),
    CONSTRAINT rating_range CHECK (rating BETWEEN 1 AND 5)
);

CREATE VIEW monthly_revenue AS
SELECT DATE_FORMAT(ordered_at, '%Y-%m') AS month, COUNT(*) AS orders, SUM(total) AS revenue
FROM orders WHERE status IN ('paid', 'shipped', 'delivered') GROUP BY DATE_FORMAT(ordered_at, '%Y-%m');

INSERT INTO categories VALUES
    (1, 'Kitchen'), (2, 'Tableware'), (3, 'Textiles'), (4, 'Lighting'), (5, 'Garden'), (6, 'Bath'), (7, 'Stationery'),
    (8, 'Outdoor');

INSERT INTO products (id, sku, name, category_id, price, stock, details) VALUES
    (1, 'KIT-0101', 'Cast iron skillet, 26 cm', 1, 54.00, 38, '{"material": "cast iron", "weight_g": 2600}'),
    (2, 'KIT-0102', 'Oak cutting board', 1, 38.50, 64, '{"material": "oak", "size_cm": [40, 25]}'),
    (3, 'KIT-0103', 'Enamel saucepan, 1.5 l', 1, 42.00, 25, '{"material": "enamel", "colour": "sage"}'),
    (4, 'KIT-0104', 'Stoneware mixing bowl', 1, 26.00, 80, '{"material": "stoneware", "colour": "oat"}'),
    (5, 'KIT-0105', 'Pour-over coffee set', 1, 47.00, 31, '{"material": "glass", "cups": 4}'),
    (6, 'TAB-0201', 'Hand-thrown mug', 2, 18.00, 140, '{"material": "stoneware", "colour": "slate", "ml": 350}'),
    (7, 'TAB-0202', 'Speckled dinner plate', 2, 22.00, 96, '{"material": "stoneware", "diameter_cm": 27}'),
    (8, 'TAB-0203', 'Recycled glass tumblers, set of 6', 2, 32.00, 45, '{"material": "glass", "ml": 300}'),
    (9, 'TAB-0204', 'Walnut serving tray', 2, 58.00, 18, '{"material": "walnut"}'),
    (10, 'TAB-0205', 'Olive wood salad servers', 2, 21.50, 57, '{"material": "olive wood"}'),
    (11, 'TEX-0301', 'Linen napkins, set of 4', 3, 28.00, 73, '{"material": "linen", "colour": "clay"}'),
    (12, 'TEX-0302', 'Herringbone wool throw', 3, 89.00, 12, '{"material": "wool", "size_cm": [130, 180]}'),
    (13, 'TEX-0303', 'Linen tablecloth', 3, 64.00, 22, '{"material": "linen", "colour": "natural"}'),
    (14, 'TEX-0304', 'Cotton tea towels, set of 3', 3, 19.50, 110, '{"material": "cotton"}'),
    (15, 'TEX-0305', 'Chunky knit cushion', 3, 45.00, 29, '{"material": "wool", "colour": "cream"}'),
    (16, 'LGT-0401', 'Brass desk lamp', 4, 119.00, 9, '{"material": "brass", "bulb": "E27"}'),
    (17, 'LGT-0402', 'Paper pendant shade', 4, 49.00, 34, '{"material": "paper", "diameter_cm": 45}'),
    (18, 'LGT-0403', 'Beeswax pillar candle', 4, 16.00, 210, '{"material": "beeswax", "burn_hours": 60}'),
    (19, 'LGT-0404', 'Rechargeable lantern', 4, 39.00, 41, '{"material": "steel", "battery_hours": 12}'),
    (20, 'GDN-0501', 'Terracotta planter, large', 5, 36.00, 27, '{"material": "terracotta", "diameter_cm": 32}'),
    (21, 'GDN-0502', 'Herb seed collection', 5, 14.50, 160, '{"varieties": ["basil", "thyme", "chives", "dill"]}'),
    (22, 'GDN-0503', 'Ash-handled trowel', 5, 24.00, 52, '{"material": "steel and ash"}'),
    (23, 'GDN-0504', 'Galvanised watering can', 5, 42.00, 19, '{"material": "steel", "litres": 5}'),
    (24, 'GDN-0505', 'Cedar bird feeder', 5, 29.00, 38, '{"material": "cedar"}'),
    (25, 'BTH-0601', 'Waffle bath towel', 6, 34.00, 66, '{"material": "cotton", "colour": "sand"}'),
    (26, 'BTH-0602', 'Olive oil soap, set of 3', 6, 15.00, 130, '{"weight_g": 300}'),
    (27, 'BTH-0603', 'Bamboo bath mat', 6, 27.00, 44, '{"material": "bamboo"}'),
    (28, 'BTH-0604', 'Ceramic soap dish', 6, 12.00, 88, '{"material": "ceramic", "colour": "white"}'),
    (29, 'STA-0701', 'Dot-grid notebook, A5', 7, 13.50, 240, '{"pages": 192}'),
    (30, 'STA-0702', 'Brass fountain pen', 7, 72.00, 15, '{"material": "brass", "nib": "medium"}'),
    (31, 'STA-0703', 'Recycled paper cards, set of 10', 7, 11.00, 175, '{"material": "recycled paper"}'),
    (32, 'STA-0704', 'Birch desk organiser', 7, 31.00, 36, '{"material": "birch plywood"}'),
    (33, 'OUT-0801', 'Enamel camping mug', 8, 14.00, 150, '{"material": "enamel", "ml": 400}'),
    (34, 'OUT-0802', 'Merino picnic blanket', 8, 79.00, 14, '{"material": "merino", "size_cm": [150, 200]}'),
    (35, 'OUT-0803', 'Insulated water bottle', 8, 29.50, 92, '{"material": "steel", "ml": 750}'),
    (36, 'OUT-0804', 'Folding beech stool', 8, 65.00, 11, '{"material": "beech"}'),
    (37, 'KIT-0106', 'Carbon steel wok', 1, 59.00, 20, '{"material": "carbon steel", "diameter_cm": 32}'),
    (38, 'LGT-0405', 'Linen lampshade', 4, 54.00, 16, '{"material": "linen", "colour": "natural"}');

-- 0 to 2999, for the rows below (a session's own table: no database shows it).
CREATE TEMPORARY TABLE seq (n INT NOT NULL PRIMARY KEY);
INSERT INTO seq (n)
SELECT a.d + 10 * b.d + 100 * c.d + 1000 * e.d
FROM (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
      UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a,
     (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
      UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b,
     (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
      UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c,
     (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2) e;

-- 240 customers: each first and last name pair once (7 and 13 step through 40 and 37 names).
INSERT INTO customers (id, first_name, last_name, email, city, country, tier, newsletter, created_at)
SELECT n + 1, first_name, last_name,
       LOWER(CONCAT(first_name, '.', last_name, '@', ELT(1 + MOD(n, 3), 'example.com', 'example.net', 'example.org'))),
       ELT(place, 'Lisbon', 'Berlin', 'Lyon', 'Utrecht', 'Gothenburg', 'Dublin', 'Porto', 'Munich', 'Copenhagen',
           'Vienna', 'Ghent', 'Bologna', 'Edinburgh', 'Toronto', 'Melbourne', 'Austin'),
       ELT(place, 'PT', 'DE', 'FR', 'NL', 'SE', 'IE', 'PT', 'DE', 'DK', 'AT', 'BE', 'IT', 'GB', 'CA', 'AU', 'US'),
       CASE WHEN MOD(n, 11) = 0 THEN 'gold' WHEN MOD(n, 4) = 0 THEN 'silver' ELSE 'standard' END,
       MOD(n, 3) <> 0,
       TIMESTAMP('2024-01-08 09:00:00') + INTERVAL (n * 3) DAY + INTERVAL MOD(n * 4111, 36000) SECOND
FROM (SELECT n, 1 + MOD(n * 5, 16) AS place,
             ELT(1 + MOD(n * 7, 40), 'Maya', 'Lukas', 'Priya', 'Tomas', 'Aisha', 'Daniel', 'Sofia', 'Kenji', 'Elena',
                 'Marcus', 'Ingrid', 'Omar', 'Chloe', 'Mateo', 'Hana', 'Felix', 'Amara', 'Jonas', 'Leila', 'Samuel',
                 'Nora', 'Ravi', 'Clara', 'Diego', 'Freya', 'Yusuf', 'Isla', 'Arjun', 'Mila', 'Theo', 'Zara', 'Emil',
                 'Lucia', 'Kofi', 'Astrid', 'Hugo', 'Naomi', 'Ivan', 'Anika', 'Leo') AS first_name,
             ELT(1 + MOD(n * 13, 37), 'Okafor', 'Brandt', 'Raman', 'Novak', 'Haddad', 'Lindqvist', 'Moreau', 'Tanaka',
                 'Rossi', 'Fischer', 'Kowalski', 'Mensah', 'Silva', 'Andersen', 'Costa', 'Nakamura', 'Weber', 'Duarte',
                 'Petrov', 'Byrne', 'Jansen', 'Kaur', 'Laurent', 'Ortiz', 'Bergstrom', 'Chen', 'Murphy', 'Varga',
                 'Nilsen', 'Okonkwo', 'Rahman', 'Schulz', 'Ferreira', 'Dubois', 'Ito', 'Keller', 'Santos') AS last_name
      FROM seq WHERE n < 240) people;

-- 2,400 orders from November 2025 to October 2026; the first 24 customers order most. The newest are still on their way.
INSERT INTO orders (id, customer_id, status, ordered_at, note)
SELECT 10001 + n,
       CASE WHEN MOD(n, 5) = 0 THEN 1 + MOD(n, 24) ELSE 1 + MOD(n * 89, 240) END,
       CASE WHEN MOD(n + 1, 41) = 0 THEN 'cancelled' WHEN MOD(n + 1, 29) = 0 THEN 'refunded'
            WHEN n >= 2385 THEN ELT(1 + MOD(n, 3), 'pending', 'paid', 'paid') WHEN n >= 2300 THEN 'shipped'
            ELSE 'delivered' END,
       TIMESTAMP('2025-11-01 08:00:00') + INTERVAL FLOOR(n * 365 / 2400) DAY
           + INTERVAL MOD(n * 7919, 50400) + MOD(n * n * 131 + n * 17, 3600) SECOND,
       CASE MOD(n, 17) WHEN 0 THEN 'Gift wrap, please' WHEN 5 THEN 'Leave with a neighbour if out'
                       WHEN 11 THEN 'Deliver after 5 pm' END
FROM seq WHERE n < 2400;
UPDATE orders SET shipped_at = ordered_at + INTERVAL (1 + MOD(id, 3)) DAY + INTERVAL 3 HOUR
WHERE status IN ('shipped', 'delivered', 'refunded');

-- One to four lines an order, each a different product at its price.
INSERT INTO order_items (order_id, line, product_id, quantity, unit_price)
SELECT o.id, l.line, p.id, 1 + MOD(o.id + l.line, 3), p.price
FROM orders o
JOIN (SELECT 1 AS line UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4) l ON l.line <= 1 + MOD(o.id * 7, 4)
JOIN products p ON p.id = 1 + MOD(o.id * 11 + l.line * 17, 36);
UPDATE orders o
JOIN (SELECT order_id, SUM(quantity * unit_price) AS total FROM order_items GROUP BY order_id) i ON i.order_id = o.id
SET o.total = i.total;

INSERT INTO reviews (product_id, customer_id, rating, title, written_at)
SELECT 1 + MOD(n * 13, 36), 1 + MOD(n * 61, 240), rating,
       IF(rating = 5, ELT(1 + MOD(n, 3), 'Beautifully made', 'Lovely quality', 'Exactly as described'),
          ELT(rating, 'Disappointed', 'Not as pictured', 'Does the job', 'Very good, would buy again')),
       TIMESTAMP('2025-11-10 10:00:00') + INTERVAL MOD(n * 233, 350) DAY + INTERVAL MOD(n * 4111, 36000) SECOND
FROM (SELECT n, CASE WHEN MOD(n, 13) = 0 THEN 2 WHEN MOD(n, 7) = 0 THEN 3 WHEN MOD(n, 3) = 0 THEN 4 ELSE 5 END AS rating
      FROM seq WHERE n < 400) r;

-- Staging: behind on products and the newest orders, with a column and a table of its own.
CREATE DATABASE shop_staging CHARACTER SET utf8mb4;
USE shop_staging;

CREATE TABLE categories (
    id SMALLINT UNSIGNED NOT NULL PRIMARY KEY,
    name VARCHAR(40) NOT NULL,
    UNIQUE KEY name (name)
);

CREATE TABLE products (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    sku VARCHAR(16) NOT NULL,
    name VARCHAR(100) NOT NULL,
    category_id SMALLINT UNSIGNED NOT NULL,
    price DECIMAL(8,2) NOT NULL,
    stock INT NOT NULL DEFAULT 0,
    details JSON NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE KEY sku (sku),
    CONSTRAINT products_category FOREIGN KEY (category_id) REFERENCES categories (id),
    CONSTRAINT price_positive CHECK (price > 0)
);

CREATE TABLE customers (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    email VARCHAR(255) NOT NULL,
    phone VARCHAR(30) NULL,
    city VARCHAR(60) NOT NULL,
    country CHAR(2) NOT NULL,
    tier ENUM('standard', 'silver', 'gold') NOT NULL DEFAULT 'standard',
    newsletter BOOLEAN NOT NULL DEFAULT FALSE,
    created_at DATETIME NOT NULL,
    UNIQUE KEY email (email),
    KEY country (country)
);

CREATE TABLE orders (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    customer_id INT UNSIGNED NOT NULL,
    status ENUM('pending', 'paid', 'shipped', 'delivered', 'refunded', 'cancelled') NOT NULL DEFAULT 'pending',
    ordered_at DATETIME NOT NULL,
    shipped_at DATETIME NULL,
    total DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    note VARCHAR(255) NULL,
    KEY status_ordered (status, ordered_at),
    CONSTRAINT orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id)
);

CREATE TABLE order_items (
    order_id INT UNSIGNED NOT NULL,
    line TINYINT UNSIGNED NOT NULL,
    product_id INT UNSIGNED NOT NULL,
    quantity SMALLINT UNSIGNED NOT NULL,
    unit_price DECIMAL(8,2) NOT NULL,
    PRIMARY KEY (order_id, line),
    KEY product (product_id),
    CONSTRAINT items_order FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE,
    CONSTRAINT items_product FOREIGN KEY (product_id) REFERENCES products (id)
);

CREATE TABLE gift_cards (
    code CHAR(12) NOT NULL PRIMARY KEY,
    balance DECIMAL(8,2) NOT NULL,
    expires_on DATE NOT NULL
);

CREATE VIEW monthly_revenue AS
SELECT DATE_FORMAT(ordered_at, '%Y-%m') AS month, COUNT(*) AS orders, SUM(total) AS revenue
FROM orders WHERE status IN ('paid', 'shipped', 'delivered') GROUP BY DATE_FORMAT(ordered_at, '%Y-%m');

INSERT INTO categories SELECT * FROM shop.categories;
INSERT INTO products SELECT * FROM shop.products WHERE id <= 36;
UPDATE products SET price = price - 2.00 WHERE id IN (6, 18, 29);
INSERT INTO customers (id, first_name, last_name, email, city, country, tier, newsletter, created_at)
SELECT id, first_name, last_name, email, city, country, tier, newsletter, created_at FROM shop.customers;
INSERT INTO orders SELECT * FROM shop.orders WHERE ordered_at < '2026-10-20';
INSERT INTO order_items SELECT i.* FROM shop.order_items i JOIN orders o ON o.id = i.order_id;
INSERT INTO gift_cards VALUES ('GC7Q2M9XK4PA', 50.00, '2027-06-30'), ('GC3T8R1WZ6HD', 25.00, '2027-03-31');

DROP TEMPORARY TABLE shop.seq;
