extension AttackCorpus {
    static let withAndExplain = [
        "WITH x AS (SELECT 1) DELETE FROM users",
        "WITH x AS (SELECT id FROM users) UPDATE users SET admin = 1 WHERE id IN (SELECT id FROM x)",
        "WITH RECURSIVE x (n) AS (SELECT 1) INSERT INTO t SELECT n FROM x",
        "WITH x AS (SELECT 1), y AS (SELECT 2) DELETE t FROM t JOIN x",
        "(WITH x AS (SELECT 1) DELETE FROM users)",
        "EXPLAIN ANALYZE SELECT * FROM users",
        "EXPLAIN ANALYZE UPDATE users SET admin = 1",
        "EXPLAIN ANALYZE FORMAT=TREE SELECT 1",
        "EXPLAIN FORMAT=JSON ANALYZE SELECT 1",
        "explain analyze delete from users",
        "EXPLAIN UPDATE users SET admin = 1",
        "EXPLAIN DELETE FROM users",
        "DESCRIBE INSERT INTO users VALUES (1)",
        "DESC REPLACE INTO users VALUES (1)",
        "EXPLAIN WITH x AS (SELECT 1) DELETE FROM users",
        "EXPLAIN DROP TABLE users",
        "ANALYZE SELECT * FROM users",
        "ANALYZE FORMAT=JSON SELECT 1",
        "ANALYZE TABLE users",
    ]

    static let locks = [
        "SELECT * FROM users FOR UPDATE",
        "SELECT * FROM users FOR UPDATE NOWAIT",
        "SELECT * FROM users FOR UPDATE SKIP LOCKED",
        "SELECT * FROM users FOR UPDATE OF users",
        "SELECT * FROM users FOR UPDATE WAIT 5",
        "SELECT * FROM users FOR SHARE",
        "SELECT * FROM users FOR SHARE NOWAIT",
        "SELECT * FROM users LOCK IN SHARE MODE",
        "select * from users for /* x */ update",
        "SELECT * FROM users\nFOR\nUPDATE",
        "SELECT * FROM users FOR#\nUPDATE",
        "SELECT * FROM (SELECT * FROM users FOR UPDATE) AS x",
        "SELECT * FROM users WHERE id IN (SELECT id FROM t FOR SHARE)",
        "WITH x AS (SELECT * FROM users FOR UPDATE) SELECT * FROM x",
        "(SELECT * FROM users) UNION (SELECT * FROM users FOR UPDATE)",
    ]

    static let sequencesAndAssignments = [
        "SELECT NEXTVAL(order_seq)",
        "SELECT SETVAL(order_seq, 1000)",
        "SELECT NEXT VALUE FOR order_seq",
        "SELECT order_seq.nextval",
        "SELECT * FROM t WHERE id = NEXT VALUE FOR order_seq",
        "SELECT @a := 1",
        "SELECT @total := SUM(amount) FROM orders",
        "SELECT * FROM users WHERE (@x := id) > 0",
    ]

    static let temporaryTables = [
        "CREATE TEMPORARY TABLE scratch AS SELECT * FROM users",
        "CREATE TEMPORARY TABLE scratch (a INT)",
        "DROP TEMPORARY TABLE scratch",
        "INSERT INTO scratch VALUES (1)",
        "EXPLAIN CREATE TEMPORARY TABLE scratch (a INT)",
        "SELECT * FROM users; CREATE TEMPORARY TABLE scratch (a INT)",
    ]

    static let severalStatements = [
        "SELECT 1; DROP TABLE users",
        "SELECT 1;DELETE FROM users",
        "SHOW TABLES; SET GLOBAL read_only = 0",
        "SELECT ';'; DROP TABLE users",
        "SELECT 1;;SELECT 2",
        "SELECT 1; SELECT 2",
        "DESCRIBE users; TRUNCATE users",
        "SELECT 1\n;\nUPDATE users SET admin = 1",
        "DELIMITER //\nSELECT 1//",
        "DELIMITER ;\nSELECT 1",
    ]

    static let otherStatements = [
        "UPDATE users SET admin = 1", "DELETE FROM users", "INSERT INTO users VALUES (1)",
        "REPLACE INTO users VALUES (1)", "DROP TABLE users", "TRUNCATE users", "ALTER TABLE users ADD c INT",
        "CREATE TABLE t (a INT)", "GRANT ALL ON *.* TO 'x'@'%'", "REVOKE ALL ON *.* FROM 'x'@'%'", "CALL purge_old()",
        "DO SLEEP(1)", "HANDLER users OPEN", "LOAD DATA INFILE '/tmp/x' INTO TABLE users", "SET GLOBAL read_only = 0",
        "SET @x = 1", "SET NAMES latin1", "SET sql_mode = 'NO_BACKSLASH_ESCAPES'", "LOCK TABLES users READ",
        "UNLOCK TABLES", "KILL 1", "KILL QUERY 1", "FLUSH TABLES", "PREPARE s FROM 'DELETE FROM users'", "EXECUTE s",
        "START TRANSACTION", "BEGIN", "COMMIT", "ROLLBACK", "XA START 'x'", "RENAME TABLE a TO b",
        "OPTIMIZE TABLE users", "REPAIR TABLE users", "CHECK TABLE users", "CHECKSUM TABLE users",
        "INSTALL PLUGIN x SONAME 'x.so'", "UNINSTALL PLUGIN x", "SHUTDOWN", "RESTART",
        "CHANGE MASTER TO MASTER_HOST = 'db'", "CHANGE REPLICATION SOURCE TO SOURCE_HOST = 'db'", "STOP REPLICA",
        "PURGE BINARY LOGS TO 'binlog.000002'", "RESET MASTER", "TABLE users", "VALUES ROW(1)", "CREATE USER x",
        "ALTER USER CURRENT_USER() IDENTIFIED BY 'x'", "CREATE FUNCTION f RETURNS STRING SONAME 'udf.so'",
    ]

    static let brokenText = [
        "", "   ", "-- only a comment", ";", "/* */", "SELECT 'abc", "SELECT `abc", "SELECT \"abc", "SELECT 1\u{0}",
        "SELECT 1\u{0}; DROP TABLE users",
    ]
}
