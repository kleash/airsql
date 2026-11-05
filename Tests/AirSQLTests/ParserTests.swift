@testable import AirSQLCore
import Foundation
import Testing

@Suite struct ParserTests {
    func one(_ sql: String) -> SQLParsedStatement { SQLParser.parse(sql)[0] }
    func text(_ sql: String, _ range: Range<Int>) -> String { (sql as NSString).substring(with: NSRange(range)) }
    /// The first error's message, or nil.
    func error(_ sql: String) -> String? { one(sql).errors.first?.message }

    @Test func readsASelect() throws {
        let sql = "SELECT DISTINCT o.id, COUNT(*) AS n, total t FROM shop.orders AS o LEFT JOIN customers c ON c.id = o.customer_id "
            + "WHERE o.total > 10 AND c.name LIKE 'a%' GROUP BY o.id HAVING n > 1 ORDER BY n DESC, 2 LIMIT 5, 10"
        let statement = one(sql)
        #expect(statement.kind == .select && statement.errors.isEmpty)
        let select = try #require(statement.query?.blocks.first)
        #expect(select.distinct)
        #expect(select.items.map { $0.alias?.value } == [nil, "n", "t"])
        #expect(select.from.map { $0.name?.last.value } == ["orders", "customers"])
        #expect(select.from[0].name?.qualifier?.value == "shop" && select.from[0].alias?.value == "o")
        #expect(select.from[1].join?.kind == "LEFT JOIN" && select.from[1].join?.on != nil)
        #expect(select.whereClause?.op == "AND" && select.whereClause?.children.count == 2)
        #expect(select.groupBy.count == 1 && select.having != nil)
        #expect(select.orderBy.map { $0.direction?.value } == ["DESC", nil])
        #expect(select.limit.count == 2)
        #expect(text(sql, select.items[1].range) == "COUNT(*) AS n")
        #expect(text(sql, select.from[1].range) == "customers c")
    }

    @Test func rangesCountFromTheWholeText() throws {
        let sql = "SELECT 1;\n-- é\nSELECT é FROM t"
        let statements = SQLParser.parse(sql)
        #expect(statements.count == 2)
        let item = try #require(statements[1].query?.blocks[0].items[0])
        #expect(text(sql, item.expr.range) == "é")
        #expect(text(sql, statements[1].range) == "SELECT é FROM t")
    }

    @Test func readsCTEsSubqueriesAndUnions() throws {
        let sql = """
            WITH RECURSIVE a (x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM a WHERE x < 3), b AS (SELECT * FROM t)
            SELECT * FROM a, (SELECT id FROM u) AS d (i) WHERE EXISTS (SELECT 1 FROM v) AND a.x IN (SELECT i FROM w) ORDER BY 1
            """
        let query = try #require(one(sql).query)
        #expect(one(sql).errors.isEmpty)
        #expect(query.recursive && query.ctes.map(\.name.value) == ["a", "b"])
        #expect(query.ctes[0].columns.map(\.value) == ["x"])
        #expect(query.ctes[0].query.blocks.count == 2 && query.ctes[0].query.setOperators == ["UNION ALL"])
        let derived = query.blocks[0].from[1]
        #expect(derived.alias?.value == "d" && derived.columnAliases.map(\.value) == ["i"] && derived.query != nil)
        #expect(query.blocks[0].whereClause?.children.count == 2)
    }

    @Test func aUnionOwnsItsLastOrderAndLimit() throws {
        let query = try #require(one("SELECT a FROM t UNION SELECT b FROM u ORDER BY 1 LIMIT 3").query)
        #expect(query.orderBy.count == 1 && query.limit.count == 1 && query.blocks[1].orderBy.isEmpty)
        let brackets = try #require(one("(SELECT 1) UNION (SELECT 2) ORDER BY 1").query)
        #expect(brackets.blocks.count == 2 && brackets.blocks[0].nested != nil && brackets.orderBy.count == 1)
    }

    @Test func nestedJoinsComeFlat() throws {
        let select = try #require(one("SELECT 1 FROM a LEFT JOIN (b JOIN c ON b.x = c.x) ON a.y = b.y, d NATURAL JOIN e").query?.blocks[0])
        #expect(select.from.map { $0.name?.last.value } == ["a", "b", "c", "d", "e"])
        #expect(select.from[1].join?.kind == "LEFT JOIN" && select.from[1].join?.on != nil)
        #expect(select.from[4].join?.natural == true)
    }

    @Test func precedenceFollowsTheManual() throws {
        let plain = try #require(one("SELECT a OR b AND NOT c = 1 + 2 * 3").query?.blocks[0].items[0].expr)
        #expect(plain.op == "OR" && plain.children[1].op == "AND" && plain.children[1].children[1].op == "NOT")
        let comparison = plain.children[1].children[1].children[0]
        #expect(comparison.op == "=" && comparison.children[1].op == "+" && comparison.children[1].children[1].op == "*")
        let between = try #require(one("SELECT a BETWEEN 1 AND 2 AND b").query?.blocks[0].items[0].expr)
        #expect(between.op == "AND" && between.children.count == 2)
        let chain = try #require(one("SELECT a AND b AND c AND d").query?.blocks[0].items[0].expr)
        #expect(chain.children.count == 4)
    }

    @Test func readsWrites() throws {
        let insert = one("INSERT IGNORE INTO t (a, b) VALUES (1, 'x'), (2, DEFAULT) AS new ON DUPLICATE KEY UPDATE b = new.b")
        #expect(insert.kind == .insert && insert.errors.isEmpty)
        #expect(insert.write?.columns.map(\.value) == ["a", "b"])
        #expect(insert.write?.rows.map(\.values.count) == [2, 2])
        #expect(insert.write?.rowAlias?.value == "new" && insert.write?.onDuplicate.count == 1)
        let select = one("INSERT INTO t (a) SELECT x FROM u")
        #expect(select.query != nil && select.errors.isEmpty)
        let set = one("REPLACE t SET a = 1, b = 2")
        #expect(set.kind == .replace && set.write?.assignments.count == 2)
        let update = one("UPDATE a JOIN b ON a.x = b.x SET a.y = 1, b.z = DEFAULT WHERE a.k > 0 ORDER BY a.k LIMIT 3")
        #expect(update.kind == .update && update.errors.isEmpty)
        #expect(update.write?.tables.count == 2 && update.write?.whereClause != nil && update.write?.limit.count == 1)
        let delete = one("DELETE FROM t WHERE a = 1 RETURNING id")
        #expect(delete.kind == .delete && delete.write?.tables.count == 1 && delete.write?.returning.count == 1)
        let multiple = one("DELETE a, b.* FROM a JOIN b USING (id) WHERE a.x = 1")
        #expect(multiple.write?.deleteTargets.count == 2 && multiple.write?.tables.count == 2 && multiple.errors.isEmpty)
        let using = one("DELETE FROM a, b USING a JOIN b ON a.x = b.x")
        #expect(using.write?.deleteTargets.count == 2 && using.write?.tables.count == 2 && using.errors.isEmpty)
        let with = one("WITH c AS (SELECT 1 AS id) DELETE FROM t WHERE id IN (SELECT id FROM c)")
        #expect(with.kind == .delete && with.ctes.count == 1)
    }

    @Test func readsDefinitions() throws {
        let table = one("""
            CREATE TEMPORARY TABLE IF NOT EXISTS shop.t (
              id INT UNSIGNED NOT NULL AUTO_INCREMENT, name VARCHAR(20) DEFAULT 'x' COMMENT 'y', price DECIMAL(10, 2),
              PRIMARY KEY (id), KEY name_i (name), CONSTRAINT c FOREIGN KEY (id) REFERENCES u (id)
            ) ENGINE = InnoDB
            """)
        #expect(table.kind == .create && table.errors.isEmpty && table.objects[0].kind == "TABLE")
        #expect(table.columns.map(\.name.value) == ["id", "name", "price"])
        #expect(table.columns[0].type == "INT UNSIGNED" && table.columns[0].notNull && table.columns[0].autoIncrement)
        #expect(table.columns[1].type == "VARCHAR(20)" && table.columns[1].hasDefault && table.columns[2].type == "DECIMAL(10,2)")
        #expect(one("CREATE TABLE t AS SELECT a FROM u").query != nil)
        #expect(one("CREATE TABLE t (a INT) ENGINE=InnoDB SELECT a FROM u").query != nil)
        #expect(one("CREATE TABLE t LIKE u").objects.count == 2)
        let view = one("CREATE OR REPLACE ALGORITHM=MERGE DEFINER=`a`@`b` SQL SECURITY INVOKER VIEW v (a) AS SELECT 1 WITH CHECK OPTION")
        #expect(view.objects[0].kind == "VIEW" && view.query != nil && view.errors.isEmpty)
        let index = one("CREATE UNIQUE INDEX i ON t (a(10) DESC, b) USING BTREE")
        #expect(index.objects.map(\.kind) == ["INDEX", "TABLE"] && index.errors.isEmpty)
        let routine = one("CREATE DEFINER=root@localhost PROCEDURE p(IN a INT, OUT b DECIMAL(10,2), c TEXT) COMMENT 'x' BEGIN SELECT 1; END")
        #expect(routine.parameters.map(\.value) == ["a", "b", "c"] && routine.bodyStart != nil && routine.shallow)
        #expect(one("DROP TABLE IF EXISTS a, b.c CASCADE").objects.map(\.name.last.value) == ["a", "c"])
        #expect(one("DROP INDEX i ON t").objects.map(\.kind) == ["INDEX", "TABLE"])
        #expect(one("ALTER TABLE shop.t ADD COLUMN x INT, DROP y").objects[0].name.last.value == "t")
        #expect(one("TRUNCATE TABLE t").objects.count == 1 && one("TRUNCATE t").objects.count == 1)
        #expect(one("RENAME TABLE a TO b, c TO d").objects.count == 4)
        #expect(one("USE shop").kind == .use && one("USE shop").objects[0].name.last.value == "shop")
        #expect(one("CALL db.p(1, @a)").arguments.count == 2)
        #expect(one("EXPLAIN FORMAT=JSON SELECT 1").query != nil && one("EXPLAIN FORMAT=JSON SELECT 1").kind == .explain)
        #expect(one("EXPLAIN UPDATE t SET a = 1").write != nil)
        #expect(one("DESC t").objects.count == 1)
        #expect(one("SET @a = (SELECT 1), @b := 2").arguments.count == 2)
    }

    @Test func theRestStaysShallowAndSilent() {
        for sql in ["SHOW TABLES", "GRANT SELECT ON *.* TO a", "SET NAMES utf8mb4", "SET autocommit = ON", "BEGIN", "COMMIT",
                    "LOAD DATA INFILE 'x' INTO TABLE t", "HELP 'x'", "FLUSH TABLES", "KILL 3", "ALTER USER a IDENTIFIED BY 'b'",
                    "ANALYZE TABLE t", "CREATE USER a", "CREATE EVENT e ON SCHEDULE EVERY 1 DAY DO SELECT 1", "END", "whatever this is"] {
            #expect(one(sql).shallow, "\(sql)")
            #expect(one(sql).errors.isEmpty, "\(sql)")
        }
    }

    /// Valid statements a false alarm would underline.
    @Test func validSQLHasNoErrors() {
        let valid = [
            "SELECT 1", "SELECT 1 FROM DUAL", "SELECT * FROM t", "SELECT t.* FROM t", "SELECT db.t.* FROM db.t", "(SELECT 1)", "((SELECT 1))",
            "SELECT `select` FROM `from`", "SELECT t.order, t.select FROM t", "SELECT a 'alias', b \"other\", c AS `x` FROM t",
            "SELECT 'a' 'b', N'x', _utf8mb4'y', X'41', b'1', 0x41, 1e3, .5", "SELECT DATE '2020-01-01', TIME '10:00', TIMESTAMP '2020-01-01 10:00:00'",
            "SELECT CASE WHEN a THEN 1 WHEN b THEN 2 ELSE 3 END, CASE x WHEN 1 THEN 2 END FROM t",
            "SELECT CAST(a AS UNSIGNED), CAST(a AS DECIMAL(10, 2)), CONVERT(a, CHAR(3)), CONVERT(a USING utf8mb4) FROM t",
            "SELECT EXTRACT(YEAR FROM d), TIMESTAMPDIFF(MONTH, a, b), TIMESTAMPADD(DAY, 1, a), GET_FORMAT(DATE, 'USA') FROM t",
            "SELECT TRIM(BOTH 'x' FROM a), TRIM(LEADING FROM a), TRIM('x' FROM a), TRIM(a), SUBSTRING(a FROM 1 FOR 2), POSITION('a' IN b) FROM t",
            "SELECT GROUP_CONCAT(DISTINCT a ORDER BY b DESC SEPARATOR ', '), COUNT(DISTINCT a, b), SUM(ALL a) FROM t",
            "SELECT d + INTERVAL 1 DAY, DATE_ADD(d, INTERVAL '1:2' HOUR_MINUTE), INTERVAL 1 YEAR + d, INTERVAL(1, 2, 3) FROM t",
            "SELECT MATCH (a, b) AGAINST ('x' IN NATURAL LANGUAGE MODE), MATCH (a) AGAINST ('y' WITH QUERY EXPANSION) FROM t",
            "SELECT ROW_NUMBER() OVER (PARTITION BY a ORDER BY b ROWS BETWEEN 1 PRECEDING AND CURRENT ROW), SUM(a) OVER w, RANK() OVER () FROM t WINDOW w AS (ORDER BY a)",
            "SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY a) OVER (PARTITION BY b) FROM t",
            "SELECT a->'$.b', a->>'$.c', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP(), NOW(3), CURRENT_USER, CURRENT_USER() FROM t",
            "SELECT a IS NULL, a IS NOT NULL, a IS TRUE, a IS NOT UNKNOWN, a NOT IN (1, 2), a NOT LIKE 'x' ESCAPE '|', a NOT BETWEEN 1 AND 2, a SOUNDS LIKE b FROM t",
            "SELECT a REGEXP 'x', a NOT RLIKE 'y', (a, b) = (1, 2), (a, b) IN ((1, 2), (3, 4)), ROW(1, 2) = ROW(a, b), 1 MEMBER OF ('[1]'), a COLLATE utf8mb4_bin, BINARY a, BINARY(a) FROM t",
            "SELECT a = ANY (SELECT 1), a > ALL (SELECT 2), a <> SOME (SELECT 3), - a, + a, ~ a, ! a, NOT a, 1 DIV 2, 1 MOD 2, 5 % 2, 1 ^ 2, 1 << 2, 1 >> 2, 1 & 2, 1 | 2, a <=> b, a && b, a || b, a XOR b FROM t",
            "SELECT @a := 1, @b, @@session.sql_mode, @@global.x, ?, :name FROM t", "SELECT IF(a, 1, 2), LEFT(a, 1), RIGHT(a, 1), REPLACE(a, 'x', 'y'), INSERT(a, 1, 2, 'x'), CHAR(65 USING utf8mb4), DATABASE(), SCHEMA(), MOD(a, 2), REPEAT('a', 2), VALUES(a) FROM t",
            "SELECT db.f(1), `db`.`f`(2), f(), NEXT VALUE FOR s, PREVIOUS VALUE FOR db.s FROM t", "SELECT { d '2020-01-01' }, { fn NOW() }, COUNT(*) FROM t",
            "SELECT STRAIGHT_JOIN SQL_NO_CACHE SQL_CALC_FOUND_ROWS a FROM t", "SELECT a FROM t GROUP BY a WITH ROLLUP", "SELECT a FROM t GROUP BY a DESC",
            "SELECT a FROM t LIMIT 1 OFFSET 2", "SELECT a FROM t LIMIT ?, ?", "SELECT a FROM t LIMIT 5 ROWS EXAMINED 10", "SELECT a FROM t LIMIT ROWS EXAMINED 10",
            "SELECT a FROM t ORDER BY a OFFSET 2 ROWS FETCH NEXT 3 ROWS ONLY", "SELECT a FROM t FETCH FIRST 3 ROWS WITH TIES",
            "SELECT a FROM t FOR UPDATE", "SELECT a FROM t FOR UPDATE OF t NOWAIT", "SELECT a FROM t FOR SHARE SKIP LOCKED", "SELECT a FROM t LOCK IN SHARE MODE",
            "SELECT a INTO @x FROM t", "SELECT a FROM t INTO @x", "SELECT a INTO OUTFILE '/tmp/x' FIELDS TERMINATED BY ',' FROM t", "SELECT 1 INTO DUMPFILE 'x'",
            "SELECT a FROM t PARTITION (p0, p1) AS x", "SELECT a FROM t USE INDEX (i) IGNORE INDEX FOR ORDER BY (j), u FORCE KEY FOR JOIN (k)", "SELECT a FROM t USE INDEX ()",
            "SELECT * FROM a JOIN b USING (x, y) LEFT OUTER JOIN c ON 1 RIGHT JOIN d ON 1 CROSS JOIN e INNER JOIN f STRAIGHT_JOIN g NATURAL LEFT OUTER JOIN h",
            "SELECT * FROM a, LATERAL (SELECT a.x) AS l", "SELECT * FROM a JOIN LATERAL (SELECT 1) l ON TRUE", "SELECT * FROM (a, b)", "SELECT * FROM (a JOIN b)", "SELECT * FROM { OJ a LEFT OUTER JOIN b ON 1 }",
            "SELECT * FROM JSON_TABLE(a, '$[*]' COLUMNS (x INT PATH '$.x', NESTED PATH '$.y' COLUMNS (z INT PATH '$'))) AS j", "SELECT * FROM t FOR SYSTEM_TIME AS OF TIMESTAMP '2020-01-01 00:00:00' AS x", "SELECT * FROM t FOR SYSTEM_TIME ALL",
            "VALUES ROW(1, 2), ROW(3, 4)", "VALUES (1, 2), (3, 4) ORDER BY 1", "TABLE t", "TABLE t ORDER BY a LIMIT 1", "SELECT 1 UNION DISTINCT SELECT 2 EXCEPT ALL SELECT 3 INTERSECT SELECT 4",
            "WITH a AS (SELECT 1) SELECT * FROM a", "WITH RECURSIVE a AS (SELECT 1) UPDATE t SET x = 1", "WITH a AS (VALUES ROW(1)) TABLE a", "SELECT (WITH a AS (SELECT 1) SELECT * FROM a)",
            "INSERT t VALUES ()", "INSERT INTO t () VALUES ()", "INSERT INTO t VALUE (1)", "INSERT INTO t VALUES ROW(1), ROW(2)", "INSERT INTO t (a) (SELECT 1)", "INSERT INTO t SELECT * FROM u ON DUPLICATE KEY UPDATE a = VALUES(a)",
            "INSERT LOW_PRIORITY IGNORE INTO db.t PARTITION (p) SET a = 1 RETURNING *", "INSERT INTO t (a) WITH c AS (SELECT 1) SELECT * FROM c", "INSERT INTO t TABLE u", "REPLACE INTO t VALUES (1)", "INSERT INTO t (t.a) VALUES (1)",
            "UPDATE LOW_PRIORITY IGNORE t SET a = a + 1", "UPDATE a, b SET a.x = b.x WHERE a.id = b.id", "UPDATE t AS x SET x.a := 1 ORDER BY b LIMIT 1", "UPDATE (SELECT 1 AS a) d, t SET t.a = d.a",
            "DELETE LOW_PRIORITY QUICK IGNORE FROM t", "DELETE FROM t ORDER BY a LIMIT 1", "DELETE FROM t AS x WHERE x.a = 1", "DELETE t FROM t JOIN u ON t.a = u.a", "DELETE FROM t PARTITION (p) WHERE 1",
            "CREATE TABLE t (id INT, PRIMARY KEY (id))", "CREATE TABLE t (`key` INT, `index` TEXT)", "CREATE TABLE t (a INT) PARTITION BY HASH (a) PARTITIONS 4", "CREATE TABLE t (a INT GENERATED ALWAYS AS (1 + 2) VIRTUAL)",
            "CREATE TABLE t (LIKE u)", "CREATE TABLE t (SELECT 1 AS a)", "CREATE TABLE IF NOT EXISTS t IGNORE AS SELECT 1 a", "CREATE OR REPLACE TABLE t (a INT)", "CREATE DATABASE IF NOT EXISTS d CHARACTER SET utf8mb4", "CREATE SCHEMA d",
            "CREATE VIEW v AS (SELECT 1)", "CREATE VIEW db.v AS SELECT a FROM t UNION SELECT b FROM u", "CREATE FULLTEXT INDEX i ON t (a)", "CREATE INDEX i USING BTREE ON t (a)", "CREATE INDEX i ON t ((a + 1))",
            "CREATE TRIGGER g BEFORE INSERT ON t FOR EACH ROW SET NEW.a = 1", "CREATE FUNCTION f(a INT) RETURNS INT DETERMINISTIC RETURN a + 1", "CREATE SEQUENCE s START WITH 1",
            "DROP DATABASE IF EXISTS d", "DROP VIEW v", "DROP PROCEDURE IF EXISTS p", "DROP TEMPORARY TABLE t", "DROP USER a", "DROP INDEX `PRIMARY` ON t", "RENAME TABLES a TO b", "RENAME USER a TO b",
            "DESCRIBE SELECT 1", "DESC db.t", "DESCRIBE t a%", "EXPLAIN EXTENDED SELECT 1", "EXPLAIN PARTITIONS SELECT 1", "EXPLAIN ANALYZE SELECT 1", "EXPLAIN FORMAT=TREE SELECT 1", "EXPLAIN t", "EXPLAIN FOR CONNECTION 3", "ANALYZE SELECT 1", "ANALYZE FORMAT=JSON SELECT 1",
            "SET @a = 1", "SET @@sql_mode = ''", "SET GLOBAL a = ON", "CALL p", "CALL p()", "USE `a b`",
        ]
        for sql in valid {
            let wrong = SQLParser.parse(sql).flatMap(\.errors).first?.message
            #expect(wrong == nil, "\(sql)")
        }
    }

    /// The odd corners of real statements, as a second net for false alarms.
    @Test func everydaySQLHasNoErrors() {
        let valid = [
            "SELECT * FROM t1 LEFT JOIN (t2, t3) ON t1.a = t2.a", "SELECT 1 FROM t WHERE a = 'x' COLLATE utf8mb4_bin", "SELECT a, b FROM t ORDER BY a LIMIT 1 FOR UPDATE",
            "SELECT COUNT(*) AS c, b FROM t GROUP BY 2 HAVING c > 1", "SELECT CONCAT(a, ' ', b) name FROM t", "SELECT DISTINCT(a), b FROM t", "SELECT COUNT(DISTINCT(a)) FROM t",
            "SELECT -1, +1, - -1, 1--1", "SELECT CURRENT_DATE + 1, CURDATE() - INTERVAL 1 DAY", "SELECT * FROM t WHERE d > NOW() - INTERVAL 7 DAY", "SELECT ADDDATE(x, INTERVAL 1 MONTH), ADDDATE(x, 1) FROM t",
            "SELECT LAST_INSERT_ID(), FOUND_ROWS(), VERSION(), USER(), CHARSET('a'), COLLATION(a), CHARACTER_LENGTH(a), LOCALTIME(), UTC_TIMESTAMP(3) FROM t", "SELECT a MOD b, a DIV b, ASCII('a'), FORMAT(1, 2), TRUNCATE(1.5, 0) FROM t",
            "SELECT MICROSECOND(a), SECOND(a), MINUTE(a), YEAR(d), DATE(d), TIME(d), TIMESTAMP(d), DATE_FORMAT(d, '%Y') FROM t", "SELECT EXISTS(SELECT 1), 1 = 1 IS TRUE, ROW_COUNT(), GET_LOCK('a', 1), SLEEP(1)",
            "SELECT JSON_OBJECT('a', 1), JSON_ARRAYAGG(a ORDER BY b), JSON_VALUE(a, '$.b' RETURNING CHAR(3)) FROM t", "SELECT a FROM t1 UNION ALL (SELECT b FROM t2 ORDER BY 1 LIMIT 1) LIMIT 5",
            "SELECT * FROM (SELECT 1) a JOIN (SELECT 2) b", "SELECT * FROM t WHERE (a, b) IN (SELECT a, b FROM u)", "SELECT a FROM t WHERE b LIKE CONCAT('%', ?, '%')", "SELECT BINARY 'a' = 'A'", "SELECT a FROM t HAVING a > 1",
            "SELECT a FROM t ORDER BY CASE WHEN a THEN 1 ELSE 2 END DESC, FIELD(b, 1, 2)", "SELECT DATE_SUB(NOW(), INTERVAL -1 DAY)", "SELECT a, @rownum := @rownum + 1 FROM t, (SELECT @rownum := 0) r", "SELECT @a:=1",
            "INSERT INTO t SET a = 1 ON DUPLICATE KEY UPDATE a = a + 1", "INSERT INTO t (a) VALUES (1) ON DUPLICATE KEY UPDATE a = VALUES(a), b = (VALUES(a) + 1)", "INSERT INTO t (a, b) SELECT a, b FROM u WHERE 1 ON DUPLICATE KEY UPDATE a = 1",
            "INSERT INTO t SELECT * FROM u UNION SELECT * FROM v", "UPDATE t SET a = (SELECT MAX(b) FROM u) WHERE c", "UPDATE t SET a = DEFAULT", "UPDATE t1 INNER JOIN t2 USING (id) SET t1.a = 1",
            "DELETE FROM t WHERE a IN (SELECT a FROM (SELECT a FROM t) x)", "LOCK TABLES t READ", "UNLOCK TABLES", "FLUSH PRIVILEGES", "OPTIMIZE TABLE t", "CHECK TABLE t",
            "CREATE TABLE t (a INT) COMMENT 'x' AS SELECT 1",
            "CREATE TABLE t (a INT CHECK (a > 0), b VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin, c ENUM('a', 'b') NOT NULL DEFAULT 'a', d DATETIME ON UPDATE CURRENT_TIMESTAMP, e TIMESTAMP(3) DEFAULT CURRENT_TIMESTAMP(3), INDEX (b), FULLTEXT KEY ft (b))",
            "CREATE TABLE t (a INT, FOREIGN KEY (a) REFERENCES u (b) ON DELETE CASCADE)", "CREATE TABLE t (id INT PRIMARY KEY AUTO_INCREMENT)", "SET @a := (SELECT 1)", "SET @a = 1, @@session.x = 2",
            "SELECT `a`.`b`.`c` FROM a.b", "SELECT a.*, b.x FROM a, b", "SELECT 1 LIMIT 1;", "SELECT * FROM t WHERE a = b'101'", "SELECT .5 + 1.", "SELECT a FROM t WHERE b = :name AND c = :n2",
            "SELECT CAST(a AS JSON), CAST('1' AS SIGNED INTEGER), CAST(a AS CHAR(10) CHARACTER SET utf8) FROM t", "SELECT 1 AS 'a b', 2 \"c d\"", "SELECT a FROM t USE INDEX FOR JOIN (i)", "SELECT * FROM t1 NATURAL RIGHT JOIN t2",
            "SELECT a FROM t PROCEDURE ANALYSE()", "SELECT LAG(a, 1, 0) OVER (ORDER BY b) FROM t", "SELECT a FROM t WHERE MATCH(a) AGAINST('b' IN BOOLEAN MODE) > 0", "SELECT GROUPING(a) FROM t GROUP BY a WITH ROLLUP",
            "SELECT (SELECT 1) + 1, (SELECT 1), (2), ((1))", "(SELECT 1) LIMIT 1", "(SELECT 1) ORDER BY 1", "WITH a AS (SELECT 1) (SELECT * FROM a)", "SELECT * FROM (VALUES ROW(1)) t (a)", "SELECT * FROM (VALUES (1), (2)) t",
            "SELECT * FROM t WHERE a IN (1)", "SELECT a b, c AS d, e FROM t", "SELECT year, month, day, date, time, text, status, name, type, value, comment, data, count, sum FROM t",
            "SELECT t.year FROM year t", "SELECT * FROM user", "SELECT * FROM status WHERE type = 1", "SELECT a FROM t WHERE date > '2020-01-01' AND time < 3", "UPDATE t SET date = NOW(), text = 'x', value = 1",
            "INSERT INTO t (date, text, status) VALUES ('2020-01-01', 'x', 1)", "SELECT CHAR(65), CONVERT('a' USING utf8mb4), CHAR(65 USING utf8mb4), DAY(d), WEEK(d, 1) FROM t",
        ]
        for sql in valid {
            let wrong = SQLParser.parse(sql).flatMap(\.errors).first?.message
            #expect(wrong == nil, "\(sql)")
        }
    }

    @Test func realReadsHaveNoErrors() {
        for sql in ReadCorpus.all {
            let wrong = SQLParser.parse(sql).flatMap(\.errors).first?.message
            #expect(wrong == nil, "\(sql)")
        }
    }

    @Test func saysWhatIsWrong() {
        #expect(error("SELECT FROM t") == "Expected a value, found FROM")
        #expect(error("SELECT a, FROM t") == "Expected a value, found FROM")
        #expect(error("SELECT a FROM") == "Expected a table name")
        #expect(error("SELECT a FROM WHERE b") == "Expected a table name, found WHERE")
        #expect(error("SELECT a FROM t WHERE") == "Expected a value")
        #expect(error("SELECT a FROM t WHERE AND b") == "Expected a value, found AND")
        #expect(error("SELECT a FROM t WHERE a = ") == "Expected a value")
        #expect(error("SELECT a FROM t GROUP a") == "Expected BY after GROUP, found a")
        #expect(error("SELECT a FROM t ORDER BY a WHERE b") == "WHERE can’t come after ORDER")
        #expect(error("SELECT a FROM t LIMIT 1 ORDER BY a") == "ORDER can’t come after LIMIT")
        #expect(error("SELECT a b c FROM t") == "Unexpected c")
        #expect(error("SELECT 1)") == "Unmatched )")
        #expect(error("SELECT a FROM t JOIN") == "Expected a table name")
        #expect(error("SELECT CASE a THEN 1 END") == "Expected WHEN, found THEN")
        #expect(error("SELECT CASE WHEN a THEN 1") == "Expected END to close CASE")
        #expect(error("SELECT a IS 1") == "Expected NULL, TRUE, FALSE or UNKNOWN after IS, found 1")
        #expect(error("SELECT a IN 1") == "Expected ( after IN, found 1")
        #expect(error("SELECT a BETWEEN 1") == "Expected AND after BETWEEN’s first value")
        #expect(error("SELECT INTERVAL 1") == "Expected a unit such as DAY after INTERVAL’s value")
        #expect(error("INSERT INTO t") == "Expected VALUES, SET or SELECT")
        #expect(error("INSERT INTO t VALUES") == "Expected a row in brackets after VALUES")
        #expect(error("UPDATE t") == "Expected SET")
        #expect(error("UPDATE t SET") == "Expected a column name")
        #expect(error("UPDATE t SET a") == "Expected = after the column’s name")
        #expect(error("DELETE t") == "Expected FROM")
        #expect(error("DROP TABLE") == "Expected a name")
        #expect(error("CREATE VIEW v SELECT 1") == "Expected AS after the view’s name, found SELECT")
    }

    @Test func anErrorPointsAtItsToken() throws {
        let sql = "SELECT 1; SELECT a FROM t WHERE AND b"
        let found = try #require(SQLParser.parse(sql)[1].errors.first)
        #expect(text(sql, found.range) == "AND")
        let atEnd = "SELECT a FROM "
        #expect(text(atEnd, try #require(one(atEnd).errors.first).range) == "FROM")
    }

    @Test func missingClosersAreLeftToTheBracketCheck() {
        #expect(one("SELECT (1 + 2").errors.isEmpty)
        #expect(one("SELECT a FROM (SELECT 1").errors.isEmpty)
        #expect(one("SELECT 'open").errors.isEmpty && one("SELECT 'open").shallow)
    }

    @Test func recoversAndKeepsWhatFollows() throws {
        let select = try #require(one("SELECT a, FROM t JOIN u ON WHERE b = 1 ORDER BY c").query?.blocks[0])
        #expect(select.from.count == 2 && select.whereClause != nil && select.orderBy.count == 1)
        #expect(select.items.count == 1)
        let typing = try #require(one("SELECT o. FROM orders o").query?.blocks[0])
        #expect(typing.from.first?.alias?.value == "o")
    }

    @Test func executableCommentsAreReadButNotJudged() {
        let statement = one("SELECT /*!50100 a, */ b FROM t /*! WHERE */")
        #expect(statement.shallow && statement.errors.isEmpty && statement.query != nil)
    }

    @Test func clausesTellWhereACaretIs() throws {
        let sql = "SELECT a FROM t JOIN u ON x WHERE b ORDER BY c"
        let select = try #require(one(sql).query?.blocks[0])
        #expect(select.clauses.map { "\($0.clause)" } == ["selectList", "from", "from", "on", "whereClause", "orderBy"])
    }

    @Test func deepNestingEndsQuietly() {
        // Plain values to expect: a failure would otherwise reflect the whole tree.
        func shallow(_ sql: String) -> Bool { one(sql).shallow }
        let deep = String(repeating: "(", count: 50_000) + "1" + String(repeating: ")", count: 50_000)
        let brackets = shallow("SELECT " + deep)
        #expect(brackets)
        let nots = shallow("SELECT " + String(repeating: "NOT ", count: 50_000) + "1")
        #expect(nots)
        let queries = shallow("SELECT " + String(repeating: "(SELECT ", count: 50_000))
        #expect(queries)
        let sums = shallow("SELECT 1" + String(repeating: " + 1", count: 50_000))
        #expect(sums)
        let joins = shallow("SELECT * FROM " + String(repeating: "(", count: 50_000) + "t")
        #expect(joins)
        let wide = one("SELECT 1 WHERE a" + String(repeating: " OR a", count: 50_000))
        let count = wide.query?.blocks[0].whereClause?.children.count
        let read = !wide.shallow
        #expect(read)
        #expect(count == 50_001)
    }

    @Test func anyTextParses() {
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % n
        }
        let pieces = ["SELECT", "FROM", "(", ")", ",", "a", "t.", "'x", "`", "/*", "*/", "WHERE", "JOIN", "ON", "WITH", "AS", "CASE", "END", "INSERT",
                      "VALUES", "UPDATE", "SET", "=", "*", ".", ";", "DELETE", "CREATE", "TABLE", "DROP", "UNION", "BY", "ORDER", "INTERVAL", "NOT", "IN", "{", "}"]
        for _ in 0..<3000 {
            let sql = (0..<next(14)).map { _ in pieces[next(pieces.count)] }.joined(separator: " ")
            _ = SQLParser.parse(sql)
        }
    }

    /// A large INSERT is the worst text a person opens in the console.
    @Test func parsesABigScriptQuickly() {
        let rows = (0..<20_000).map { "(\($0), 'name \($0)', NOW(), NULL)" }.joined(separator: ", ")
        let start = Date()
        let parsed = SQLParser.parse("INSERT INTO t (a, b, c, d) VALUES " + rows)
        #expect(parsed[0].write?.rows.count == 20_000)
        #expect(Date().timeIntervalSince(start) < 5)  // a debug build; a release one is several times quicker
    }
}

@Suite struct ParserScopeTests {
    func analysis(_ sql: String, snapshot: SchemaSnapshot? = SQLNameCheckTests.snapshot()) -> SQLAnalysis {
        SQLAnalysis(sql, snapshot: snapshot, database: "shop")
    }

    /// Where the `n`th `word` starts.
    func offset(_ sql: String, _ word: String, _ n: Int = 0) -> Int {
        var from = sql.startIndex, found = 0
        while let range = sql.range(of: word, range: from..<sql.endIndex) {
            if found == n { return sql.utf16.distance(from: sql.startIndex, to: range.lowerBound) }
            found += 1
            from = range.upperBound
        }
        return -1
    }

    @Test func aliasesAndTheirUses() throws {
        let sql = "SELECT o.id, o.total FROM orders o WHERE o.id = 1"
        let found = analysis(sql)
        let reference = try #require(found.reference(at: offset(sql, "o.total")))
        #expect(reference.symbol.kind == .tableAlias)
        #expect(found.usages(of: reference.symbol).map(\.range.lowerBound) == [offset(sql, "o.id"), offset(sql, "o.total"), offset(sql, "o WHERE"), offset(sql, "o.id", 1)])
        #expect(found.usages(of: reference.symbol).filter(\.isDeclaration).count == 1)
    }

    @Test func columnsResolveToTheSchemaAcrossStatements() throws {
        let sql = "SELECT total FROM orders; UPDATE orders SET total = 1; SELECT o.total FROM orders o"
        let found = analysis(sql)
        let reference = try #require(found.reference(at: offset(sql, "total")))
        #expect(reference.symbol.kind == .column && reference.symbol.table == "orders" && reference.symbol.database == "shop")
        #expect(found.usages(of: reference.symbol).count == 3)
        let table = try #require(found.reference(at: offset(sql, "orders")))
        #expect(table.symbol.kind == .table && found.usages(of: table.symbol).count == 3)
    }

    @Test func aCaretAtANamesEndCounts() {
        let found = analysis("SELECT id FROM orders")
        #expect(found.reference(at: 7)?.symbol.name == "id" && found.reference(at: 9)?.symbol.name == "id")
        #expect(found.reference(at: 10) == nil)
    }

    @Test func ctesAndDerivedColumnsWorkWithoutASchema() throws {
        let sql = "WITH c (a) AS (SELECT 1), d AS (SELECT 2 AS b) SELECT c.a, x.b, y FROM c, d x, (SELECT 3 AS y) z"
        let found = analysis(sql, snapshot: nil)
        let c = try #require(found.reference(at: offset(sql, "c.a")))
        #expect(c.symbol.kind == .cte && c.symbol.declaration?.lowerBound == offset(sql, "c (a)"))
        let a = try #require(found.reference(at: offset(sql, "a, x.b")))
        #expect(a.symbol.kind == .selectAlias && a.symbol.declaration?.lowerBound == offset(sql, "a) AS"))
        let b = try #require(found.reference(at: offset(sql, "b, y")))
        #expect(b.symbol.declaration?.lowerBound == offset(sql, "b)"))
        let y = try #require(found.reference(at: offset(sql, "y FROM")))
        #expect(y.symbol.declaration?.lowerBound == offset(sql, "y) z"))
        #expect(found.issues.isEmpty)
    }

    @Test func starsCarryColumnsThroughQueries() throws {
        let sql = "SELECT d.name FROM (SELECT * FROM customers) d"
        let found = analysis(sql)
        let name = try #require(found.reference(at: offset(sql, "name")))
        #expect(name.symbol.kind == .column && name.symbol.table == "customers")
    }

    @Test func aRecursiveCTESeesItself() {
        let found = analysis("WITH RECURSIVE c (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 3) SELECT n FROM c")
        #expect(found.issues.isEmpty)
    }

    @Test func aScopeTellsWhatsVisibleAtACaret() throws {
        let sql = "SELECT * FROM orders o WHERE EXISTS (SELECT 1 FROM customers c WHERE  ) AND o.id = 1 "
        let found = analysis(sql)
        let inner = try #require(found.scope(at: offset(sql, "  )") + 1))
        #expect(inner.sources.map(\.name) == ["c"])
        #expect(inner.visibleSources.map(\.name) == ["c", "o"])
        #expect(inner.clause(at: offset(sql, "  )") + 1) == .whereClause)
        let outer = try #require(found.scope(at: sql.utf16.count))
        #expect(outer.sources.map(\.name) == ["o"] && outer.sources[0].columns.count == 5)
        #expect(outer.clause(at: sql.utf16.count) == .whereClause)
    }

    @Test func aHalfTypedStatementStillHasItsScope() throws {
        let sql = "SELECT o. FROM orders o JOIN customers c ON "
        let found = analysis(sql)
        let scope = try #require(found.scope(at: 9))
        #expect(scope.sources.map(\.name) == ["o", "c"])
        #expect(scope.clause(at: 9) == .selectList && scope.clause(at: sql.utf16.count) == .on)
    }

    @Test func aWriteHasAScopeToo() throws {
        let sql = "UPDATE orders o SET o.total = 1 WHERE "
        let scope = try #require(analysis(sql).scope(at: sql.utf16.count))
        #expect(scope.sources.map(\.name) == ["o"] && scope.clause(at: sql.utf16.count) == .whereClause)
        #expect(scope.clause(at: offset(sql, "o.total")) == .set)
    }

    @Test func outputsAnswerOrderByButNotWhere() {
        func names(_ sql: String) -> [String] { analysis(sql).issues.map(\.name) }
        #expect(names("SELECT id + 1 AS n FROM orders ORDER BY n").isEmpty)
        #expect(names("SELECT id + 1 AS n FROM orders GROUP BY n HAVING n > 1").isEmpty)
        #expect(names("SELECT id + 1 AS n FROM orders WHERE n > 1") == ["n"])
    }

    @Test func saysWhichNamesAreAmbiguous() {
        func kinds(_ sql: String) -> [String] { analysis(sql).issues.compactMap { if case .ambiguous(let sources) = $0.kind { return "\($0.name) in \(sources)" } else { return nil } } }
        #expect(kinds("SELECT id FROM orders o JOIN customers c ON c.id = o.id") == [#"id in ["o", "c"]"#])
        #expect(kinds("SELECT id FROM orders JOIN customers USING (id)").isEmpty)
        #expect(kinds("SELECT id FROM orders NATURAL JOIN customers").isEmpty)
        #expect(kinds("SELECT o.id FROM orders o JOIN customers c ON 1 ORDER BY id").isEmpty)
        #expect(kinds("SELECT total FROM orders o JOIN customers c ON 1").isEmpty)
        #expect(kinds("SELECT 1 FROM orders a, orders b WHERE total > 1") == [#"total in ["a", "b"]"#])
        // The nearest scope that has it wins.
        #expect(kinds("SELECT 1 FROM orders WHERE EXISTS (SELECT id FROM customers)").isEmpty)
    }

    @Test func unknownQualifiersAndRoutines() {
        let found = analysis("SELECT x.id FROM orders o; CALL nosuch()")
        #expect(found.issues.map(\.name) == ["x", "nosuch"])
        #expect(analysis("SELECT 1 FROM orders o WHERE EXISTS (SELECT o.id)").issues.isEmpty)
    }
}

@Suite struct InspectionTests {
    static func snapshot() -> SchemaSnapshot {
        func column(_ name: String, nullable: Bool = true, generated: Bool = false, auto: Bool = false) -> SchemaColumn {
            SchemaColumn(name: name, dataType: "int", columnType: "int", nullable: nullable, defaultValue: .none, autoIncrement: auto, onUpdate: nil,
                         generated: generated ? .init(expression: "1", stored: false) : nil, invisible: false, isJSON: false, charset: nil, collation: nil, comment: "")
        }
        var orders = SchemaTable(name: "orders", kind: .table)
        orders.columns = [column("id", nullable: false, auto: true), column("total"), column("customer_id", nullable: false), column("twice", generated: true)]
        orders.indexes = [SchemaIndex(name: "PRIMARY", unique: true, type: "BTREE", parts: [.init(column: "id", expression: nil, prefixLength: nil, descending: false)], visible: true, comment: "")]
        var customers = SchemaTable(name: "customers", kind: .table)
        customers.columns = [column("id", nullable: false), column("name")]
        var shop = SchemaDatabase(name: "shop", charset: "utf8mb4", collation: "utf8mb4_bin")
        shop.tables = [customers, orders]
        shop.detailsLoaded = true
        var snapshot = SchemaSnapshot()
        snapshot.server = SchemaServer(version: "8.4.3")
        snapshot.databases = [shop]
        return snapshot
    }

    func problems(_ sql: String, readOnly: Bool = false) -> [SQLProblem] {
        SQLInspections.problems(SQLAnalysis(sql, snapshot: Self.snapshot(), database: "shop"), readOnly: readOnly)
    }

    /// `code: underlined text` of each problem.
    func found(_ sql: String, readOnly: Bool = false) -> [String] {
        problems(sql, readOnly: readOnly).map { "\($0.code): " + (sql as NSString).substring(with: NSRange($0.range)) }
    }

    /// The text after the first edit fix of the problem at `index`, by title.
    func fixed(_ sql: String, _ title: String) -> String? {
        for problem in problems(sql) {
            for fix in problem.fixes where fix.title == title {
                guard case .edit(let edits) = fix.action else { continue }
                let text = NSMutableString(string: sql)
                for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { text.replaceCharacters(in: NSRange(edit.range), with: edit.text) }
                return text as String
            }
        }
        return nil
    }

    @Test func cleanStatementsSayNothing() {
        for sql in [
            "SELECT id, total FROM orders WHERE total > 1 ORDER BY id DESC LIMIT 5",
            "SELECT c.name, COUNT(*) FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.name",
            "SELECT id, total FROM orders GROUP BY id", "SELECT total + 1 FROM orders GROUP BY total + 1",
            "SELECT total AS t FROM orders GROUP BY t ORDER BY t", "SELECT COUNT(*) FROM orders", "SELECT 1 FROM orders WHERE 1 = 1 AND id = 1",
            "INSERT INTO orders (total, customer_id) VALUES (1, 2), (3, 4)", "INSERT INTO orders VALUES (NULL, 1, 2, DEFAULT)",
            "UPDATE orders SET total = 1 WHERE id = 1", "DELETE FROM orders WHERE id = 1", "WITH c AS (SELECT 1 AS a) SELECT a FROM c",
            "SELECT ROUND(total), ROUND(total, 2), SUBSTRING('a', 1), SUBSTRING('a' FROM 1), NOW(), NOW(3), COALESCE(total, 0) FROM orders",
            "SELECT `rank` FROM (SELECT 1 AS `rank`) d", "SELECT MAX(total) OVER (), id FROM orders GROUP BY id",
        ] {
            #expect(found(sql) == [], "\(sql)")
        }
    }

    @Test func syntaxErrorsSilenceTheirStatement() {
        #expect(found("SELECT nope, FROM orders") == ["syntax: FROM"])
        #expect(found("SELECT nope FROM orders; SELECT FROM") == ["unknownName: nope", "syntax: FROM"])
    }

    @Test func reservedWordsGetAQuoteFix() {
        #expect(fixed("SELECT * FROM order", "Quote “order” as a Name") == "SELECT * FROM `order`")
    }

    @Test func didYouMean() {
        #expect(fixed("SELECT totl FROM orders", "Change to “total”") == "SELECT total FROM orders")
        #expect(fixed("SELECT * FROM order_s", "Change to “orders”") == "SELECT * FROM orders")
        #expect(fixed("SELECT oo.id FROM orders o", "Change to “o”") == "SELECT o.id FROM orders o")
        #expect(fixed("SELECT zzzzz FROM orders", "Change to “total”") == nil)
    }

    @Test func offersToRefreshAndToAddTheColumn() throws {
        let problem = try #require(problems("SELECT nope FROM orders").first)
        #expect(problem.fixes.contains { $0.action == .refreshSchema })
        #expect(fixed("SELECT nope FROM orders", "Write ALTER TABLE to Add “nope”")
                == "ALTER TABLE shop.orders ADD COLUMN nope VARCHAR(255);\nSELECT nope FROM orders")
    }

    @Test func ambiguousColumnsCanBeQualified() {
        let sql = "SELECT id FROM orders o JOIN customers c ON c.id = o.id"
        #expect(found(sql) == ["ambiguousColumn: id"])
        #expect(fixed(sql, "Qualify as c.id") == "SELECT c.id FROM orders o JOIN customers c ON c.id = o.id")
    }

    @Test func insertCounts() {
        #expect(found("INSERT INTO orders (id, total) VALUES (1)") == ["insertCount: (1)"])
        #expect(found("INSERT INTO orders (id) VALUES (1), (2, 3)") == ["insertCount: (2, 3)"])
        #expect(found("INSERT INTO orders VALUES (1, 2)") == ["insertCount: (1, 2)"])
        #expect(found("INSERT INTO nosuch VALUES (1, 2)") == ["unknownName: nosuch"])
    }

    @Test func nullComparisons() {
        #expect(found("SELECT 1 FROM orders WHERE total = NULL") == ["nullComparison: ="])
        #expect(fixed("SELECT 1 FROM orders WHERE total = NULL", "Change to IS NULL") == "SELECT 1 FROM orders WHERE total IS NULL")
        #expect(fixed("SELECT 1 FROM orders WHERE total <> NULL", "Change to IS NOT NULL") == "SELECT 1 FROM orders WHERE total IS NOT NULL")
        #expect(found("SELECT 1 FROM orders WHERE total <=> NULL") == [])
        #expect(found("UPDATE orders SET total = NULL WHERE id = 1") == [])
    }

    @Test func writesWithoutLimits() {
        #expect(found("UPDATE orders SET total = 1") == ["noWhere: UPDATE"])
        #expect(found("DELETE FROM orders") == ["noWhere: DELETE"])
        #expect(found("EXPLAIN DELETE FROM orders") == [])
        #expect(found("UPDATE orders o JOIN customers c SET o.total = 1 WHERE o.id = 1") == ["joinWithoutOn: JOIN"])
        #expect(found("DELETE o FROM orders o JOIN customers c ON c.id = o.id WHERE o.id = 1") == [])
    }

    @Test func groupByColumns() {
        #expect(found("SELECT name, COUNT(*) FROM customers GROUP BY id") == ["groupBy: name"])
        #expect(found("SELECT customer_id, total FROM orders GROUP BY customer_id") == ["groupBy: total"])
        #expect(fixed("SELECT customer_id, total FROM orders GROUP BY customer_id", "Add “total” to GROUP BY")
                == "SELECT customer_id, total FROM orders GROUP BY customer_id, total")
        #expect(found("SELECT customer_id FROM orders GROUP BY customer_id HAVING total > 1") == ["groupBy: total"])
        #expect(found("SELECT customer_id FROM orders GROUP BY customer_id ORDER BY total") == ["groupBy: total"])
        #expect(found("SELECT customer_id, ANY_VALUE(total) FROM orders GROUP BY customer_id") == [])
    }

    @Test func aggregatesInTheWrongPlace() {
        #expect(found("SELECT 1 FROM orders WHERE SUM(total) > 1") == ["aggregateMisuse: SUM(total)"])
        #expect(found("SELECT SUM(COUNT(total)) FROM orders") == ["aggregateMisuse: COUNT(total)"])
        #expect(found("SELECT 1 FROM orders GROUP BY MAX(total)") == ["aggregateMisuse: MAX(total)"])
        #expect(found("SELECT customer_id FROM orders GROUP BY customer_id HAVING SUM(total) > 1") == [])
    }

    @Test func subqueriesAndAliases() {
        #expect(found("SELECT * FROM (SELECT 1)") == ["derivedAlias: (SELECT 1)"])
        #expect(fixed("SELECT * FROM (SELECT 1)", "Add an Alias") == "SELECT * FROM (SELECT 1) AS d")
        #expect(found("SELECT 1 FROM orders o JOIN customers o ON 1") == ["duplicateAlias: o"])
        #expect(found("SELECT 1 FROM orders JOIN orders ON 1") == ["duplicateAlias: orders"])
        #expect(found("SELECT 1 FROM orders JOIN customers USING (total)") == ["usingColumn: total"])
        #expect(found("WITH c AS (SELECT 1) SELECT 2") == ["unusedCTE: c"])
    }

    @Test func functions() {
        #expect(found("SELECT COUNT (*) FROM orders") == ["functionSpace: COUNT"])
        #expect(fixed("SELECT COUNT (*) FROM orders", "Remove the Space") == "SELECT COUNT(*) FROM orders")
        #expect(found("SELECT IF(1, 2) FROM orders") == ["functionArguments: IF"])
        #expect(found("SELECT LEFT('a') FROM orders") == ["functionArguments: LEFT"])
        #expect(problems("SELECT CONCAT_WS(',') FROM orders").first?.message == "CONCAT_WS takes at least 2 arguments, not 1")
    }

    @Test func insertValues() {
        #expect(found("INSERT INTO orders (total, customer_id) VALUES (1, NULL)") == ["nullIntoNotNull: NULL"])
        #expect(found("INSERT INTO orders (id, customer_id) VALUES (NULL, 1)") == [])
        #expect(found("INSERT INTO orders (customer_id, twice) VALUES (1, 2)") == ["generatedColumn: 2"])
    }

    @Test func tidying() {
        #expect(found("SELECT id FROM orders ORDER BY id ASC") == ["redundantCode: ASC"])
        #expect(fixed("SELECT id FROM orders ORDER BY id ASC", "Remove ASC") == "SELECT id FROM orders ORDER BY id")
        #expect(fixed("SELECT id AS id FROM orders", "Remove the Alias") == "SELECT id FROM orders")
        #expect(fixed("SELECT CASE WHEN id THEN 1 ELSE NULL END FROM orders", "Remove ELSE NULL") == "SELECT CASE WHEN id THEN 1 END FROM orders")
        #expect(found("SELECT 1 FROM orders WHERE 'a' = 'a'") == ["constantCondition: 'a' = 'a'"])
        #expect(found("SELECT 1 FROM orders WHERE 1 = 2") == ["constantCondition: 1 = 2"])
    }

    @Test func mysql8Words() {
        #expect(found("SELECT rank FROM (SELECT 1 AS `rank`) d") == ["reservedWord: rank"])
    }

    @Test func readOnlyMarksWrites() {
        #expect(found("DELETE FROM orders WHERE id = 1", readOnly: true) == ["readOnlyWrite: DELETE"])
        #expect(found("SELECT 1 FROM orders", readOnly: true) == [])
        #expect(found("DROP TABLE orders", readOnly: true) == ["readOnlyWrite: DROP"])
        #expect(found("SHOW TABLES", readOnly: true) == [])
    }

    @Test func aDisabledInspectionIsQuiet() {
        let analysis = SQLAnalysis("DELETE FROM orders", snapshot: Self.snapshot(), database: "shop")
        #expect(SQLInspections.problems(analysis, disabled: ["noWhere"]).isEmpty)
    }
}

@Suite struct IntentionTests {
    func analysis(_ sql: String) -> SQLAnalysis { SQLAnalysis(sql, snapshot: InspectionTests.snapshot(), database: "shop") }

    func apply(_ edits: [SQLEdit], to sql: String) -> String {
        let text = NSMutableString(string: sql)
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { text.replaceCharacters(in: NSRange(edit.range), with: edit.text) }
        return text as String
    }

    /// The text after the action `title` with the caret at the `|` in `marked`.
    func after(_ marked: String, _ title: String) -> String? {
        let caret = (marked as NSString).range(of: "|").location, sql = marked.replacingOccurrences(of: "|", with: "")
        guard let fix = SQLIntentions.actions(at: caret, in: analysis(sql)).first(where: { $0.title == title }), case .edit(let edits) = fix.action else { return nil }
        return apply(edits, to: sql)
    }

    @Test func quotesAndUnquotes() {
        #expect(after("SELECT i|d FROM orders", "Quote Name") == "SELECT `id` FROM orders")
        #expect(after("SELECT `i|d` FROM orders", "Remove Quotes") == "SELECT id FROM orders")
        #expect(after("SELECT `i|d` FROM orders", "Quote Name") == nil)
    }

    @Test func qualifiesAndUnqualifies() {
        #expect(after("SELECT tot|al FROM orders o", "Qualify with o") == "SELECT o.total FROM orders o")
        #expect(after("SELECT o.tot|al FROM orders o", "Remove Table Name") == "SELECT total FROM orders o")
        #expect(after("SELECT o.i|d FROM orders o JOIN customers c ON 1", "Remove Table Name") == nil)
        #expect(after("SELECT 1 FROM ord|ers", "Qualify with shop") == "SELECT 1 FROM shop.orders")
        #expect(after("SELECT 1 FROM shop.ord|ers", "Remove Database Name") == "SELECT 1 FROM orders")
    }

    @Test func introducesAnAlias() {
        #expect(after("SELECT orders.id FROM ord|ers WHERE orders.id = 1", "Add Table Alias “o”") == "SELECT o.id FROM orders o WHERE o.id = 1")
        #expect(after("SELECT 1 FROM cust|omers, orders c", "Add Table Alias “c2”") == "SELECT 1 FROM customers c2, orders c")
        #expect(after("SELECT 1 FROM ord|ers o", "Add Table Alias “o”") == nil)
    }

    @Test func expandsAStar() {
        #expect(after("SELECT *| FROM customers", "Expand * to Its Columns") == "SELECT id, name FROM customers")
        #expect(after("SELECT c.*| FROM customers c JOIN orders o ON 1", "Expand * to Its Columns") == "SELECT c.id, c.name FROM customers c JOIN orders o ON 1")
        #expect(after("SELECT *| FROM customers c, customers d", "Expand * to Its Columns") == "SELECT c.id, c.name, d.id, d.name FROM customers c, customers d")
        #expect(after("SELECT *| FROM nosuch", "Expand * to Its Columns") == nil)
    }

    @Test func movesASubqueryToWith() {
        #expect(after("SELECT * FROM (SELECT i|d FROM orders) d", "Move Subquery to WITH") == "WITH d AS (SELECT id FROM orders)\nSELECT * FROM d")
        #expect(after("SELECT (SELECT MAX(i|d) FROM orders) FROM customers", "Move Subquery to WITH")
                == "WITH extracted AS (SELECT MAX(id) FROM orders)\nSELECT (SELECT * FROM extracted) FROM customers")
        #expect(after("WITH a AS (SELECT 1) SELECT * FROM a, (SELECT 2| AS b) d", "Move Subquery to WITH") == "WITH a AS (SELECT 1), d AS (SELECT 2 AS b) SELECT * FROM a, d")
        #expect(after("SELECT * FROM orders o WHERE EXISTS (SELECT 1| FROM customers c WHERE c.id = o.id)", "Move Subquery to WITH") == nil)
    }

    @Test func splitsAndMergesInserts() {
        #expect(after("INSERT INTO t (a) VALUES (1|), (2)", "Split into One INSERT per Row") == "INSERT INTO t (a) VALUES (1);\nINSERT INTO t (a) VALUES (2)")
        #expect(after("INSERT INTO t (a) VALUES (1|); INSERT INTO t (a) VALUES (2), (3); SELECT 1", "Merge with the Next INSERT") == "INSERT INTO t (a) VALUES (1), (2), (3); SELECT 1")
        #expect(after("INSERT INTO t (a) VALUES (1|); INSERT INTO u (a) VALUES (2)", "Merge with the Next INSERT") == nil)
    }

    @Test func dropsAnInsertColumn() {
        #expect(after("INSERT INTO t (a, b|, c) VALUES (1, 2, 3), (4, 5, 6)", "Remove Column “b” and Its Values") == "INSERT INTO t (a, c) VALUES (1, 3), (4, 6)")
        #expect(after("INSERT INTO t (a, b|) VALUES (1, 2)", "Remove Column “b” and Its Values") == "INSERT INTO t (a) VALUES (1)")
    }

    @Test func previewsWhatAWriteWouldTouch() {
        func preview(_ sql: String) -> String? { let found = analysis(sql); return SQLIntentions.preview(of: found.statements[0], in: found) }
        #expect(preview("DELETE FROM orders WHERE id = 1") == "SELECT orders.* FROM orders WHERE id = 1 LIMIT 1000")
        #expect(preview("UPDATE orders o JOIN customers c ON c.id = o.id SET o.total = 1") == "SELECT 1 AS `new total`, o.*, c.* FROM orders o JOIN customers c ON c.id = o.id LIMIT 1000")
        #expect(preview("DELETE o FROM orders o JOIN customers c ON c.id = o.id WHERE c.id = 2 ") == "SELECT o.* FROM orders o JOIN customers c ON c.id = o.id WHERE c.id = 2 LIMIT 1000")
        #expect(preview("DELETE FROM orders ORDER BY id DESC LIMIT 5") == "SELECT orders.* FROM orders ORDER BY id DESC LIMIT 5")
        #expect(preview("UPDATE orders SET total = total + 1, customer_id = 2 WHERE id = 1")
                == "SELECT total + 1 AS `new total`, 2 AS `new customer_id`, orders.* FROM orders WHERE id = 1 LIMIT 1000")
        #expect(preview("WITH c AS (SELECT 1 AS id) DELETE FROM orders WHERE id IN (SELECT id FROM c)")
                == "WITH c AS (SELECT 1 AS id) SELECT orders.* FROM orders WHERE id IN (SELECT id FROM c) LIMIT 1000")
        #expect(preview("SELECT 1") == nil && preview("DELETE FROM") == nil)
        let previewSQL = preview("UPDATE orders SET total = 1") ?? ""
        #expect(ReadOnlyClassifier.classify(previewSQL, noBackslashEscapes: false) == .readOnly)
    }

    @Test func renames() throws {
        func renamed(_ marked: String, to name: String) throws -> String {
            let caret = (marked as NSString).range(of: "|").location, sql = marked.replacingOccurrences(of: "|", with: "")
            let found = analysis(sql), symbol = try #require(found.reference(at: caret)?.symbol)
            return apply(try SQLIntentions.rename(symbol, to: name, at: caret, in: found).get(), to: sql)
        }
        #expect(try renamed("SELECT o.id FROM orders o| WHERE o.total > 1", to: "ord") == "SELECT ord.id FROM orders ord WHERE ord.total > 1")
        #expect(try renamed("WITH c| AS (SELECT 1 AS x) SELECT c.x FROM c", to: "d e") == "WITH `d e` AS (SELECT 1 AS x) SELECT `d e`.x FROM `d e`")
        #expect(try renamed("SELECT id AS n|, 1 FROM orders ORDER BY n", to: "m") == "SELECT id AS m, 1 FROM orders ORDER BY m")
        #expect(try renamed("SELECT * FROM orders|; DELETE FROM orders", to: "sales") == "RENAME TABLE shop.orders TO shop.sales;\nSELECT * FROM sales; DELETE FROM sales")
        #expect(try renamed("SELECT total| FROM orders", to: "sum") == "ALTER TABLE shop.orders RENAME COLUMN total TO sum;\nSELECT sum FROM orders")
    }

    @Test func aRenameThatClashesIsRefused() throws {
        let sql = "SELECT 1 FROM orders o, customers c", found = analysis(sql)
        let caret = 21, symbol = try #require(found.reference(at: caret)?.symbol)
        #expect(SQLIntentions.rename(symbol, to: "c", at: caret, in: found) == .failure(SQLRenameError(message: "“c” is already a table in this query")))
        #expect(SQLIntentions.rename(symbol, to: " ", at: caret, in: found) == .failure(SQLRenameError(message: "Type a name")))
    }

    @Test func renamesVariables() throws {
        let sql = "SET @total = 1; SELECT @Total + @other"
        let edits = try #require(SQLIntentions.renameVariable(at: 6, to: "sum", in: analysis(sql)))
        #expect(apply(edits, to: sql) == "SET @sum = 1; SELECT @sum + @other")
    }

    @Test func documentsTablesColumnsAndFunctions() throws {
        func doc(_ marked: String) -> (title: String, body: String)? {
            let caret = (marked as NSString).range(of: "|").location
            return SQLIntentions.documentation(at: caret, in: analysis(marked.replacingOccurrences(of: "|", with: "")))
        }
        let table = try #require(doc("SELECT 1 FROM ord|ers"))
        #expect(table.title == "orders" && table.body.contains("customer_id") && table.body.contains("PK"))
        let column = try #require(doc("SELECT i|d FROM orders"))
        #expect(column.title == "id" && column.body.contains("NOT NULL") && column.body.contains("In orders"))
        #expect(doc("SELECT CONC|AT('a') FROM orders")?.body.hasPrefix("CONCAT(text, …)") == true)
        #expect(doc("SELECT 1 FROM orders o|")?.body.hasPrefix("Alias of orders") == true)
        #expect(doc("WITH c| AS (SELECT 1 AS x) SELECT * FROM c")?.body.contains("x") == true)
        #expect(doc("SELECT 1| FROM orders") == nil)
    }

    @Test func parameterInfoFollowsTheCaret() throws {
        func info(_ marked: String) -> (String, [String], Int)? {
            let caret = (marked as NSString).range(of: "|").location
            return SQLIntentions.parameters(at: caret, in: analysis(marked.replacingOccurrences(of: "|", with: ""))).map { ($0.title, $0.items, $0.active) }
        }
        let call = try #require(info("SELECT IF(a, b|, c)"))
        #expect(call.0 == "IF" && call.1 == ["condition", "then", "else"] && call.2 == 1)
        #expect(info("SELECT IF(a, LEFT(|x, 1), c)")?.0 == "LEFT")
        let value = try #require(info("INSERT INTO orders (id, total) VALUES (1, |2)"))
        #expect(value.1 == ["id", "total"] && value.2 == 1)
        #expect(info("INSERT INTO orders VALUES (1, |2)")?.1.first == "id")
        #expect(info("SELECT 1|") == nil)
    }

    @Test func hintsNameValuesStarsAndJoins() {
        #expect(SQLIntentions.hints(in: analysis("INSERT INTO orders (id, total) VALUES (1, 2)")).map(\.text) == ["id:", "total:"])
        #expect(SQLIntentions.hints(in: analysis("SELECT * FROM customers")).map(\.text) == ["id, name"])
        #expect(SQLIntentions.hints(in: analysis("SELECT * FROM orders")).first?.text == "id, total, customer_id, twice")
        #expect(SQLIntentions.hints(in: analysis("SELECT 1 FROM nosuch")).isEmpty)
        var snapshot = InspectionTests.snapshot()
        let index = snapshot.databases[0].tables.firstIndex { $0.name == "orders" }!
        snapshot.databases[0].tables[index].foreignKeys = [SchemaForeignKey(name: "fk", columns: ["customer_id"], referencedDatabase: "shop", referencedTable: "customers",
                                                                            referencedColumns: ["id"], onUpdate: "", onDelete: "")]
        func joins(_ sql: String) -> [String] { SQLIntentions.hints(in: SQLAnalysis(sql, snapshot: snapshot, database: "shop")).map(\.text).filter { $0.contains(":") } }
        #expect(joins("SELECT 1 FROM customers c JOIN orders o ON o.customer_id = c.id") == ["1:n"])
        #expect(joins("SELECT 1 FROM orders o JOIN customers c ON o.customer_id = c.id") == ["n:1"])
        #expect(joins("SELECT 1 FROM orders o JOIN customers c ON o.id = c.id").isEmpty)
    }

    @Test func offersRenameOnNames() {
        let titles = SQLIntentions.actions(at: 7, in: analysis("SELECT id FROM orders")).map(\.title)
        #expect(titles.contains("Rename…"))
        let preview = SQLIntentions.actions(at: 2, in: analysis("DELETE FROM orders WHERE id = 1")).map(\.title)
        #expect(preview.contains("Preview the Rows This Would Touch"))
    }
}
