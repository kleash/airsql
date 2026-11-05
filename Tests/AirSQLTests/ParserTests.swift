import AirSQLCore
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
        #expect(select.clauses.map { "\($0.clause)" } == ["selectList", "from", "on", "from", "whereClause", "orderBy"])
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
