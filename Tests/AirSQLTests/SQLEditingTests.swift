import Testing
@testable import AirSQLCore

/// The SQL-aware text of the editor's commands.
@Suite struct SQLEditingTests {
    func joined(_ text: String) -> String { SQLEditing.joined(text, 0..<text.utf16.count) }

    @Test func joiningKeepsTheMeaning() {
        #expect(joined("SELECT 1\n  FROM t\n\n  WHERE a") == "SELECT 1 FROM t WHERE a")
        #expect(joined("f(\n  a\n  , b\n)") == "f(a, b)")
        #expect(joined("SELECT 1 -- why\nFROM t") == "SELECT 1 -- why\nFROM t", "a comment would swallow the next line")
        #expect(joined("SELECT 'a\nb'\nFROM t") == "SELECT 'a\nb' FROM t", "a string's line break is its text")
        #expect(joined("/* a\nb */\nx") == "/* a\nb */ x")
    }

    /// The text each ⌥↑ selects from `|`.
    func growing(_ marked: String) -> [String] {
        let start = marked.utf16.firstIndex(of: 0x7C).map { marked.utf16.distance(from: marked.utf16.startIndex, to: $0) } ?? 0
        let text = marked.replacingOccurrences(of: "|", with: "")
        let units = Array(text.utf16)
        var selection = start..<start, steps: [String] = []
        while let next = SQLEditing.grown(selection, in: text) {
            selection = next
            steps.append(String(decoding: units[next], as: UTF16.self))
        }
        return steps
    }

    @Test func selectionGrowsBySyntax() {
        #expect(growing("SELECT a, t.b|c + 1, d FROM t WHERE x;\nSELECT 2") == [
            "bc", "t.bc", "t.bc + 1", "SELECT a, t.bc + 1, d", "SELECT a, t.bc + 1, d FROM t WHERE x",
            "SELECT a, t.bc + 1, d FROM t WHERE x;", "SELECT a, t.bc + 1, d FROM t WHERE x;\nSELECT 2",
        ])
        #expect(growing("WHERE x IN ('a|b', 'c')") == ["ab", "'ab'", "'ab', 'c'", "('ab', 'c')", "x IN ('ab', 'c')", "WHERE x IN ('ab', 'c')"])
        #expect(growing("WHERE a = 1 AND b|c = 2 OR d").prefix(3) == ["bc", "bc = 2", "WHERE a = 1 AND bc = 2 OR d"])
        #expect(growing("") == [])
    }

    @Test func aStatementCompletes() {
        func completed(_ text: String) -> String? {
            SQLEditing.completed(text, caret: text.utf16.count).map { edit in
                let units = Array(text.utf16)
                return String(decoding: units[..<edit.range.lowerBound], as: UTF16.self) + edit.text
                    + String(decoding: units[edit.range.upperBound...], as: UTF16.self)
            }
        }
        #expect(completed("SELECT (1") == "SELECT (1);")
        #expect(completed("SELECT f(g(1") == "SELECT f(g(1));")
        #expect(completed("SELECT 1;") == "SELECT 1;")
        #expect(completed("SELECT 'a") == nil, "a string left open")
        #expect(SQLEditing.completed("SELECT (1;\nSELECT 2", caret: 3)?.caret == 11, "before its delimiter, the caret after it")
    }
}
