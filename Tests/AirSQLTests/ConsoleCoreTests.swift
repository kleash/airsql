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
        #expect(format("update t set a = 1 where id in (select id from u where x)") == "UPDATE t\nSET a = 1\nWHERE id IN (SELECT id FROM u WHERE x)")
        #expect(format("insert into t (a) values (1) on duplicate key update a = values(a)")
                == "INSERT INTO t (a)\nVALUES (1) ON duplicate KEY UPDATE a = VALUES(a)")
        #expect(format("delete from t where a = 1") == "DELETE FROM t\nWHERE a = 1")
        #expect(format("create table t (a varchar(10)) default character set utf8mb4") == "CREATE TABLE t (a VARCHAR(10)) DEFAULT CHARACTER SET utf8mb4")
    }

    @Test func namesLiteralsAndCommentsStayAsTheyAre() {
        #expect(format("select t.order, `from` from t") == "SELECT t.order, `from`\nFROM t")
        #expect(format("select 'from  x'  -- keep  this\nfrom t") == "SELECT 'from  x' -- keep  this\nFROM t")
        #expect(format("select a,\n  -- the b column\n  b from t") == "SELECT a,\n-- the b column\nb\nFROM t")
        #expect(format("/*!40101 set   names utf8 */;") == "/*!40101 set   names utf8 */;")
        #expect(format("select count(*)  from t") == "SELECT count(*)\nFROM t")  // COUNT isn't reserved
    }

    @Test func delimiterBlocksAreLeftAlone() {
        let script = "DELIMITER ;;\nCREATE PROCEDURE p() begin select 1; end;;\nDELIMITER ;\nselect 2 from dual;"
        #expect(format(script) == "DELIMITER ;;\nCREATE PROCEDURE p() begin select 1; end;;\nDELIMITER ;\nSELECT 2\nFROM DUAL;")
    }

    @Test(arguments: AttackCorpus.all + ReadCorpus.all)
    func neverChangesWhatTheServerReads(_ sql: String) {
        let formatted = SQLFormatter.format(sql)
        #expect(formatted != nil, "\(sql)")
        if let formatted { #expect(SQLLexer.sameTokens(sql, formatted)) }
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
        #expect(items.map(\.label) == ["CONCAT", "CONCAT_WS"] && items.first?.text == "CONCAT(")
        #expect(try await suggest("SELECT JSON_D|").map(\.label) == ["JSON_DETAILED"], "MariaDB's")
        #expect(try await suggest("SELECT REGEXP_L|").isEmpty, "MySQL's only")
        #expect(try await suggest("SELECT 1 FR|").map(\.label) == ["FROM", "FROM_UNIXTIME"])
        // A name that needs quoting is offered quoted.
        #expect(try await suggest("SELECT * FROM we|").first?.text == "`we``ird 'name' ✓`")
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
