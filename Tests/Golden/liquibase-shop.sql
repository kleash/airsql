--liquibase formatted sql

--changeset deploy:20261102-001-invoice_numbers
CREATE SEQUENCE `invoice_numbers` start with 1000 minvalue 1 maxvalue 9223372036854775806 increment by 1 cache 1000 nocycle ENGINE=InnoDB;
--rollback DROP SEQUENCE `invoice_numbers`;

--changeset deploy:20261102-002-customers
CREATE TABLE `customers` (
  `id` int(11) NOT NULL,
  `name` varchar(50) NOT NULL,
  `referred_by` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `fk_referrer` (`referred_by`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;
--rollback DROP TABLE `customers`;

--changeset deploy:20261102-003-orders stripComments:false
CREATE TABLE `orders` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `customer_id` int(11) NOT NULL,
  `total` decimal(12,2) NOT NULL DEFAULT 0.00,
  `note` varchar(200) DEFAULT NULL /*!80023 INVISIBLE */,
  PRIMARY KEY (`id`),
  KEY `fk_orders_customer` (`customer_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;
--rollback DROP TABLE `orders`;

--changeset deploy:20261102-004-x___DROP_TABLE_nothing__--
CREATE TABLE `x``; DROP TABLE nothing; --` (
  `id` int(11) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;
--rollback DROP TABLE `x``; DROP TABLE nothing; --`;

--changeset deploy:20261102-005-fk_referrer
ALTER TABLE `customers` ADD CONSTRAINT `fk_referrer` FOREIGN KEY (`referred_by`) REFERENCES `customers` (`id`);
--rollback ALTER TABLE `customers` DROP FOREIGN KEY `fk_referrer`;

--changeset deploy:20261102-006-fk_orders_customer
ALTER TABLE `orders` ADD CONSTRAINT `fk_orders_customer` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) ON DELETE CASCADE;
--rollback ALTER TABLE `orders` DROP FOREIGN KEY `fk_orders_customer`;

--changeset deploy:20261102-007-refund_total splitStatements:false
CREATE FUNCTION `refund_total`(p_order BIGINT) RETURNS decimal(12,2)
    READS SQL DATA
BEGIN
  DECLARE t DECIMAL(12,2);
  # rollback nothing here: this only reads
  SELECT total INTO t FROM orders WHERE id = p_order;
  IF t IS NULL THEN RETURN 0; END IF;
  RETURN t;
END
--rollback DROP FUNCTION `refund_total`;

--changeset deploy:20261102-008-touch
CREATE PROCEDURE `touch`()
SELECT 1;
--rollback DROP PROCEDURE `touch`;

--changeset deploy:20261102-009-order_totals runOnChange:true
CREATE OR REPLACE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `order_totals` AS select `orders`.`customer_id` AS `customer_id`,sum(`orders`.`total`) AS `total` from `orders` group by `orders`.`customer_id`;
--rollback DROP VIEW `order_totals`;

--changeset deploy:20261102-010-big_spenders runOnChange:true
CREATE OR REPLACE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `big_spenders` AS select `t`.`customer_id` AS `customer_id` from `order_totals` `t` where `t`.`total` > 1000;
--rollback DROP VIEW `big_spenders`;

--changeset deploy:20261102-011-orders_bi splitStatements:false
CREATE TRIGGER `orders_bi` BEFORE INSERT ON `orders` FOR EACH ROW BEGIN
  IF NEW.total < 0 THEN SET NEW.total = 0; END IF;
END
--rollback DROP TRIGGER `orders_bi`;

--changeset deploy:20261102-012-nightly
CREATE EVENT `nightly` ON SCHEDULE EVERY 1 DAY STARTS '2037-01-01 00:00:00' ON COMPLETION NOT PRESERVE DISABLE DO DELETE FROM orders WHERE total = 0;
--rollback DROP EVENT `nightly`;
