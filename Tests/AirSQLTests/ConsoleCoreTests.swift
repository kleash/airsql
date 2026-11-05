import CMariaDB
import Foundation
import Testing
@testable import AirSQLCore

// The console's text tools (plan §2.6, §2.10): what a run sends, where errors point, result tabs' names, the safety
// prompts' checks and the formatter.
struct ConsoleScriptTests {
    let script = "-- Top customers\nSELECT 1;\n\n/* Refunds\n   per product */\nSELECT 2;  -- after two\nSELECT 3"

    @Test func runsTheStatementAtTheCaretAllOrTheSelection() {
        let caret = ConsoleScript.statements(in: script, selection: nil, caret: 20, all: false, noBackslashEscapes: false)
        #expect(caret.map(\.sql) == ["SELECT 1"])
        let all = ConsoleScript.statements(in: script, selection: nil, caret: 0, all: true, noBackslashEscapes: false)
        #expect(all.map(\.sql) == ["SELECT 1", "SELECT 2", "SELECT 3"])
        // The selection's statements, with offsets in the whole text.
        let start = (script as NSString).range(of: "SELECT 2").location
        let selected = ConsoleScript.statements(in: script, selection: start..<(start + 8), caret: 0, all: false,
                                                noBackslashEscapes: false)
        #expect(selected.map(\.sql) == ["SELECT 2"] && selected.first?.range == start..<(start + 8))
    }

    @Test func linesAndErrorLines() {
        #expect(ConsoleScript.line(of: 0, in: script) == 1)
        #expect(ConsoleScript.line(of: 17, in: script) == 2)
        let statements = SQLSplitter.statements(in: script)
        let message = "You have an error in your SQL syntax; check the manual near 'FORM t' at line 1"
        #expect(ConsoleScript.errorLine(message, statement: statements[1], in: script) == 6)
        #expect(ConsoleScript.errorLine("Table 'x' doesn't exist", statement: statements[1], in: script) == nil)
    }

    @Test func errorsPointAtTheirToken() {
        let text = "SELECT 1;\nSELECT `é`, a\nFORM t WHERE x = 'FORM';"
        let statement = SQLSplitter.statements(in: text)[1]
        func marked(_ message: String) -> String? {
            ConsoleScript.problem(message, shown: "shown", statement: statement, noBackslashEscapes: false).map {
                String(decoding: Array(text.utf16)[$0.range], as: UTF16.self)
            }
        }
        #expect(marked("Error 1064 (42000): You have an error … to use near 'FORM t WHERE x = 'FORM'' at line 2") == "FORM")
        #expect(marked("… near 't WHERE x = 'FORM'' at line 2") == "t")  // a quote inside the near text
        #expect(marked("… near 'WHERE' at line 9") == "WHERE")  // the line is only where to start looking
        #expect(marked("… near '' at line 2") == "'FORM'")  // the statement's end
        #expect(marked("… near 'nothing like it' at line 1") == nil)
        #expect(marked("Error 1054 (42S22): Unknown column 'q.A' in 'field list'") == "a")
        #expect(marked("Error 1146 (42S02): Table 'db.é' doesn't exist") == "`é`")
        #expect(marked("Error 1062 (23000): Duplicate entry '1' for key 'a'") == nil)
        #expect(ConsoleScript.problem("… near 'FORM' at line 1", shown: "", statement: SQLStatement(sql: "FORM"), noBackslashEscapes: false) == nil)
    }

    @Test func whatTheTextLeavesOpen() {
        func problems(_ text: String, noBackslashEscapes: Bool = false) -> [String] {
            ConsoleScript.unclosed(in: text, noBackslashEscapes: noBackslashEscapes).map {
                "\($0.range.lowerBound): \($0.message)"
            }
        }
        #expect(problems("SELECT ('a', `b`, [1], {d '2020-01-01'}) /* c */; -- it's (\nSELECT ')' # (").isEmpty)
        #expect(problems("SELECT 'a") == ["7: This text has no closing quote"])
        #expect(problems("SELECT `a") == ["7: This name has no closing `"])
        #expect(problems("SELECT 1 /* a") == ["9: This comment has no closing */"])
        #expect(problems("SELECT 1 /*! a") == ["9: This comment has no closing */"])
        #expect(problems("SELECT 'a\\'") == ["7: This text has no closing quote"])
        #expect(problems("SELECT 'a\\'", noBackslashEscapes: true).isEmpty)
        #expect(problems("SELECT (1, (2)") == ["7: This ( has no closing )"])
        #expect(problems("SELECT 1)") == ["8: This ) has no opening ("])
        #expect(problems("SELECT (1]") == ["9: This ] has no opening [", "7: This ( has no closing )"])
        // A bracket left open ends with its statement; a routine's own delimiter keeps its ; inside.
        #expect(problems("SELECT (1;\nSELECT 2)") == ["7: This ( has no closing )", "19: This ) has no opening ("])
        #expect(problems("DELIMITER $$\nCREATE PROCEDURE p() BEGIN SELECT (1); END$$\nDELIMITER ;\nSELECT 2").isEmpty)
        #expect(ConsoleScript.unclosed(in: String(repeating: "(;", count: 500), noBackslashEscapes: false).count == ConsoleScript.unclosedLimit)
    }

    @Test func resultTabsAreNamedFromTheCommentAbove() {
        let statements = SQLSplitter.statements(in: script)
        func title(_ index: Int) -> String? {
            ConsoleScript.title(of: statements[index], in: script, after: index == 0 ? 0 : statements[index - 1].end,
                                noBackslashEscapes: false)
        }
        #expect(title(0) == "Top customers")
        #expect(title(1) == "Refunds")
        #expect(title(2) == nil)  // "-- after two" ends the line of the statement before
        let long = "-- " + String(repeating: "word ", count: 30) + "\nSELECT 1"
        let named = ConsoleScript.title(of: SQLSplitter.statements(in: long)[0], in: long, after: 0, noBackslashEscapes: false)
        #expect(named?.count == 60 && named?.hasSuffix("…") == true)
    }
}

struct StatementCheckTests {
    @Test func whatWrites() {
        for sql in ["SELECT 1", "SHOW TABLES", "USE shop", "SET @x = 1", "SET NAMES utf8mb4", "COMMIT", "ROLLBACK",
                    "START TRANSACTION", "BEGIN", "SET SESSION sql_mode = ''"] {
            #expect(!StatementCheck.writes(sql, noBackslashEscapes: false), "\(sql)")
        }
        for sql in ["INSERT INTO t VALUES (1)", "UPDATE t SET a = 1 WHERE id = 2", "CALL p()", "SET GLOBAL max_connections = 10",
                    "SET @@global.x = 1", "SET PASSWORD = 'x'", "DROP TABLE t", "CREATE TABLE t (a INT)", "SELECT my_udf()"] {
            #expect(StatementCheck.writes(sql, noBackslashEscapes: false), "\(sql)")
        }
    }

    @Test func aLimitedWriteIsNotEveryRowAndCharsetChangesAreSpotted() {
        func risk(_ sql: String) -> StatementCheck.Risk? { StatementCheck.risk(sql, noBackslashEscapes: false) }
        #expect(risk("DELETE FROM t LIMIT 5")?.limited == true && risk("DELETE FROM t")?.limited == false)
        #expect(StatementCheck.changesCharset("SET NAMES latin1", noBackslashEscapes: false))
        #expect(StatementCheck.changesCharset("set character set cp1251", noBackslashEscapes: false))
        #expect(!StatementCheck.changesCharset("SET NAMES utf8mb4", noBackslashEscapes: false))
        #expect(!StatementCheck.changesCharset("SET @a = 'SET NAMES latin1'", noBackslashEscapes: false))
    }

    @Test func completionKnowsTheServerAndQuotesMySQL8Words() {
        #expect(SQLCompletion.quote("rank") == "`rank`" && SQLCompletion.quote("name") == "name")
        let mysql57 = SchemaServer(version: "5.7.44"), mysql84 = SchemaServer(version: "8.4.13"), mariadb = SchemaServer(version: "10.5.29-MariaDB")
        for name in ["REGEXP_REPLACE", "REGEXP_SUBSTR", "JSON_VALUE"] {
            let function = SQLFunction.all.first { $0.name == name }
            #expect(function?.available(on: mysql57) == false && function?.available(on: mysql84) == true
                    && function?.available(on: mariadb) == true, "\(name)")
        }
    }

    @Test func unboundedWritesDropsAndTruncates() {
        func risk(_ sql: String) -> StatementCheck.Risk? { StatementCheck.risk(sql, noBackslashEscapes: false) }
        #expect(risk("UPDATE t SET a = 1")?.kind == .unboundedWrite)
        #expect(risk("UPDATE LOW_PRIORITY shop.t SET a = 1")?.object == "shop.t")
        #expect(risk("UPDATE t SET a = (SELECT b FROM u WHERE c = 1)")?.kind == .unboundedWrite)
        #expect(risk("UPDATE t SET a = 1 WHERE id = 1") == nil)
        #expect(risk("DELETE FROM shop.orders")?.object == "shop.orders")
        #expect(risk("/* tidy */ DELETE FROM `my orders`")?.object == "`my orders`")
        #expect(risk("DELETE FROM t WHERE x = 1") == nil)
        #expect(risk("WITH c AS (SELECT 1) DELETE FROM t")?.kind == .unboundedWrite)
        #expect(risk("DROP TABLE IF EXISTS a, shop.b") == StatementCheck.Risk(kind: .drop, verb: "DROP", objectType: "table",
                                                                                object: "a, shop.b"))
        #expect(risk("drop database `my db`")?.objectType == "database")
        #expect(risk("/*!40101 DROP VIEW v */")?.objectType == "view")
        #expect(risk("TRUNCATE TABLE t")?.kind == .truncate && risk("TRUNCATE t")?.object == "t")
        #expect(risk("SELECT * FROM t") == nil && risk("INSERT INTO t SELECT * FROM u") == nil)
    }

    /// A destructive statement hidden behind a version-gated comment the server skips still asks (plan §2.10): the
    /// lexer reads the skipped comment as a comment, so the DROP/TRUNCATE after its */ is a real statement.
    @Test func riskSeesStatementsHiddenBehindAVersionGatedComment() {
        func risk(_ sql: String) -> StatementCheck.Risk? { StatementCheck.risk(sql, noBackslashEscapes: false) }
        #expect(risk("/*!99999 ' */ DROP TABLE shop.t -- ' */")
            == StatementCheck.Risk(kind: .drop, verb: "DROP", objectType: "table", object: "shop.t"))
        #expect(risk("/*M!999999 ' */ TRUNCATE shop.t -- ' */")?.kind == .truncate)
        #expect(risk("/*!99999 ' */ UPDATE shop.t SET a = 1 -- ' */")?.kind == .unboundedWrite)
        #expect(StatementCheck.writes("/*!99999 ' */ DROP TABLE shop.t -- ' */", noBackslashEscapes: false))
    }

    /// A read-only connection runs what the read-only check proves only reads, and a bare USE; nothing that could lift
    /// the session's READ ONLY.
    @Test func readOnlyConnectionsRunOnlyWhatOnlyReads() {
        func refusal(_ sql: String) -> String? { StatementCheck.readOnlyRefusal(sql, on: "Prod", noBackslashEscapes: false) }
        for sql in ["SELECT 1", "SHOW DATABASES", "EXPLAIN SELECT * FROM t", "DESCRIBE t", "USE shop", "USE `my db`"] {
            #expect(refusal(sql) == nil, "\(sql)")
        }
        for sql in ["SET SESSION TRANSACTION READ WRITE", "START TRANSACTION READ WRITE", "SET transaction_read_only = 0",
                    "CREATE DATABASE x", "INSERT INTO t VALUES (1)", "CALL p()", "SELECT SLEEP(1)", "EXPLAIN UPDATE t SET a = 1",
                    "USE shop /*! , x */", "/*!99999 DROP TABLE t */ USE shop"] {
            #expect(refusal(sql)?.hasPrefix("“Prod” is read-only, so nothing ran. ") == true, "\(sql)")
        }
        #expect(refusal("SET SESSION TRANSACTION READ WRITE") == "“Prod” is read-only, so nothing ran. SET isn't a read-only "
            + "statement; only SELECT, WITH … SELECT, SHOW, DESCRIBE and EXPLAIN are. To change anything, turn off Read-only "
            + "in its connection settings.")
    }
}

struct SQLFormatterTests {
    func format(_ sql: String) -> String? { SQLFormatter.format(sql) }

    @Test func clausesOnTheirOwnLinesAndReservedWordsInUpperCase() {
        #expect(format("select a, b from t where x = 1 order by a") == "SELECT a, b\nFROM t\nWHERE x = 1\nORDER BY a")
        #expect(format("select * from a left join b on a.id = b.id join c on 1  group by a.x")
                == "SELECT *\nFROM a\nLEFT JOIN b ON a.id = b.id\nJOIN c ON 1\nGROUP BY a.x")
        #expect(format("insert into t (a) values (1) on duplicate key update a = values(a)")
                == "INSERT INTO t (a)\nVALUES (1)\nON DUPLICATE KEY UPDATE a = VALUES(a)")
        #expect(format("delete from t where a = 1") == "DELETE FROM t\nWHERE a = 1")
        #expect(format("select a from t limit 1 offset 2") == "SELECT a\nFROM t\nLIMIT 1 OFFSET 2")
    }

    @Test func subqueriesIndentAndConditionsTakeLines() {
        #expect(format("update t set a = 1 where id in (select id from u where x)") == """
            UPDATE t
            SET a = 1
            WHERE id IN (
                SELECT id
                FROM u
                WHERE x
            )
            """)
        #expect(format("select * from (select a from (select 1 a) b) c where x=1 and y between 1 and 2 or z") == """
            SELECT *
            FROM (
                SELECT a
                FROM (
                    SELECT 1 a
                ) b
            ) c
            WHERE x = 1
              AND y BETWEEN 1 AND 2
               OR z
            """)
        #expect(format("select 1 from a join b on a.x=b.x and a.y=b.y") == "SELECT 1\nFROM a\nJOIN b ON a.x = b.x\n    AND a.y = b.y")
        #expect(format("with a as (select 1), b as (select 2) select * from a") == "WITH a AS (\n    SELECT 1\n),\nb AS (\n    SELECT 2\n)\nSELECT *\nFROM a")
    }

    @Test func casesRowsAndTables() {
        #expect(format("select case when a then 1 else 2 end x from t") == "SELECT CASE\n           WHEN a THEN 1\n           ELSE 2\n       END x\nFROM t")
        #expect(format("insert into t values (1,'a'),(2,'b')") == "INSERT INTO t\nVALUES (1, 'a'),\n       (2, 'b')")
        #expect(format("create table t (id int primary key, long_name varchar(10) not null, text text, key k (id)) engine=InnoDB default character set utf8mb4") == """
            CREATE TABLE t (
                id        INT PRIMARY KEY,
                long_name VARCHAR(10) NOT NULL,
                text      TEXT,
                KEY k (id)
            ) ENGINE = InnoDB DEFAULT CHARACTER SET utf8mb4
            """)
    }

    @Test func routineBodiesIndentByBlock() {
        let script = "DELIMITER ;;\ncreate procedure p() begin declare i int; if i then select 1 from t; else while i do set i = 0; end while; end if; repeat set i = 1; until i end repeat; end;;\nDELIMITER ;\nselect 2 from dual;"
        #expect(format(script) == """
            DELIMITER ;;
            CREATE PROCEDURE p()
            BEGIN
                DECLARE i INT;
                IF i THEN
                    SELECT 1
                    FROM t;
                ELSE
                    WHILE i DO
                        SET i = 0;
                    END WHILE;
                END IF;
                REPEAT
                    SET i = 1;
                UNTIL i
                END REPEAT;
            END;;
            DELIMITER ;
            SELECT 2
            FROM DUAL;
            """)
    }

    @Test func namesLiteralsAndCommentsStayAsTheyAre() {
        #expect(format("select t.order, `from` from t") == "SELECT t.order, `from`\nFROM t")
        #expect(format("select 'from  x'  -- keep  this\nfrom t") == "SELECT 'from  x' -- keep  this\nFROM t")
        #expect(format("select a,\n  -- the b column\n  b from t") == "SELECT a,\n       -- the b column\n       b\nFROM t")
        #expect(format("/*!40101 set   names utf8 */;") == "/*!40101 set   names utf8 */;")
        #expect(format("select count(*)  from t") == "SELECT count(*)\nFROM t")  // COUNT isn't reserved
        #expect(format("select count (*) from t") == "SELECT count(*)\nFROM t")
        #expect(format("alter table t add a int, add b int") == "ALTER TABLE t ADD a INT,\n    ADD b INT")
        #expect(format("select 1 - -1, a*b, -c, t.*, @x:=1 from t") == "SELECT 1 - -1, a * b, -c, t.*, @x := 1\nFROM t")
        #expect(format("-- @formatter:off\nselect  1;\n-- @formatter:on\nselect  2;") == "-- @formatter:off\nselect  1;\n-- @formatter:on\nSELECT 2;")
    }

    @Test func rulesOfTheStyle() {
        func format(_ sql: String, _ change: (inout SQLFormatStyle) -> Void) -> String? {
            var style = SQLFormatStyle()
            change(&style)
            return SQLFormatter.format(sql, style: style)
        }
        #expect(format("SELECT a, b FROM t WHERE x = 1") { $0.keywords = .lower } == "select a, b\nfrom t\nwhere x = 1")
        #expect(format("select count(*), cast(a as char), b from t") { $0.functions = .upper } == "SELECT COUNT(*), CAST(a AS CHAR), b\nFROM t")
        #expect(format("select a, b from t") { $0.lists = .always } == "SELECT a,\n       b\nFROM t")
        #expect(format("select a, b from t") { $0.lists = .always; $0.commaFirst = true } == "SELECT a\n     , b\nFROM t")
        let long = "select " + (1...30).map { "column\($0)" }.joined(separator: ", ") + " from t"
        #expect(format(long) { _ in }?.contains("column1,\n       column2") == true)
        #expect(format("select a from t where x and y") { $0.conditionsOnLines = false } == "SELECT a\nFROM t\nWHERE x AND y")
        #expect(format("select a from t where x and y") { $0.operatorFirst = false } == "SELECT a\nFROM t\nWHERE x AND\n      y")
        #expect(format("select 1 from a join b on x") { $0.joinOnOwnLine = true } == "SELECT 1\nFROM a\nJOIN b\n    ON x")
        #expect(format("select 1 from a join b on x") { $0.joinsIndented = true } == "SELECT 1\nFROM a\n    JOIN b ON x")
        #expect(format("select * from (select 1) a") { $0.brackets = .ownLine } == "SELECT *\nFROM\n(\n    SELECT 1\n) a")
        #expect(format("select * from (select 1) a") { $0.brackets = .indented } == "SELECT *\nFROM\n    (\n        SELECT 1\n    ) a")
        #expect(format("select f(a,b) x from t") { $0.spaceAfterComma = false; $0.spaceInsideBrackets = true } == "SELECT f( a,b ) x\nFROM t")
        #expect(format("select a=1 from t") { $0.spaceAroundOperators = false } == "SELECT a=1\nFROM t")
        #expect(format("select case when a then 1 end") { $0.caseOnLines = false } == "SELECT CASE WHEN a THEN 1 END")
        #expect(format("select a from t where x and y group by a") { $0.river = true } == "SELECT a\n  FROM t\n WHERE x\n   AND y\n GROUP BY a")
        #expect(format("insert into t values (1),(2)") { $0.rowsOnLines = false } == "INSERT INTO t\nVALUES (1), (2)")
        #expect(format("create table t (a int, bb int)") { $0.alignColumns = false } == "CREATE TABLE t (\n    a INT,\n    bb INT\n)")
        // Names follow their rule everywhere they're used.
        #expect(format("select o.Total as Amount from Orders o order by Amount") { $0.aliases = .lower } == "SELECT o.Total AS amount\nFROM Orders o\nORDER BY amount")
        #expect(format("select Total from Orders") { $0.identifiers = .lower } == "SELECT total\nFROM orders")
    }

    @Test func aStyleSavedByAnOlderVersionKeepsItsDefaults() throws {
        let style = try JSONDecoder().decode(SQLFormatStyle.self, from: Data(#"{"indent": 2}"#.utf8))
        #expect(style.indent == 2 && style.keywords == .upper)
        #expect(SQLFormatStyle.presets.first?.style == SQLFormatStyle() && SQLFormatStyle.presets.count >= 6)
    }

    @Test(arguments: AttackCorpus.all + ReadCorpus.all)
    func neverChangesWhatTheServerReads(_ sql: String) {
        let formatted = SQLFormatter.format(sql)
        #expect(formatted != nil, "\(sql)")
        if let formatted { #expect(SQLLexer.sameTokens(sql, formatted)) }
        // Formatting what's formatted changes nothing.
        if let formatted { #expect(SQLFormatter.format(formatted) == formatted, "\(sql)") }
        // Every preset holds to it too.
        for preset in SQLFormatStyle.presets { #expect(SQLFormatter.format(sql, style: preset.style) != nil, "\(preset.name): \(sql)") }
    }
}

/// Completion from the schema cache (the MariaDB 11.8 recording of the fixture schema): tables after FROM, columns
/// through aliases, joins from foreign keys, databases after USE, functions of the server's flavour, keywords.
struct SQLCompletionTests {
    func suggest(_ text: String, database: String? = "airsql_fixture") async throws -> [CompletionItem] {
        let (cache, _) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
        let caret = (text as NSString).range(of: "|").location
        let clean = text.replacingOccurrences(of: "|", with: "")
        return SQLCompletion.suggestions(text: clean, caret: caret, snapshot: cache.snapshot, database: database).items
    }

    @Test func tablesAfterFromAndJoin() async throws {
        let items = try await suggest("SELECT * FROM cu|")
        #expect(items.map(\.label) == ["customers", "customer_emails"])
        #expect(items.last?.kind == .view)
        let qualified = try await suggest("SELECT * FROM airsql_fixture.or|")
        #expect(Set(qualified.map(\.label)) == ["orders", "order_lines", "order_seq"])
        #expect(try await suggest("USE airsql|").map(\.label) == ["airsql other", "airsql_fixture"])
        #expect(try await suggest("USE airsql|").first?.text == "`airsql other`")
    }

    @Test func columnsThroughAliasesAndJoinsFromForeignKeys() async throws {
        let columns = try await suggest("SELECT o.| FROM orders AS o")
        #expect(columns.first?.label == "id" && columns.contains { $0.label == "customer_id" } && columns.allSatisfy { $0.kind == .column })
        let unqualified = try await suggest("SELECT cust| FROM orders o JOIN customers c ON c.id = o.customer_id")
        #expect(unqualified.first?.label == "customer_id" && unqualified.first?.detail.hasSuffix("· o") == true)
        let joins = try await suggest("SELECT * FROM orders o JOIN |")
        #expect(joins.first?.kind == .join)
        #expect(joins.first?.text == "customers c ON c.id = o.customer_id", "\(joins.first?.text ?? "")")
        let back = try await suggest("SELECT * FROM customers c JOIN |")
        #expect(back.contains { $0.text == "orders o ON o.customer_id = c.id" }, "\(back.prefix(3).map(\.text))")
    }

    @Test func functionsOfTheServerAndKeywords() async throws {
        let items = try await suggest("SELECT CONC|")
        #expect(items.map(\.label).prefix(2) == ["CONCAT", "CONCAT_WS"] && items.first?.text == "CONCAT(")
        #expect(try await suggest("SELECT JSON_D|").map(\.label) == ["JSON_DETAILED"], "MariaDB's")
        #expect(try await suggest("SELECT REGEXP_L|").isEmpty, "MySQL's only")
        #expect(try await suggest("SELECT 1 FR|").map(\.label) == ["FROM", "FROM_UNIXTIME"])
        // A name that needs quoting is offered quoted.
        #expect(try await suggest("SELECT * FROM we|").first?.text == "`we``ird 'name' ✓`")
    }

    func suggest(_ text: String, options: CompletionOptions) async throws -> [CompletionItem] {
        let (cache, _) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
        let caret = (text as NSString).range(of: "|").location
        return SQLCompletion.suggestions(text: text.replacingOccurrences(of: "|", with: ""), caret: caret, snapshot: cache.snapshot,
                                         database: "airsql_fixture", options: options).items
    }

    @Test func matchesByAbbreviationAndTheMiddleOfAWord() async throws {
        #expect(SQLCompletion.match("film_category", "fica") == 2)
        #expect(SQLCompletion.match("ORDER BY", "ob") == 2)
        #expect(SQLCompletion.match("filmCategory", "fc") == 2)
        #expect(SQLCompletion.match("old_customers", "cust") == 1)
        #expect(SQLCompletion.match("old_customers", "stom") == 3)
        #expect(SQLCompletion.match("customers", "cu") == 0)
        #expect(SQLCompletion.match("customers", "xy") == nil)
        #expect(try await suggest("SELECT * FROM orl|").first?.label == "order_lines")
        #expect(try await suggest("SELECT * FROM mail|").first?.label == "customer_emails")
        #expect(try await suggest("SELECT * FROM orders ob|").first?.label == "ORDER BY")
        // What was chosen before goes first among equals.
        var options = CompletionOptions()
        options.recent = ["customer_emails": 3]
        #expect(try await suggest("SELECT * FROM cu|", options: options).first?.label == "customer_emails")
    }

    @Test func offersWhatTheGrammarAllowsHere() async throws {
        #expect(try await suggest("SELECT * FROM orders ORDER |").map(\.label) == ["BY"])
        #expect(try await suggest("SELECT * FROM orders o LEFT |").map(\.label) == ["JOIN", "OUTER JOIN"])
        #expect(try await suggest("SELECT * FROM orders o WH|").map(\.label) == ["WHERE"])
        let start = try await suggest("IN|").map(\.label)
        #expect(start.contains("INSERT INTO") && !start.contains("INNER JOIN"))
        let tail = try await suggest("SELECT * FROM orders ORDER BY id L|").map(\.label)
        #expect(tail.contains("LIMIT") && !tail.contains("LEFT JOIN"))
        #expect(try await suggest("CREATE TABLE x (a int) ENGINE=Inn|").map(\.text) == ["InnoDB"])
        #expect(try await suggest("CALL add|").map(\.text) == ["add_customer("])
        var lower = CompletionOptions()
        lower.keywordCase = .lower
        lower.functionCase = .lower
        #expect(try await suggest("SELECT * FROM orders GR|", options: lower).first?.text == "group by")
        #expect(try await suggest("SELECT CONC|", options: lower).first?.text == "concat(")
    }

    @Test func columnsOfCTEsDerivedTablesAndOutputs() async throws {
        #expect(try await suggest("WITH c AS (SELECT id, status s FROM customers) SELECT c.| FROM c").map(\.label) == ["id", "s", "all columns"])
        #expect(try await suggest("SELECT d.| FROM (SELECT id a FROM orders) d").map(\.label) == ["a"])
        #expect(try await suggest("WITH recent AS (SELECT 1) SELECT * FROM rec|").first?.detail == "CTE")
        #expect(try await suggest("SELECT total AS amount FROM orders ORDER BY am|").first?.detail == "alias")
        // Two tables with the same name: it comes with its table.
        let both = try await suggest("SELECT i| FROM orders o JOIN customers c ON 1").map(\.text)
        #expect(both.prefix(2) == ["o.id", "c.id"])
        #expect(try await suggest("SELECT airsql_fixture.orders.cust| FROM orders").map(\.label) == ["customer_id"])
    }

    @Test func insertColumnsValuesAndStars() async throws {
        let list = try await suggest("INSERT INTO orders (|")
        #expect(list.first?.text == "customer_id, region, number, total, parent_id", "AUTO_INCREMENT left out of the whole list")
        #expect(list.contains { $0.label == "id" } && list.allSatisfy { $0.kind == .column })
        #expect(try await suggest("INSERT INTO orders (id, re|").first?.label == "region")
        let values = try await suggest("INSERT INTO orders (id, total) VALUES (|")
        #expect(values.first?.text == "$id$, $total$$END$")
        #expect(try await suggest("SELECT *| FROM orders").first?.text == "id, customer_id, region, number, total, parent_id")
        #expect(try await suggest("SELECT *| FROM orders").first?.replacing == 7..<8)
        #expect(try await suggest("SELECT o.*| FROM orders o").first?.replacing == 7..<10)
        let two = try #require(try await suggest("SELECT *| FROM log l JOIN audit a ON 1").first?.text)
        #expect(two == "l.at, l.message, a.id, a.what, a.address")
        #expect(try await suggest("SELECT 2 *| FROM orders").first?.replacing == nil, "a product, not a star")
    }

    @Test func joinsAndConditions() async throws {
        let on = try await suggest("SELECT * FROM orders o JOIN customers c ON |")
        #expect(on.first?.text == "c.id = o.customer_id" && on.first?.kind == .join)
        // Names alone: orders.customer_id to customers.id with no key in the way.
        var snapshot = try await SchemaTests.loaded(SchemaFixtures.mariadb118).0.snapshot
        let index = try #require(snapshot.databases.firstIndex { $0.name == "airsql_fixture" })
        let table = try #require(snapshot.databases[index].tables.firstIndex { $0.name == "orders" })
        snapshot.databases[index].tables[table].foreignKeys = []
        let text = "SELECT * FROM orders o JOIN "
        let items = SQLCompletion.suggestions(text: text, caret: (text as NSString).length, snapshot: snapshot, database: "airsql_fixture").items
        #expect(items.contains { $0.text == "customers c ON c.id = o.customer_id" && $0.detail == "same names" }, "\(items.prefix(3).map(\.text))")
        // A key the person defined counts as a key.
        let virtual = SchemaForeignKey(name: "v", columns: ["message"], referencedDatabase: "airsql_fixture", referencedTable: "audit", referencedColumns: ["what"], onUpdate: "", onDelete: "")
        let added = snapshot.adding(["airsql_fixture": ["log": [virtual]]])
        let log = "SELECT * FROM log l JOIN "
        let joined = SQLCompletion.suggestions(text: log, caret: (log as NSString).length, snapshot: added, database: "airsql_fixture").items
        #expect(joined.first?.text == "audit a ON a.what = l.message")
    }

    @Test func aliasOnlyWhereOneFits() async throws {
        var options = CompletionOptions()
        options.tableAlias = true
        #expect(try await suggest("SELECT * FROM order_li|", options: options).first?.text == "order_lines ol")
        #expect(try await suggest("SELECT * FROM orders o, cust|", options: options).first?.text == "customers c")
        #expect(try await suggest("SELECT * FROM cust|  c2", options: options).first?.text == "customers", "it has one")
        #expect(try await suggest("DELETE FROM cust|", options: options).first?.text == "customers")
        #expect(try await suggest("INSERT INTO cust|", options: options).first?.text == "customers")
        #expect(SQLCompletion.alias("order_regions", used: []) == "or2", "OR is reserved")
        #expect(SQLCompletion.alias("orders", used: ["o"]) == "o2")
    }

    @Test func valuesOfEnumsAndSettings() async throws {
        #expect(try await suggest("SELECT * FROM customers WHERE status = '|").map(\.text) == ["'new'", "'active'", "'gone'"])
        #expect(try await suggest("SELECT * FROM customers c WHERE c.status IN ('new', 'g|").map(\.text) == ["'gone'"])
        #expect(try await suggest("SELECT * FROM customers WHERE status = |").first?.text == "'new'")
        #expect(try await suggest("SELECT * FROM customers WHERE email = '|").isEmpty)
        #expect(try await suggest("SELECT 1 -- status = '|").isEmpty)
    }

    @Test func variablesWordsAndColumnsBeforeFrom() async throws {
        #expect(try await suggest("SELECT @@sql_m|").map(\.text) == ["@@sql_mode"])
        #expect(try await suggest("SET @total = 1; SELECT @to|").map(\.text) == ["@total"])
        #expect(try await suggest("SET sql_m|").map(\.text) == ["sql_mode"])
        #expect(try await suggest("SELECT zebra; SELECT zeb|").map(\.label) == ["zebra"])
        let first = try #require(try await suggest("SELECT ema|").first { $0.label == "email_domain" })
        #expect(first.text == "email_domain$END$ FROM customers" && first.kind == .template)
    }

    @Test func postfixAndTemplates() async throws {
        let post = try await suggest("orders.|")
        #expect(post.map(\.label) == ["from", "cfrom", "afrom", "join", "cast"])
        #expect(post[0].text == "SELECT * FROM orders$END$" && post[0].replacing == 0..<7)
        #expect(post[2].text.hasPrefix("SELECT o.id, o.customer_id") && post[2].text.hasSuffix("FROM orders o$END$"))
        #expect(post[3].text == "SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id$END$")
        #expect(try await suggest("SELECT o.total.ca| FROM orders o").first?.text == "CAST(o.total AS $type$)$END$")
        #expect(try await suggest("SELECT 1 FROM orders WHERE log.fr|").isEmpty, "a query can't start here")
        let sel = try await suggest("sel|")
        #expect(sel.first?.kind == .template && sel.first?.label == "sel")
        #expect(try await suggest("se|").first?.kind == .keyword, "the abbreviation isn't whole yet")
        var options = CompletionOptions()
        options.snippets = [SQLSnippet(name: "Mine", abbreviation: "sel", body: "SELECT 1"), SQLSnippet(name: "No word", body: "SELECT 2")]
        #expect(try await suggest("sel|", options: options).first?.text == "SELECT 1")
    }
}

struct SnippetSettingsTests {
    @Test func ownSnippetsComeFirstAndSurviveSaving() throws {
        var settings = AppSettings()
        settings.snippets = [SQLSnippet(name: "Mine", abbreviation: "sel", folder: "Work", body: "SELECT 1")]
        settings.formatStyle.keywords = .lower
        settings.completionTableAlias = false
        let options = settings.completionOptions(recent: ["x": 1])
        #expect(options.snippets.first?.name == "Mine" && options.snippets.count == SQLSnippet.builtIn.count + 1)
        #expect(options.keywordCase == .lower && !options.tableAlias && options.recent == ["x": 1])
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(back == settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)) == AppSettings(), "older settings")
    }

    @Test func documentationOfASuggestion() async throws {
        let (cache, _) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
        let table = CompletionItem(kind: .table, text: "log", label: "log", detail: "table")
        #expect(SQLCompletion.documentation(table, snapshot: cache.snapshot, database: "airsql_fixture") == "at datetime, message varchar(200)")
        let template = CompletionItem(kind: .template, text: "SELECT $a$$END$", label: "x", detail: "")
        #expect(SQLCompletion.documentation(template, snapshot: nil, database: nil) == "SELECT a")
    }
}

struct SQLTemplateTests {
    @Test func fieldsEndAndDollars() {
        let plain = SQLTemplate.expand("SELECT * FROM $table$ WHERE $a$ = $a$;$END$")
        #expect(plain.text == "SELECT * FROM table WHERE a = a;")
        #expect(plain.fields == [[14..<19], [26..<27, 30..<31]] && plain.end == 32)
        #expect(SQLTemplate.expand("a $$ b $1 $ $x y$").text == "a $ b $1 $ $x y$")
        #expect(SQLTemplate.expand("($SELECTION$) AS $alias$", selection: "SELECT 1").text == "(SELECT 1) AS alias")
        #expect(SQLTemplate.expand("x").fields.isEmpty && SQLTemplate.expand("x").end == nil)
        #expect(SQLTemplate.expand(SQLTemplate.escape("a$b$c")).text == "a$b$c")
    }

    @Test func builtInsHaveFieldsAndAnEnd() {
        #expect(Set(SQLSnippet.builtIn.map(\.abbreviation)) == ["sel", "selw", "selc", "lim", "ins", "upd", "del", "tab", "view", "col"])
        for snippet in SQLSnippet.builtIn {
            let expansion = SQLTemplate.expand(snippet.body)
            #expect(!expansion.fields.isEmpty && expansion.end != nil && !expansion.text.contains("$"), "\(snippet.name)")
        }
    }
}

struct ExplainPlanTests {
    @Test func mariaDBsJSONPlanReadsAsATree() {
        let json = #"{"query_block": {"select_id": 1, "nested_loop": [{"table": {"table_name": "o", "access_type": "range", "key": "k", "rows": 4, "using_index": true}}, {"table": {"table_name": "c", "access_type": "eq_ref", "rows": 1, "using_index": false}}]}}"#
        #expect(ExplainPlan.tree(fromJSON: json) == """
            Query block #1
                Nested Loop
                    Table o (access type: range, key: k, rows: 4, using index)
                    Table c (access type: eq_ref, rows: 1)
            """)
        #expect(ExplainPlan.tree(fromJSON: "not json") == "not json")
        // MariaDB 10.5 and 10.6 repeat the key, in the join's order; a quote in a value doesn't end its string.
        let repeated = #"{"query_block": {"table": {"table_name": "o", "rows": 2}, "table": {"table_name": "c", "#
            + #""attached_condition": "c.a = '\"table\": 1'"}, "table": {"table_name": "i"}}}"#
        #expect(ExplainPlan.tree(fromJSON: repeated) == #"""
            Query block
                Table o (rows: 2)
                Table c (attached condition: c.a = '"table": 1')
                Table i
            """#)
        #expect(ExplainPlan.treeSQL("SELECT 1", server: nil).json)
        func server(_ flavor: ServerInfo.Flavor, _ number: Int) -> ServerInfo {
            ServerInfo(flavor: flavor, version: "", versionNumber: number, threadID: 1, tls: nil, certificate: nil)
        }
        #expect(!ExplainPlan.treeSQL("SELECT 1", server: server(.mysql, 80016)).json)
        #expect(ExplainPlan.treeSQL("SELECT 1", server: server(.mysql, 80015)).json)
        #expect(ExplainPlan.treeSQL("SELECT 1", server: server(.mariadb, 110809)).json)
        #expect(server(.mariadb, 110100).atLeast(11, 1) && !server(.mariadb, 110099).atLeast(11, 1))
        #expect(server(.mysql, 50720).atLeast(5, 7, 20) && !server(.mysql, 50719).atLeast(5, 7, 20) && !server(.mysql, 79999).atLeast(8))
    }
}

struct ResultSetSourceTests {
    @Test func columnsKindsNullsAndLongValues() {
        let store = ResultStore(columns: [
            ResultStore.Column(name: "id", type: MYSQL_TYPE_LONG, flags: UInt32(PRI_KEY_FLAG)),
            ResultStore.Column(name: "note", table: "t", type: MYSQL_TYPE_BLOB, charset: 45),
            ResultStore.Column(name: "at", type: MYSQL_TYPE_DATETIME), ResultStore.Column(name: "doc", type: MYSQL_TYPE_JSON),
            ResultStore.Column(name: "raw", type: MYSQL_TYPE_BLOB, charset: 63),
        ])
        let long = String(repeating: "x", count: 5_000)
        store.append([Array("7".utf8), Array(long.utf8), nil, Array("{}".utf8), Array(repeating: 0xFF, count: 300)])
        let source = ResultSetSource(store)
        #expect(source.columns.map(\.kind) == [.number, .text, .date, .json, .binary])
        #expect(source.columns[0].isKey && source.columns.map(\.type) == ["int", "text", "datetime", "json", "blob"])
        #expect(source.rowCount == 1 && source.cell(0, 0) == .text("7") && source.cell(0, 2) == .null)
        #expect(source.cell(0, 1).text.count == ResultSetSource.shownLimit + 1 && source.cell(0, 1).text.hasSuffix("…"))
        #expect(source.value(0, 1) == long && source.value(0, 2) == nil)
        // The cell on screen cuts a BLOB to 256 bytes, but ⌘C and export copy the whole value.
        #expect(source.cell(0, 4).text == "0x" + String(repeating: "FF", count: 256) + "…")
        #expect(source.value(0, 4) == "0x" + String(repeating: "FF", count: 300))
    }
}

@Suite struct QueryHistoryRemoveTests {
    @Test func removesOnlyTheChosenStatements() async throws {
        let history = QueryHistory(directory: URL(fileURLWithPath: try scratch()))
        let id = UUID()
        for sql in ["SELECT 1", "SELECT 2", "SELECT 3"] { history.add(HistoryEntry(sql: sql, connection: id)) }
        history.flush()
        let all = await history.entries(id)
        history.remove([all[1]], from: id)
        #expect(await history.entries(id).map(\.sql) == ["SELECT 3", "SELECT 1"])
    }
}

/// The local check for unknown names: what it finds, and above all where it says nothing.
@Suite struct SQLNameCheckTests {
    static func snapshot(version: String = "8.4.3", caseless: Int = 0) -> SchemaSnapshot {
        func table(_ name: String, _ columns: [String], kind: SchemaTable.Kind = .table) -> SchemaTable {
            var table = SchemaTable(name: name, kind: kind)
            table.columns = columns.map {
                SchemaColumn(name: $0, dataType: "int", columnType: "int", nullable: true, defaultValue: .none, autoIncrement: false,
                             onUpdate: nil, generated: nil, invisible: false, isJSON: false, charset: nil, collation: nil, comment: "")
            }
            return table
        }
        var shop = SchemaDatabase(name: "shop", charset: "utf8mb4", collation: "utf8mb4_bin")
        shop.tables = [table("orders", ["id", "total", "customer_id", "year", "café"]), table("customers", ["id", "name"]),
                       table("Order Details", ["id", "order id"]), table("big_view", ["id"], kind: .view), table("broken_view", [], kind: .view)]
        shop.detailsLoaded = true
        var names = SchemaDatabase(name: "names_only", charset: "utf8mb4", collation: "utf8mb4_bin")
        names.tables = [table("t", [])]
        var system = SchemaDatabase(name: "information_schema", charset: "utf8mb3", collation: "utf8mb3_general_ci")
        system.tables = [table("TABLES", ["TABLE_NAME"])]
        system.detailsLoaded = true
        var snapshot = SchemaSnapshot()
        snapshot.server = SchemaServer(version: version, lowerCaseTableNames: caseless)
        snapshot.databases = [shop, names, system]
        return snapshot
    }

    /// The words underlined in `sql`.
    func found(_ sql: String, snapshot: SchemaSnapshot? = snapshot(), database: String? = "shop", changed: Set<String> = []) -> [String] {
        let text = sql as NSString
        return SQLNameCheck.problems(in: sql, snapshot: snapshot, database: database, changed: changed)
            .map { text.substring(with: NSRange($0.range)) }
    }

    @Test func findsUnknownTablesAndColumns() {
        #expect(found("SELECT * FROM nosuch") == ["nosuch"])
        #expect(found("SELECT 1 FROM orders o JOIN nosuch n ON n.id = o.id") == ["nosuch"])
        #expect(found("SELECT 1 FROM orders, nosuch") == ["nosuch"])
        #expect(found("SELECT 1 FROM orders o JOIN customers c ON c.id = o.id, nosuch") == ["nosuch"])
        #expect(found("SELECT * FROM orders WHERE id IN (SELECT id FROM nosuch)") == ["nosuch"])
        #expect(found("UPDATE nosuch SET a = 1") == ["nosuch"])
        #expect(found("DELETE FROM nosuch") == ["nosuch"])
        #expect(found("INSERT INTO nosuch (a) VALUES (1)") == ["nosuch"])
        #expect(found("SELECT * FROM shop.nosuch") == ["nosuch"])
        #expect(found("SELECT nope, id FROM orders") == ["nope"])
        #expect(found("SELECT o.nope, c.name FROM orders o JOIN customers c ON c.id = o.customer_id") == ["nope"])
        #expect(found("SELECT COUNT(o.nope) FROM orders o") == ["nope"])
        #expect(found("SELECT id FROM orders WHERE nope = 1 AND total > 2 ORDER BY other_one DESC") == ["nope", "other_one"])
        #expect(found("UPDATE orders SET nope = 1, total = nada WHERE id = 1") == ["nope", "nada"])
        #expect(found("INSERT INTO orders (id, nope) VALUES (1, 2)") == ["nope"])
        #expect(found("SELECT `nope` FROM `orders`") == ["`nope`"])
        // Each statement of a script, at its place.
        let text = "SELECT 1;\nSELECT é, nope FROM orders;"
        let problem = SQLNameCheck.problems(in: text, snapshot: Self.snapshot(), database: "shop").first
        #expect(problem?.range == ((text as NSString).range(of: "nope").location..<(text as NSString).range(of: "nope").location + 4))
        #expect(problem?.message.contains("“nope”") == true && problem?.message.contains("“orders”") == true)
    }

    @Test func validStatementsStayClean() {
        for sql in [
            "SELECT 1", "SELECT NOW()", "SELECT 1 FROM DUAL", "SELECT * FROM orders", "SELECT o.* FROM orders o",
            "SELECT id, total * 2 AS twice, total + 1 plus FROM orders ORDER BY twice, plus",
            "SELECT id AS 'the id' FROM orders ORDER BY `the id`",
            "SELECT COUNT(*) n, customer_id FROM orders GROUP BY customer_id HAVING n > 1",
            "SELECT EXTRACT(YEAR FROM NOW()), TRIM(BOTH 'x' FROM 'y'), SUBSTRING('abc' FROM 1 FOR 2) FROM orders",
            "SELECT CAST(id AS DECIMAL(10, 2)), CONVERT(id, SIGNED), TIMESTAMPDIFF(MONTH, NOW(), NOW()) FROM orders",
            "SELECT GROUP_CONCAT(id ORDER BY total SEPARATOR ',') FROM orders",
            "SELECT CASE WHEN total > 1 THEN id ELSE customer_id END FROM orders",
            "SELECT DATE '2024-01-01', _utf8mb4'x', CURRENT_DATE, CURRENT_TIMESTAMP, NULL, TRUE FROM orders",
            "SELECT id FROM orders WHERE total BETWEEN 1 AND 2 AND id IN (1, 2) AND total IS NOT NULL",
            "SELECT NOW() + INTERVAL 1 DAY FROM orders",
            "SELECT SQL_NO_CACHE * FROM orders", "SELECT SQL_CALC_FOUND_ROWS id FROM orders LIMIT 1, 2",
            "SELECT id FROM orders FORCE INDEX (primary_key), customers", "SELECT 1 FROM orders PARTITION (p0) o WHERE o.id = 1",
            "SELECT o.id FROM orders o WHERE EXISTS (SELECT 1 FROM customers c WHERE c.id = o.customer_id AND total > 1)",
            "SELECT id FROM orders UNION SELECT id FROM customers ORDER BY id",
            "SELECT id FROM orders FOR UPDATE OF orders, customers", "SELECT id INTO @a FROM orders", "SELECT id INTO a, b FROM orders",
            "SELECT id, SUM(total) OVER w FROM orders WINDOW w AS (ORDER BY id), v AS (ORDER BY total)",
            "SELECT `order id` FROM `Order Details`", "SELECT `Order Details`.`order id` FROM `Order Details`",
            "SELECT o.id FROM shop.orders o", "SELECT shop.orders.id FROM shop.orders", "SELECT ID, Total FROM orders",
            "SELECT `year` FROM orders", "SELECT id FROM big_view", "SELECT nosuch_column FROM broken_view",
            "SELECT _rowid FROM orders",
            "UPDATE orders SET total = total + 1 WHERE id = 1 ORDER BY id LIMIT 1",
            "UPDATE orders o JOIN customers c ON c.id = o.customer_id SET o.total = 1, c.name = 2",
            "DELETE FROM orders WHERE id = 1", "DELETE o FROM orders o JOIN customers c ON c.id = o.id",
            "DELETE o, c FROM orders o, customers c", "DELETE FROM a1 USING orders AS a1 JOIN customers AS a2",
            "INSERT INTO orders VALUES (1, 2)", "INSERT INTO orders (id) VALUES (DEFAULT), (1)", "INSERT orders SET id = 1, total = 2",
            "INSERT INTO orders (id) SELECT id FROM customers",
            "INSERT INTO orders (id) VALUES (1) AS new(a) ON DUPLICATE KEY UPDATE total = a, id = VALUES(id)",
            "REPLACE INTO orders (id) VALUES (1)", "DELETE FROM orders RETURNING id, total", "SELECT id FROM orders o FOR UPDATE OF o, p",
        ] {
            #expect(found(sql) == [], "\(sql)")
        }
    }

    @Test func silentWhenTheCacheIsNotLoaded() {
        #expect(found("SELECT * FROM nosuch", snapshot: nil) == [])
        #expect(found("SELECT * FROM nosuch", snapshot: SchemaSnapshot()) == [])
        #expect(found("SELECT * FROM nosuch", database: nil) == [])
        #expect(found("SELECT * FROM nosuch", database: "names_only") == [])
        #expect(found("SELECT * FROM nosuch", database: "not_in_the_cache") == [])
    }

    @Test func silentForAnotherDatabaseThatIsNotLoaded() {
        #expect(found("SELECT * FROM names_only.nosuch") == [])
        #expect(found("SELECT * FROM elsewhere.nosuch") == [])
        // USE moves the statements after it, and only those.
        #expect(found("SELECT * FROM a; USE elsewhere; SELECT * FROM b; USE shop; SELECT * FROM c") == ["a", "c"])
        // Nor can a column be checked beside a table that isn't known.
        #expect(found("SELECT nope FROM orders JOIN elsewhere.t") == [])
        // information_schema's names have no case, whatever the server's rule.
        #expect(found("SELECT table_name FROM information_schema.tables") == [])
    }

    @Test func silentForTemporaryAndNewTables() {
        #expect(found("SELECT * FROM tmp", changed: ["tmp"]) == [])
        #expect(found("SELECT * FROM TMP", changed: ["tmp"]) == [])
        // A temporary table may hide a real one.
        #expect(found("SELECT nope FROM orders", changed: ["orders"]) == [])
        #expect(found("CREATE TEMPORARY TABLE tmp (a INT); SELECT a FROM tmp; INSERT INTO tmp VALUES (1)") == [])
        #expect(found("SELECT * FROM `new one`; CREATE TABLE `new one` (a INT)") == [])
        #expect(found("ALTER TABLE orders ADD extra INT; SELECT extra FROM orders") == [])
        #expect(found("RENAME TABLE orders TO sales; SELECT * FROM sales") == [])
        #expect(found("CALL make_tables(); SELECT * FROM tmp") == [])
        #expect(SQLNameCheck.changedNames(in: "CREATE TEMPORARY TABLE IF NOT EXISTS `Tmp` (a INT)").contains("tmp"))
        #expect(SQLNameCheck.changedNames(in: "SELECT * FROM tmp").isEmpty)
        #expect(SQLNameCheck.runsCode("call p()") && !SQLNameCheck.runsCode("SELECT 1"))
    }

    @Test func readsCTEsAndDerivedTables() {
        #expect(found("WITH c AS (SELECT id FROM orders) SELECT id, nope FROM c") == ["nope"])
        #expect(found("WITH c AS (SELECT * FROM orders) SELECT total, nope FROM c") == ["nope"])
        #expect(found("SELECT d.nope FROM (SELECT id AS x FROM orders) d") == ["nope"])
        #expect(found("SELECT * FROM orders WHERE id = (SELECT nope FROM (SELECT 1 AS x) d)") == ["nope"])
        #expect(found("WITH RECURSIVE c (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c) SELECT n FROM c") == [])
        #expect(found("SELECT * FROM orders WHERE id IN (WITH c AS (SELECT 1) SELECT * FROM c)") == [])
        #expect(found("SELECT d.x, x FROM (SELECT id AS x FROM orders) d") == [])
        #expect(found("SELECT x, o.nope FROM orders o JOIN (SELECT 1 AS x) d ON 1") == ["nope"])
        #expect(found("SELECT j.a, a FROM orders, JSON_TABLE('[]', '$[*]' COLUMNS (a INT PATH '$')) j") == [])
        #expect(found("SELECT x FROM orders o, LATERAL (SELECT o.id AS x) l") == [])
        // Inside a derived table its own tables still count.
        #expect(found("SELECT * FROM (SELECT * FROM nosuch) d") == ["nosuch"])
    }

    @Test func aBareColumnWaitsForEveryTableItCouldBeIn() {
        #expect(found("SELECT nope FROM orders JOIN nosuch") == ["nosuch"])
        #expect(found("SELECT o.nope FROM orders o JOIN nosuch n") == ["nope", "nosuch"])
        #expect(found("SELECT nope FROM orders WHERE id IN (SELECT id FROM elsewhere.t)") == ["nope"])
        #expect(found("SELECT 1 FROM orders WHERE id IN (SELECT nope FROM elsewhere.t)") == [])
        #expect(found("SELECT nope") == [])
        #expect(found("SELECT nope FROM DUAL") == [])
        // A correlated subquery reaches the outer table's columns.
        #expect(found("SELECT 1 FROM orders WHERE EXISTS (SELECT 1 FROM customers WHERE name = total)") == [])
    }

    @Test func silentForStatementsItDoesNotUnderstand() {
        for sql in [
            "SHOW TABLES FROM nosuch", "DESCRIBE nosuch", "SET @a = nosuch", "TRUNCATE nosuch",
            "CREATE VIEW v AS SELECT nope FROM nosuch", "DROP TABLE nosuch", "ANALYZE TABLE nosuch",
            "LOAD DATA INFILE 'x' INTO TABLE nosuch", "/*!50001 SELECT * FROM nosuch */", "SELECT /*!40001 SQL_NO_CACHE */ * FROM nosuch",
            "SELECT * FROM nosuch WHERE a = 'open", "SELECT (1 FROM nosuch", "SELECT 1) FROM nosuch",
            "CREATE PROCEDURE p() BEGIN DECLARE a INT; SELECT a FROM orders; SELECT * FROM nosuch; END",
            "BEGIN NOT ATOMIC SELECT * FROM nosuch; END",
            "SELECT * FROM \"nosuch\" JOIN orders WHERE nope = 1",
            "SELECT café, cafe FROM orders",
        ] {
            #expect(found(sql) == [], "\(sql)")
        }
    }

    @Test func readsWhatsAroundAQuery() {
        #expect(found("EXPLAIN SELECT * FROM nosuch") == ["nosuch"])
        #expect(found("(SELECT * FROM nosuch)") == ["nosuch"])
        #expect(found("SELECT shop.orders.nope FROM shop.orders") == ["nope"])
        #expect(found("SELECT { fn NOW() }, nope FROM orders") == ["nope"])
        #expect(found("SELECT COUNT(nope), SUM(o.nada) FROM orders o") == ["nope", "nada"])
    }

    @Test func followsTheServersCaseRule() {
        #expect(found("SELECT * FROM ORDERS") == ["ORDERS"])
        #expect(found("SELECT * FROM `Orders`") == ["`Orders`"])
        #expect(found("SELECT * FROM SHOP.orders") == [])  // that database isn't in the cache, in this case
        let caseless = Self.snapshot(caseless: 2)
        #expect(found("SELECT * FROM ORDERS", snapshot: caseless) == [])
        #expect(found("SELECT * FROM SHOP.`Orders`", snapshot: caseless) == [])
        #expect(found("SELECT id FROM orders O WHERE o.TOTAL = 1") == [])  // columns never have case
    }

    /// MariaDB's Sequence engine answers for tables no list shows.
    @Test func silentForMariaDBsSequenceTables() {
        let mariadb = Self.snapshot(version: "11.8.3-MariaDB")
        #expect(found("SELECT seq FROM seq_1_to_10", snapshot: mariadb) == [])
        #expect(found("SELECT seq FROM seq_1_to_10") == ["seq_1_to_10"])
    }

    @Test func aLongBrokenScriptStopsAtTheLimit() {
        let script = String(repeating: "SELECT * FROM nosuch;\n", count: 500)
        #expect(SQLNameCheck.problems(in: script, snapshot: Self.snapshot(), database: "shop").count == 100)
    }
}

/// The plan's steps, from either of the servers' forms.
@Suite struct ExplainPlanNodesTests {
    @Test func mysqlsTreeBecomesStepsWithTheirFigures() throws {
        let nodes = ExplainPlan.nodes(from: """
            -> Nested loop inner join  (cost=4.50 rows=2) (actual time=0.10..9.00 rows=2 loops=1)
                -> Table scan on c  (cost=0.50 rows=2) (actual time=0.05..0.10 rows=2 loops=1)
                -> Filter: (o.id > 1)  (cost=2.00 rows=1) (actual time=4.00..4.40 rows=1 loops=2)
                    -> Index lookup on o using k (c=c.id)  (cost=2.00 rows=1)
            """, json: false)
        let root = try #require(nodes.first)
        #expect(nodes.count == 1 && root.operation == "Nested loop inner join")
        #expect(root.cost == 4.5 && root.rows == 2 && root.actualRows == 2 && root.time == 9 && root.loops == 1)
        #expect(root.children.map(\.operation) == ["Table scan on c", "Filter: (o.id > 1)"])
        #expect(root.children[1].time == 8.8, "the time of a loop, for each loop")
        #expect(root.children[1].children.first?.operation == "Index lookup on o using k (c=c.id)")
        #expect(root.children[1].hot && !root.children[0].hot && !root.hot)
    }

    @Test func aJSONPlanBecomesStepsWithTheirFigures() throws {
        let nodes = ExplainPlan.nodes(from: """
            {"query_block": {"select_id": 1, "r_loops": 1, "r_total_time_ms": 2.5, "nested_loop": [
                {"table": {"table_name": "c", "access_type": "ALL", "r_loops": 1, "rows": 10, "r_rows": 8, "r_table_time_ms": 1,
                           "r_other_time_ms": 0.5, "cost": 0.25, "attached_condition": "c.id > 1"}},
                {"table": {"table_name": "o", "access_type": "ref", "key": "k", "rows": 1, "cost_info": {"prefix_cost": "1.50"}}}]}}
            """, json: true)
        let block = try #require(nodes.first)
        #expect(block.operation == "Query block #1" && block.time == 2.5)
        let tables = try #require(block.children.first?.children)
        #expect(tables.map(\.operation) == ["Table c · ALL · where c.id > 1", "Table o · ref · key k"])
        #expect(tables[0].rows == 10 && tables[0].actualRows == 8 && tables[0].time == 1.5 && tables[0].cost == 0.25)
        #expect(tables[1].cost == 1.5)
        #expect(ExplainPlan.nodes(from: "not json", json: true).isEmpty)
    }

    @Test func analyzeUsesEachServersForm() {
        func server(_ flavor: ServerInfo.Flavor, _ number: Int) -> ServerInfo {
            ServerInfo(flavor: flavor, version: "", versionNumber: number, threadID: 1, tls: nil, certificate: nil)
        }
        #expect(ExplainPlan.analyzeSQL("SELECT 1", server: server(.mariadb, 110_404))?.sql == "ANALYZE FORMAT=JSON SELECT 1")
        #expect(ExplainPlan.analyzeSQL("SELECT 1", server: server(.mysql, 80_018))?.sql == "EXPLAIN ANALYZE SELECT 1")
        #expect(ExplainPlan.analyzeSQL("SELECT 1", server: server(.mysql, 80_017)) == nil)
        // Both forms run the statement: never read-only.
        for sql in ["ANALYZE FORMAT=JSON SELECT 1", "EXPLAIN ANALYZE SELECT 1"] {
            #expect(StatementCheck.readOnlyRefusal(sql, on: "x", noBackslashEscapes: false) != nil)
        }
    }
}

/// `?` and `:name`, and what runs from the caret.
@Suite struct QueryParameterTests {
    func keys(_ sql: String) -> [String] { QueryParameters.places(in: [sql], noBackslashEscapes: false)[0].map(\.key) }

    @Test func parametersAreFoundOnlyInCode() {
        #expect(keys("SELECT * FROM t WHERE a = ? AND b = :name OR c = :name AND d=:other") == ["?1", ":name", ":name", ":other"])
        #expect(keys("SELECT '?', ':no', `?` -- ? :x\n/* ? */ # :y\n").isEmpty)
        #expect(keys("SET @a := 1").isEmpty)
        #expect(keys("lbl:LOOP LEAVE lbl; END LOOP").isEmpty)
        #expect(keys("lbl: LOOP").isEmpty)
        #expect(keys("SELECT (:a)") == [":a"])
        #expect(keys("SELECT ${a}, :a, ? , '${b}', $x") == [":a", ":a", "?1"], "${name} and :name are one parameter")
        #expect(QueryParameters.places(in: ["CALL p(? /* p_id int */)"], noBackslashEscapes: false)[0].first?.hint == "p_id int")
        let two = QueryParameters.places(in: ["SELECT ?", "SELECT ?, :a"], noBackslashEscapes: false)
        #expect(QueryParameters.keys(two) == ["?1", "?2", ":a"])
    }

    @Test func aValueCanNeverBecomeCode() {
        func bound(_ value: String, noBackslashEscapes: Bool = false) -> String {
            let sql = "SELECT :v, ':v'"
            let places = QueryParameters.places(in: [sql], noBackslashEscapes: noBackslashEscapes)[0]
            return QueryParameters.bind(sql, places, values: [":v": value], noBackslashEscapes: noBackslashEscapes)
        }
        #expect(bound("7") == "SELECT 7, ':v'")
        #expect(bound("-1.5") == "SELECT -1.5, ':v'")
        #expect(bound("007") == "SELECT '007', ':v'")
        #expect(bound("null") == "SELECT NULL, ':v'")
        #expect(bound("") == "SELECT '', ':v'")
        #expect(bound("1 OR 1=1") == "SELECT '1 OR 1=1', ':v'")
        #expect(bound("x'; DROP TABLE t; -- ") == #"SELECT 'x\'; DROP TABLE t; -- ', ':v'"#)
        #expect(bound("a'b\\", noBackslashEscapes: true) == #"SELECT 'a''b\', ':v'"#)
    }

    @Test func runningFromTheCaretTakesTheRest() {
        let text = "SELECT 1;\nSELECT 2;\nSELECT 3;"
        #expect(ConsoleScript.statements(from: 12, in: text, noBackslashEscapes: false).map(\.sql) == ["SELECT 2", "SELECT 3"])
    }

    @Test func theSmallestSubqueryAroundTheCaret() {
        let text = "SELECT * FROM (SELECT a FROM t WHERE b IN (SELECT c FROM u /* x */)) d WHERE e IN (1, 2)"
        func at(_ word: String) -> String? {
            ConsoleScript.subquery(at: (text as NSString).range(of: word).location, in: text, noBackslashEscapes: false)?.sql
        }
        #expect(at("c FROM") == "SELECT c FROM u")
        #expect(at("a FROM") == "SELECT a FROM t WHERE b IN (SELECT c FROM u /* x */)")
        #expect(at("1, 2") == nil, "brackets that hold no query")
        #expect(at("d WHERE") == nil)
        let cte = "SELECT * FROM (WITH x AS (SELECT 1) SELECT * FROM x) y"
        #expect(ConsoleScript.subquery(at: 40, in: cte, noBackslashEscapes: false)?.sql == "WITH x AS (SELECT 1) SELECT * FROM x")
    }
}

/// The saved states of a file, and the history over every connection.
@Suite struct LocalHistoryTests {
    @Test func savedStatesComeBackNewestFirstAndTheOldestGo() throws {
        let history = LocalHistory(directory: URL(fileURLWithPath: try scratch()), limit: 3)
        let file = URL(fileURLWithPath: "/nowhere/a.sql"), other = URL(fileURLWithPath: "/nowhere/b.sql")
        for (index, text) in ["one", "two", "two", "three", "four"].enumerated() {
            history.save(text, of: file, at: Date(timeIntervalSince1970: Double(index + 1)))
        }
        let texts = history.versions(of: file).map { try? String(contentsOf: $0.url, encoding: .utf8) }
        #expect(texts == ["four", "three", "two"], "the same text twice is one state; only the newest are kept")
        #expect(history.versions(of: other).isEmpty)
        let path = try #require(history.versions(of: file).first?.url.path)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func theHistoryCanBeSearchedOverEveryConnection() async throws {
        let history = QueryHistory(directory: URL(fileURLWithPath: try scratch()))
        let a = UUID(), b = UUID()
        history.add(HistoryEntry(sql: "SELECT 1", date: Date(timeIntervalSince1970: 1), connection: a))
        history.add(HistoryEntry(sql: "SELECT 2", date: Date(timeIntervalSince1970: 2), connection: b))
        history.add(HistoryEntry(sql: "DROP TABLE t", date: Date(timeIntervalSince1970: 3), connection: b))
        history.flush()
        #expect(await history.allEntries(matching: "select").map(\.sql) == ["SELECT 2", "SELECT 1"])
    }
}

@Suite struct FileDecodingTests {
    @Test func filesOpenByMarkThenUTF8ThenLatin() {
        for (bytes, text, name) in [(Array("é".utf8), "é", nil), ([0xEF, 0xBB, 0xBF, 0x61], "a", "UTF-8 with a byte-order mark"),
                                    ([0xFF, 0xFE, 0x61, 0x00], "a", "UTF-16"), ([0xE9], "é", "Windows Latin 1")] as [([UInt8], String, String?)] {
            let read = ConsoleScript.decoded(Data(bytes))
            #expect(read.text == text && read.format.name == name)
            #expect(ConsoleScript.encoded(read.text, read.format).map(ConsoleScript.decoded)?.format == read.format, "Save keeps it")
        }
        #expect(ConsoleScript.encoded("日本", ConsoleScript.FileFormat(encoding: .windowsCP1252)) == nil)
    }
}
