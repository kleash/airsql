-- AirSQL lab fixture: the same schema and data on every lab server (MySQL 5.7 to 9.7, MariaDB 10.5 to 11.8), so it
-- uses only what all of them take. The image's entrypoint runs seed/ once, when the server's data folder is new:
-- after changing a file here, run testenv/down.sh and then testenv/up.sh. Lab tests only read these databases; they
-- write in databases of their own (lane_<x>_*).
SET NAMES utf8mb4;
SET time_zone = '+00:00';
-- Not into the binary log (on by default since MySQL 8.0): it would hold the million rows a second time.
SET SESSION sql_log_bin = 0;

CREATE DATABASE fixture CHARACTER SET utf8mb4;
USE fixture;

-- Every column type: a row of everyday values, a row of extremes and a row of NULLs.
CREATE TABLE all_types (
    id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    c_tinyint TINYINT NULL,
    c_tinyint_unsigned TINYINT UNSIGNED NULL,
    c_smallint SMALLINT NULL,
    c_mediumint MEDIUMINT NULL,
    c_int INT NULL,
    c_int_unsigned INT UNSIGNED NULL,
    c_bigint BIGINT NULL,
    c_bigint_unsigned BIGINT UNSIGNED NULL,
    c_zerofill INT(6) UNSIGNED ZEROFILL NULL,
    c_boolean BOOLEAN NULL,
    c_decimal DECIMAL(65,30) NULL,
    c_money DECIMAL(10,2) NULL,
    c_float FLOAT NULL,
    c_double DOUBLE NULL,
    c_bit1 BIT(1) NULL,
    c_bit10 BIT(10) NULL,
    c_bit64 BIT(64) NULL,
    c_date DATE NULL,
    c_datetime DATETIME NULL,
    c_datetime6 DATETIME(6) NULL,
    c_timestamp TIMESTAMP NULL DEFAULT NULL,
    c_timestamp3 TIMESTAMP(3) NULL DEFAULT NULL,
    c_time TIME NULL,
    c_time3 TIME(3) NULL,
    c_year YEAR NULL,
    c_char CHAR(10) NULL,
    c_varchar VARCHAR(255) NULL,
    c_tinytext TINYTEXT NULL,
    c_text TEXT NULL,
    c_mediumtext MEDIUMTEXT NULL,
    c_longtext LONGTEXT NULL,
    c_binary16 BINARY(16) NULL,
    c_varbinary VARBINARY(255) NULL,
    c_tinyblob TINYBLOB NULL,
    c_blob BLOB NULL,
    c_mediumblob MEDIUMBLOB NULL,
    c_longblob LONGBLOB NULL,
    c_enum ENUM('small', 'medium', 'large') NULL,
    c_set SET('read', 'write', 'admin') NULL,
    c_json JSON NULL,
    c_geometry GEOMETRY NULL,
    c_point POINT NULL,
    c_linestring LINESTRING NULL,
    c_polygon POLYGON NULL,
    c_multipoint MULTIPOINT NULL,
    c_multilinestring MULTILINESTRING NULL,
    c_multipolygon MULTIPOLYGON NULL,
    c_geometrycollection GEOMETRYCOLLECTION NULL
) ENGINE=InnoDB;

INSERT INTO all_types (c_tinyint, c_tinyint_unsigned, c_smallint, c_mediumint, c_int, c_int_unsigned, c_bigint,
    c_bigint_unsigned, c_zerofill, c_boolean, c_decimal, c_money, c_float, c_double, c_bit1, c_bit10, c_bit64, c_date,
    c_datetime, c_datetime6, c_timestamp, c_timestamp3, c_time, c_time3, c_year, c_char, c_varchar, c_tinytext, c_text,
    c_mediumtext, c_longtext, c_binary16, c_varbinary, c_tinyblob, c_blob, c_mediumblob, c_longblob, c_enum, c_set,
    c_json, c_geometry, c_point, c_linestring, c_polygon, c_multipoint, c_multilinestring, c_multipolygon,
    c_geometrycollection)
VALUES
    (42, 200, 1234, 123456, 1234567, 3000000000, 1234567890123, 12345678901234567890, 42, TRUE,
     1234567.123456789012345678901234567890, 19.99, 3.14159, 2.718281828459045,
     b'1', b'1010101010', b'1111000011110000111100001111000011110000111100001111000011110000',
     '2026-11-03', '2026-11-03 12:34:56', '2026-11-03 12:34:56.123456', '2026-11-03 12:34:56',
     '2026-11-03 12:34:56.789', '12:34:56', '12:34:56.789', 2026,
     'char', 'Hello, world', 'tiny text', 'A TEXT value.', 'A MEDIUMTEXT value.', 'A LONGTEXT value.',
     UNHEX('0123456789ABCDEF0123456789ABCDEF'), X'00FF7F80', X'01', X'DEADBEEF', X'CAFEBABE', X'0102030405',
     'medium', 'read,write', '{"name": "AirSQL", "tags": ["mac", "sql"], "nested": {"n": 1.5, "ok": true, "none": null}}',
     ST_GeomFromText('POINT(1 2)'), ST_GeomFromText('POINT(13.4 52.5)'), ST_GeomFromText('LINESTRING(0 0, 1 1, 2 1)'),
     ST_GeomFromText('POLYGON((0 0, 10 0, 10 10, 0 10, 0 0), (2 2, 2 4, 4 4, 4 2, 2 2))'),
     ST_GeomFromText('MULTIPOINT(0 0, 1 1)'), ST_GeomFromText('MULTILINESTRING((0 0, 1 1), (2 2, 3 3))'),
     ST_GeomFromText('MULTIPOLYGON(((0 0, 1 0, 1 1, 0 1, 0 0)), ((5 5, 6 5, 6 6, 5 6, 5 5)))'),
     ST_GeomFromText('GEOMETRYCOLLECTION(POINT(1 1), LINESTRING(0 0, 1 1))')),
    (-128, 255, -32768, -8388608, -2147483648, 4294967295, -9223372036854775808, 18446744073709551615, 999999, FALSE,
     -99999999999999999999999999999999999.999999999999999999999999999999, 99999999.99, -3.40282e38,
     1.7976931348623157e308, b'0', b'1111111111', b'1111111111111111111111111111111111111111111111111111111111111111',
     '1000-01-01', '9999-12-31 23:59:59', '9999-12-31 23:59:59.999999', '2038-01-19 03:14:07',
     '1970-01-01 00:00:01.000', '-838:59:59', '838:59:59.000', 2155,
     REPEAT('x', 10), REPEAT('😀', 255), REPEAT('t', 255), REPEAT('text ', 13107), REPEAT('m', 70000),
     REPEAT('L', 1048576), UNHEX('FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF'), X'', X'00', REPEAT(X'00FF', 32767),
     REPEAT(X'AB', 70000), REPEAT(X'5A', 1048576), 'large', 'read,write,admin',
     '[1, -2.5, 3e10, "😀 שלום", null, true, false, {"a": {"b": {"c": [1, 2, [3, [4]]]}}}]',
     ST_GeomFromText('POINT(-180 -90)'), ST_GeomFromText('POINT(180 90)'),
     ST_GeomFromText('LINESTRING(-180 -90, 0 0, 180 90)'), NULL, NULL, NULL, NULL, NULL);
INSERT INTO all_types () VALUES ();

-- A spatial index (it needs NOT NULL).
CREATE TABLE places (
    id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    location POINT NOT NULL,
    area POLYGON NULL,
    SPATIAL INDEX location (location)
) ENGINE=InnoDB;
INSERT INTO places (name, location, area) VALUES
    ('Origin', ST_GeomFromText('POINT(0 0)'), ST_GeomFromText('POLYGON((-1 -1, 1 -1, 1 1, -1 1, -1 -1))')),
    ('North', ST_GeomFromText('POINT(0 10)'), NULL),
    ('East', ST_GeomFromText('POINT(10 0)'), NULL);

-- A small shop: foreign keys with CASCADE, RESTRICT and SET NULL, a composite key, generated columns (virtual and
-- stored, one indexed, one from JSON), a CHECK constraint (MySQL 5.7 parses it only) and triggers.
CREATE TABLE customers (
    id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NULL,
    country CHAR(2) NULL,
    created_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    UNIQUE KEY email (email)
) ENGINE=InnoDB;

CREATE TABLE products (
    id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    sku VARCHAR(20) NOT NULL,
    name VARCHAR(100) NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    attributes JSON NULL,
    color VARCHAR(20) GENERATED ALWAYS AS (JSON_UNQUOTE(JSON_EXTRACT(attributes, '$.color'))) VIRTUAL,
    price_with_tax DECIMAL(10,2) GENERATED ALWAYS AS (ROUND(price * 1.2, 2)) STORED,
    UNIQUE KEY sku (sku),
    KEY color (color)
) ENGINE=InnoDB;

CREATE TABLE orders (
    id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    customer_id INT NOT NULL,
    ordered_at DATETIME NOT NULL,
    status ENUM('new', 'paid', 'shipped', 'cancelled') NOT NULL DEFAULT 'new',
    total DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    note TEXT NULL,
    CONSTRAINT orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

CREATE TABLE order_items (
    order_id INT NOT NULL,
    line SMALLINT NOT NULL,
    product_id INT NOT NULL,
    quantity INT NOT NULL,
    unit_price DECIMAL(10,2) NOT NULL,
    line_total DECIMAL(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    PRIMARY KEY (order_id, line),
    CONSTRAINT order_items_order FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT order_items_product FOREIGN KEY (product_id) REFERENCES products (id) ON DELETE RESTRICT,
    CONSTRAINT quantity_positive CHECK (quantity > 0)
) ENGINE=InnoDB;

CREATE TABLE employees (
    id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    manager_id INT NULL,
    hired_on DATE NOT NULL,
    salary DECIMAL(10,2) NULL,
    CONSTRAINT employees_manager FOREIGN KEY (manager_id) REFERENCES employees (id) ON DELETE SET NULL
) ENGINE=InnoDB;

DELIMITER ;;
CREATE TRIGGER customers_before_insert BEFORE INSERT ON customers FOR EACH ROW
    SET NEW.email = LOWER(NEW.email);;
CREATE TRIGGER order_items_after_insert AFTER INSERT ON order_items FOR EACH ROW
    UPDATE orders SET total = total + NEW.line_total WHERE id = NEW.order_id;;
CREATE TRIGGER order_items_after_update AFTER UPDATE ON order_items FOR EACH ROW
    UPDATE orders SET total = total - OLD.line_total + NEW.line_total WHERE id = NEW.order_id;;
CREATE TRIGGER order_items_after_delete AFTER DELETE ON order_items FOR EACH ROW
    UPDATE orders SET total = total - OLD.line_total WHERE id = OLD.order_id;;
DELIMITER ;

INSERT INTO customers (id, name, email, country, created_at) VALUES
    (1, 'Ada Lovelace', 'ADA@EXAMPLE.COM', 'GB', '2026-01-01 09:00:00.000'),
    (2, 'Grace Hopper', 'grace@example.com', 'US', '2026-01-02 09:30:00.250'),
    (3, 'Lina Virtanen', 'lina@example.org', 'FI', '2026-01-03 10:00:00.500'),
    (4, 'Zoë Ünal', 'zoe@example.net', 'DE', '2026-01-04 11:15:00.750'),
    (5, 'محمد علي', 'mohammed@example.com', 'EG', '2026-01-05 12:00:00.000'),
    (6, 'דנה כהן', 'dana@example.com', 'IL', '2026-01-06 13:45:00.125'),
    (7, '山田 太郎', 'taro@example.com', 'JP', '2026-01-07 14:00:00.000'),
    (8, 'No Orders Yet', NULL, NULL, '2026-01-08 15:00:00.000');

INSERT INTO products (id, sku, name, price, attributes) VALUES
    (1, 'SKU-001', 'Notebook', 4.99, '{"color": "red", "pages": 120}'),
    (2, 'SKU-002', 'Pen', 1.50, '{"color": "blue"}'),
    (3, 'SKU-003', 'Stapler', 12.00, '{"color": "black", "weight_g": 350}'),
    (4, 'SKU-004', 'Desk lamp 💡', 39.90, '{"color": "white", "watts": 9}'),
    (5, 'SKU-005', 'Gift card', 25.00, NULL),
    (6, 'SKU-006', 'Paper (500 sheets)', 6.75, '{"size": "A4"}');

INSERT INTO orders (id, customer_id, ordered_at, status, note) VALUES
    (1, 1, '2026-02-01 10:00:00', 'shipped', NULL),
    (2, 1, '2026-02-15 16:30:00', 'paid', 'Gift wrap, please.'),
    (3, 2, '2026-02-20 09:05:00', 'paid', NULL),
    (4, 3, '2026-03-01 11:11:11', 'new', NULL),
    (5, 4, '2026-03-02 08:00:00', 'cancelled', 'Customer changed their mind.'),
    (6, 5, '2026-03-03 18:20:00', 'paid', 'التوصيل مساءً'),
    (7, 6, '2026-03-04 07:45:00', 'shipped', 'משלוח מהיר'),
    (8, 7, '2026-03-05 12:00:00', 'new', '😀 Thanks!'),
    (9, 2, '2026-03-06 13:30:00', 'shipped', NULL),
    (10, 3, '2026-03-07 14:00:00', 'paid', NULL);

INSERT INTO order_items (order_id, line, product_id, quantity, unit_price) VALUES
    (1, 1, 1, 3, 4.99), (1, 2, 2, 10, 1.50),
    (2, 1, 4, 1, 39.90),
    (3, 1, 3, 2, 12.00), (3, 2, 6, 5, 6.75),
    (4, 1, 5, 2, 25.00),
    (5, 1, 1, 1, 4.99),
    (6, 1, 2, 20, 1.40), (6, 2, 6, 1, 6.75),
    (7, 1, 4, 2, 39.90),
    (8, 1, 1, 1, 4.99), (8, 2, 2, 1, 1.50), (8, 3, 3, 1, 12.00),
    (9, 1, 6, 10, 6.50),
    (10, 1, 5, 4, 25.00), (10, 2, 2, 2, 1.50);

INSERT INTO employees (id, name, manager_id, hired_on, salary) VALUES
    (1, 'Chief', NULL, '2020-01-01', 150000.00),
    (2, 'Head of Sales', 1, '2020-06-01', 110000.00),
    (3, 'Head of Engineering', 1, '2020-07-15', 120000.00),
    (4, 'Sales Lead', 2, '2021-03-01', 80000.00),
    (5, 'Engineer', 3, '2022-09-01', 95000.00),
    (6, 'Sales Associate', 4, '2023-01-09', NULL);

-- No primary key, with rows that are exact duplicates: an edit can't tell them apart.
CREATE TABLE no_pk_log (
    logged_at DATETIME NOT NULL,
    level VARCHAR(10) NOT NULL,
    message VARCHAR(255) NOT NULL
) ENGINE=InnoDB;
INSERT INTO no_pk_log VALUES
    ('2026-01-01 10:00:00', 'info', 'started'),
    ('2026-01-01 10:00:00', 'info', 'started'),
    ('2026-01-01 10:05:00', 'warning', 'disk 80% full'),
    ('2026-01-01 10:10:00', 'error', 'disk full'),
    ('2026-01-01 10:10:00', 'error', 'disk full');

-- No primary key, but a unique key on NOT NULL columns.
CREATE TABLE unique_no_pk (
    code CHAR(8) NOT NULL,
    label VARCHAR(50) NULL,
    UNIQUE KEY code (code)
) ENGINE=InnoDB;
INSERT INTO unique_no_pk VALUES ('A-000001', 'first'), ('A-000002', 'second'), ('A-000003', NULL);

-- MyISAM: no transactions, no foreign keys.
CREATE TABLE myisam_notes (
    id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    title VARCHAR(100) NOT NULL,
    body TEXT NOT NULL,
    FULLTEXT KEY body (body)
) ENGINE=MyISAM;
INSERT INTO myisam_notes (title, body) VALUES
    ('First', 'MyISAM keeps no transactions.'),
    ('Second', 'Full-text search works on MyISAM tables.'),
    ('Third', 'A third note.');

-- Another character set: a latin1 table with one utf8mb4 binary-collation column.
CREATE TABLE latin1_legacy (
    id INT NOT NULL PRIMARY KEY,
    name VARCHAR(50) NOT NULL,
    code VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
INSERT INTO latin1_legacy VALUES (1, 'Café', 'abc'), (2, 'Müller', 'ABC'), (3, 'Ångström', NULL);

-- Text that is hard to show, sort, copy and quote; the last column has a right-to-left (Arabic) name.
CREATE TABLE texts (
    id INT NOT NULL PRIMARY KEY,
    kind VARCHAR(30) NOT NULL,
    body TEXT NULL,
    `ملاحظة` VARCHAR(100) NULL
) ENGINE=InnoDB;
INSERT INTO texts VALUES
    (1, 'ascii', 'Hello, world', NULL),
    (2, 'emoji', '😀 🎉 👍🏽 👨‍👩‍👧‍👦 🏳️‍🌈', 'رمز تعبيري'),
    (3, 'arabic', 'مرحبا بالعالم', 'عربي'),
    (4, 'hebrew', 'שלום עולם', 'עברית'),
    (5, 'mixed direction', 'Order 42 — طلب رقم ٤٢ — הזמנה 42', NULL),
    (6, 'cjk', '你好，世界 こんにちは 안녕하세요', NULL),
    (7, 'combining', CONCAT(CONVERT(X'65CC81' USING utf8mb4), ' is not ', CONVERT(X'C3A9' USING utf8mb4)), NULL),
    (8, 'control characters', CONCAT('line 1', CHAR(10 USING utf8mb4), 'line 2', CHAR(9 USING utf8mb4), 'tab',
        CHAR(13 USING utf8mb4), CHAR(10 USING utf8mb4), 'crlf'), NULL),
    (9, 'quotes', 'It''s "quoted" `ticked` \\back\\slashed\\ ; DROP TABLE nothing; --', NULL),
    (10, 'long', REPEAT('long text ', 2000), NULL),
    (11, 'empty', '', ''),
    (12, 'null', NULL, NULL),
    (13, 'spaces', '  leading and trailing  ', NULL);

-- Zero dates, stored the way old applications did (MySQL's default mode refuses them, so only for this table).
SET @fixture_sql_mode = @@SESSION.sql_mode;
SET SESSION sql_mode = '';
CREATE TABLE legacy_dates (
    id INT NOT NULL PRIMARY KEY,
    d DATE NOT NULL DEFAULT '0000-00-00',
    dt DATETIME NOT NULL DEFAULT '0000-00-00 00:00:00',
    ts TIMESTAMP NOT NULL DEFAULT '0000-00-00 00:00:00',
    note VARCHAR(50) NULL
) ENGINE=InnoDB;
INSERT INTO legacy_dates VALUES
    (1, '0000-00-00', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'zero dates'),
    (2, '2026-00-00', '2026-11-00 10:00:00', '2026-11-03 10:00:00', 'zero month or day'),
    (3, '2026-11-03', '2026-11-03 12:34:56', '2026-11-03 12:34:56', 'real dates');
SET SESSION sql_mode = @fixture_sql_mode;

-- Names at MySQL's 64-character limit, and names that need quoting (reserved words, a space, a backtick, quotes,
-- right-to-left letters, SQL in a name).
CREATE TABLE this_table_name_is_sixty_four_characters_long_the_most_mysql_has (
    id INT NOT NULL PRIMARY KEY,
    the_column_name_is_sixty_four_characters_long_the_maximum_length VARCHAR(64) NOT NULL,
    KEY this_index_name_is_sixty_four_characters_long_the_most_mysql_has
        (the_column_name_is_sixty_four_characters_long_the_maximum_length)
) ENGINE=InnoDB;
INSERT INTO this_table_name_is_sixty_four_characters_long_the_most_mysql_has VALUES
    (1, 'a value in a column with a 64-character name');
CREATE VIEW this_view_name_is_sixty_four_characters_long_the_maximum_allowed AS
    SELECT * FROM this_table_name_is_sixty_four_characters_long_the_most_mysql_has;

CREATE TABLE `order details` (
    `id` INT NOT NULL PRIMARY KEY,
    `group` VARCHAR(20) NULL,
    `order` INT NULL,
    `select` VARCHAR(20) NULL,
    `we``ird "column"` VARCHAR(20) NULL,
    `it's` VARCHAR(20) NULL,
    `Ünïcödé` VARCHAR(20) NULL
) ENGINE=InnoDB;
INSERT INTO `order details` VALUES (1, 'g', 2, 's', 'backtick', 'apostrophe', 'ü');
CREATE TABLE `טבלה` (
    `מזהה` INT NOT NULL PRIMARY KEY,
    `שם` VARCHAR(50) NOT NULL
) ENGINE=InnoDB;
INSERT INTO `טבלה` VALUES (1, 'שלום'), (2, 'עולם');
CREATE TABLE `x``; DROP TABLE nothing; --` (id INT NOT NULL PRIMARY KEY) ENGINE=InnoDB;
INSERT INTO `x``; DROP TABLE nothing; --` VALUES (1);

-- Views: a join with aggregates, an updatable one WITH CHECK OPTION, and one that runs as its caller.
CREATE VIEW customer_order_totals AS
    SELECT c.id AS customer_id, c.name, COUNT(o.id) AS orders, COALESCE(SUM(o.total), 0) AS total
    FROM customers c LEFT JOIN orders o ON o.customer_id = c.id
    GROUP BY c.id, c.name;
CREATE VIEW paid_orders AS
    SELECT id, customer_id, ordered_at, total FROM orders WHERE status = 'paid'
    WITH CHECK OPTION;
CREATE SQL SECURITY INVOKER VIEW product_colors AS
    SELECT sku, name, color FROM products WHERE color IS NOT NULL;

-- Functions and procedures: one result set and an OUT parameter, two result sets (CLIENT_MULTI_RESULTS).
DELIMITER ;;
CREATE FUNCTION order_total(p_order INT) RETURNS DECIMAL(12,2)
    READS SQL DATA DETERMINISTIC
    COMMENT 'The sum of an order''s lines'
    RETURN (SELECT COALESCE(SUM(line_total), 0) FROM order_items WHERE order_id = p_order);;
CREATE FUNCTION greeting(p_name VARCHAR(50)) RETURNS VARCHAR(100) CHARSET utf8mb4
    NO SQL DETERMINISTIC
    RETURN CONCAT('Hello, ', p_name, '!');;
CREATE PROCEDURE customer_orders(IN p_customer INT, OUT p_count INT)
    READS SQL DATA
BEGIN
    SELECT id, ordered_at, status, total FROM orders WHERE customer_id = p_customer ORDER BY id;
    SELECT COUNT(*) INTO p_count FROM orders WHERE customer_id = p_customer;
END;;
CREATE PROCEDURE two_results()
    READS SQL DATA
BEGIN
    SELECT COUNT(*) AS customers FROM customers;
    SELECT COUNT(*) AS orders FROM orders;
END;;
CREATE PROCEDURE this_routine_name_is_sixty_four_characters_long_the_most_allowed()
    NO SQL
    SELECT 'a procedure with a 64-character name' AS result;;
DELIMITER ;

-- Events (they start in 2037, the latest TIMESTAMP every server takes), one enabled and one disabled.
CREATE EVENT purge_old_log ON SCHEDULE EVERY 1 DAY STARTS '2037-01-01 00:00:00' DISABLE
    COMMENT 'Deletes log lines older than a year'
    DO DELETE FROM no_pk_log WHERE logged_at < NOW() - INTERVAL 1 YEAR;
CREATE EVENT recount_orders ON SCHEDULE EVERY 1 HOUR STARTS '2037-01-01 00:00:00' ENABLE
    DO UPDATE orders SET total = order_total(id) WHERE id < 0;

-- A million rows, made in SQL: a cross join of digits (MySQL 5.7 has no recursive CTE), in ten transactions of
-- 100,000 rows, so that a seeding server needs little memory.
CREATE TABLE digits (d TINYINT NOT NULL PRIMARY KEY) ENGINE=InnoDB;
INSERT INTO digits VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9);
CREATE TABLE big (
    id INT NOT NULL PRIMARY KEY,
    name VARCHAR(40) NOT NULL,
    amount DECIMAL(12,2) NOT NULL,
    created_at DATETIME NOT NULL,
    category ENUM('red', 'green', 'blue', 'cyan', 'magenta') NOT NULL,
    flag BOOLEAN NOT NULL,
    note VARCHAR(100) NULL,
    KEY created_at (created_at),
    KEY category (category)
) ENGINE=InnoDB;
DELIMITER ;;
CREATE PROCEDURE fill_big()
BEGIN
    DECLARE chunk INT DEFAULT 0;
    WHILE chunk < 10 DO
        INSERT INTO big (id, name, amount, created_at, category, flag, note)
            SELECT n, CONCAT('row ', n), (n * 7919 % 1000000) / 100, TIMESTAMP('2020-01-01') + INTERVAL n MINUTE,
                   1 + n % 5, n % 2, IF(n % 10 = 0, NULL, CONCAT('note ', n))
            FROM (SELECT 1 + a.d + 10 * b.d + 100 * c.d + 1000 * e.d + 10000 * f.d + 100000 * chunk AS n
                  FROM digits a, digits b, digits c, digits e, digits f) AS numbers;
        SET chunk = chunk + 1;
    END WHILE;
END;;
DELIMITER ;
CALL fill_big();
DROP PROCEDURE fill_big;
DROP TABLE digits;

-- A second database, with a name at the 64-character limit.
CREATE DATABASE this_database_name_is_sixty_four_characters_long_the_most_it_has CHARACTER SET utf8mb4;
CREATE TABLE this_database_name_is_sixty_four_characters_long_the_most_it_has.items (
    id INT NOT NULL PRIMARY KEY,
    name VARCHAR(50) NOT NULL
) ENGINE=InnoDB;
INSERT INTO this_database_name_is_sixty_four_characters_long_the_most_it_has.items VALUES (1, 'one'), (2, 'two');
