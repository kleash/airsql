--liquibase formatted sql

--changeset deploy:20261102-001-invoice_numbers
--preconditions onFail:MARK_RAN onError:HALT
--precondition-sql-check expectedResult:0 SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'invoice_numbers'
CREATE SEQUENCE `invoice_numbers` start with 1000 minvalue 1 maxvalue 9223372036854775806 increment by 1 cache 1000 nocycle ENGINE=InnoDB;

--changeset deploy:20261102-002-customers
--preconditions onFail:MARK_RAN onError:HALT
--precondition-sql-check expectedResult:0 SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'customers'
CREATE TABLE `customers` (
  `id` int(11) NOT NULL,
  `name` varchar(50) NOT NULL,
  `referred_by` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `fk_referrer` (`referred_by`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

--changeset deploy:20261102-003-orders stripComments:false
--preconditions onFail:MARK_RAN onError:HALT
--precondition-sql-check expectedResult:0 SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'orders'
CREATE TABLE `orders` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `customer_id` int(11) NOT NULL,
  `total` decimal(12,2) NOT NULL DEFAULT 0.00,
  `note` varchar(200) DEFAULT NULL /*!80023 INVISIBLE */,
  PRIMARY KEY (`id`),
  KEY `fk_orders_customer` (`customer_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

--changeset deploy:20261102-004-x___DROP_TABLE_nothing__--
--preconditions onFail:MARK_RAN onError:HALT
--precondition-sql-check expectedResult:0 SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'x`; DROP TABLE nothing; --'
CREATE TABLE `x``; DROP TABLE nothing; --` (
  `id` int(11) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;

--changeset deploy:20261102-005-fk_referrer
--preconditions onFail:MARK_RAN onError:HALT
--precondition-sql-check expectedResult:0 SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = 'customers' AND CONSTRAINT_NAME = 'fk_referrer' AND CONSTRAINT_TYPE = 'FOREIGN KEY'
ALTER TABLE `customers` ADD CONSTRAINT `fk_referrer` FOREIGN KEY (`referred_by`) REFERENCES `customers` (`id`);

--changeset deploy:20261102-006-fk_orders_customer
--preconditions onFail:MARK_RAN onError:HALT
--precondition-sql-check expectedResult:0 SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = 'orders' AND CONSTRAINT_NAME = 'fk_orders_customer' AND CONSTRAINT_TYPE = 'FOREIGN KEY'
ALTER TABLE `orders` ADD CONSTRAINT `fk_orders_customer` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) ON DELETE CASCADE;

--changeset deploy:20261102-007-refund_total endDelimiter://
--preconditions onFail:MARK_RAN onError:HALT
--precondition-sql-check expectedResult:0 SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_NAME = 'refund_total' AND ROUTINE_TYPE = 'FUNCTION'
CREATE DEFINER=`root`@`%` FUNCTION `refund_total`(p_order BIGINT) RETURNS decimal(12,2)
    READS SQL DATA
BEGIN
  DECLARE t DECIMAL(12,2);
  # rollback nothing here: this only reads
  SELECT total INTO t FROM orders WHERE id = p_order;
  IF t IS NULL THEN RETURN 0; END IF;
  RETURN t;
END
//

--changeset deploy:20261102-008-touch
--preconditions onFail:MARK_RAN onError:HALT
--precondition-sql-check expectedResult:0 SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_NAME = 'touch' AND ROUTINE_TYPE = 'PROCEDURE'
CREATE DEFINER=`root`@`%` PROCEDURE `touch`()
SELECT 1;

--changeset deploy:20261102-009-order_totals runOnChange:true
CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `order_totals` AS select `orders`.`customer_id` AS `customer_id`,sum(`orders`.`total`) AS `total` from `orders` group by `orders`.`customer_id`;

--changeset deploy:20261102-010-big_spenders runOnChange:true
CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `big_spenders` AS select `t`.`customer_id` AS `customer_id` from `order_totals` `t` where `t`.`total` > 1000;

--changeset deploy:20261102-011-orders_bi endDelimiter://
--preconditions onFail:MARK_RAN onError:HALT
--precondition-sql-check expectedResult:0 SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = DATABASE() AND TRIGGER_NAME = 'orders_bi'
CREATE DEFINER=`root`@`%` TRIGGER `orders_bi` BEFORE INSERT ON `orders` FOR EACH ROW BEGIN
  IF NEW.total < 0 THEN SET NEW.total = 0; END IF;
END
//

--changeset deploy:20261102-012-nightly
--preconditions onFail:MARK_RAN onError:HALT
--precondition-sql-check expectedResult:0 SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA = DATABASE() AND EVENT_NAME = 'nightly'
CREATE DEFINER=`root`@`%` EVENT `nightly` ON SCHEDULE EVERY 1 DAY STARTS '2037-01-01 00:00:00' ON COMPLETION NOT PRESERVE DISABLE DO DELETE FROM orders WHERE total = 0;
