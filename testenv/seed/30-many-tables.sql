-- AirSQL lab: the "many" server's database of 5,000 tables, for the schema cache's large-server paths. Every server
-- runs this file; only the one whose host name is "many" (docker-compose.yml) makes the tables.
DELIMITER ;;
CREATE PROCEDURE fixture.lab_many_tables(p_count INT)
BEGIN
    DECLARE i INT DEFAULT 1;
    IF @@hostname = 'many' THEN
        CREATE DATABASE many_tables CHARACTER SET utf8mb4;
        WHILE i <= p_count DO
            SET @lab_statement = CONCAT('CREATE TABLE many_tables.t', LPAD(i, 4, '0'), ' (',
                'id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100) NOT NULL, amount DECIMAL(10,2) NULL, ',
                'created_at DATETIME NOT NULL, status ENUM(''new'', ''done'') NOT NULL DEFAULT ''new'', parent_id INT NULL, ',
                'KEY parent_id (parent_id)) COMMENT ''table ', i, ' of ', p_count, '''');
            PREPARE lab_statement FROM @lab_statement;
            EXECUTE lab_statement;
            DEALLOCATE PREPARE lab_statement;
            SET i = i + 1;
        END WHILE;
    END IF;
END;;
DELIMITER ;
CALL fixture.lab_many_tables(5000);
DROP PROCEDURE fixture.lab_many_tables;
