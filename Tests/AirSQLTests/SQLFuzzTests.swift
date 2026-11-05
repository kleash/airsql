import Foundation
import Testing
@testable import AirSQLCore

/// Text as it is mid-edit, thrown at what reads SQL while someone types: nothing may trap or hang. The inputs are the same
/// on every run (`seed`), a statement with words swapped, or a soup of tokens.
struct SQLFuzzTests {
    private static let words = ["SELECT", "FROM", "WHERE", "(", ")", ",", ";", ".", "*", "a", "t", "u", "`x`", "'s'", "\"d\"", "1", "2.5", "@v", "@@g", "INSERT",
                                "INTO", "VALUES", "ROW", "SET", "UPDATE", "DELETE", "CREATE", "TABLE", "VIEW", "ALTER", "DROP", "IF", "EXISTS", "NOT", "IN", "AS",
                                "ON", "USING", "JOIN", "LEFT", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "UNION", "ALL", "WITH", "RECURSIVE", "CASE", "WHEN", "THEN",
                                "ELSE", "END", "BEGIN", "DELIMITER $$", "$$", "INTERVAL", "CAST", "OVER", "PARTITION", "BETWEEN", "AND", "OR", "LIKE", "IS", "NULL",
                                "DISTINCT", "=", "<", "->>", ":=", "+", "-", "/", "?", "{", "}", "--c\n", "/*c*/", "/*!50000 ", "*/", "#h\n", "'open", "`open", "\n",
                                "DUPLICATE", "KEY", "RETURNING", "CALL", "EXPLAIN", "PROCEDURE", "TRIGGER", "INDEX", "LATERAL", "JSON_TABLE", "COUNT(", "é", "😀"]
    private static let statements = [
        "SELECT a, b AS c, (SELECT MAX(x) FROM u WHERE u.a = t.a) FROM t JOIN u ON t.a = u.b WHERE a IN (1,2) GROUP BY a ORDER BY b LIMIT 1;",
        "WITH c AS (SELECT 1) UPDATE t JOIN c SET t.a = 1 WHERE t.b = 2;", "INSERT INTO t (a,b) VALUES (1,2),(3,4) ON DUPLICATE KEY UPDATE a = VALUES(a);",
        "CREATE TABLE t (a INT, b VARCHAR(10), KEY k (a), FOREIGN KEY (a) REFERENCES u (b));", "DELETE t FROM t JOIN u USING (a) WHERE b;",
        "CREATE PROCEDURE p() BEGIN SELECT 1; END;", "SELECT CASE WHEN a THEN b ELSE c END, COUNT(*) OVER (PARTITION BY a) FROM t;",
    ]

    private static var snapshot: SchemaSnapshot {
        func column(_ name: String) -> SchemaColumn {
            SchemaColumn(name: name, dataType: "int", columnType: "int", nullable: true, defaultValue: .none, autoIncrement: false, onUpdate: nil,
                         generated: nil, invisible: false, isJSON: false, charset: nil, collation: nil, comment: "")
        }
        var table = SchemaTable(name: "t", kind: .table)
        table.columns = [column("a"), column("b")]
        var database = SchemaDatabase(name: "shop", charset: "utf8mb4", collation: "utf8mb4_bin")
        database.tables = [table]
        database.detailsLoaded = true
        var snapshot = SchemaSnapshot()
        snapshot.server = SchemaServer(version: "8.4.3")
        snapshot.databases = [database]
        return snapshot
    }

    @Test func readersOfSQLSurviveAnyText() {
        var seed: UInt64 = 1
        func random(_ below: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(below))
        }
        func text() -> String {
            var parts = random(2) == 0 ? Self.statements[random(Self.statements.count)].split(separator: " ").map(String.init) : []
            for _ in 0..<(1 + random(parts.isEmpty ? 30 : 4)) {
                let word = Self.words[random(Self.words.count)]
                if parts.isEmpty || random(2) == 0 { parts.insert(word, at: random(parts.count + 1)) } else { parts[random(parts.count)] = word }
            }
            return parts.joined(separator: random(5) == 0 ? "" : " ")
        }
        let snapshot = Self.snapshot
        for _ in 0..<400 {
            let sql = text(), length = sql.utf16.count, caret = random(length + 1)
            let analysis = SQLAnalysis(sql, snapshot: snapshot, database: "shop")
            _ = SQLInspections.problems(analysis)
            _ = SQLIntentions.hints(in: analysis)
            _ = SQLIntentions.actions(at: caret, in: analysis)
            _ = SQLCompletion.suggestions(text: sql, caret: caret, snapshot: snapshot, database: "shop")
            _ = SQLFolding.regions(in: sql)
            if let edit = SQLInPaste.edit(pasting: "1\n2", into: sql, selection: caret..<caret, snapshot: snapshot, database: "shop") {
                #expect(edit.range.upperBound <= length, "\(sql)")
            }
            if let formatted = SQLFormatter.format(sql) { #expect(SQLLexer.sameTokens(sql, formatted, ignoringCaseOf: { _ in true }), "\(sql)") }
        }
    }

    /// After a dot with a space, what's typed isn't against the dot.
    @Test func aWordApartFromTheDot() {
        for sql in ["SELECT t. f", "SELECT t. ", "SELECT o.id FROM orders o WHERE o. t", "SELECT t./*c*/f"] {
            _ = SQLCompletion.suggestions(text: sql, caret: sql.utf16.count, snapshot: Self.snapshot, database: "shop")
        }
    }
}
