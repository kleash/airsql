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

    @Test func foldsAreWhatSpansLines() {
        func regions(_ text: String) -> [String] {
            let units = Array(text.utf16)
            return SQLFolding.regions(in: text).map { String(decoding: units[$0], as: UTF16.self) }
        }
        #expect(regions("SELECT 1;\nSELECT 2") == [], "one line each")
        #expect(regions("SELECT 1\nFROM t;\nSELECT 2") == ["\nFROM t;"], "from the first line's end, its delimiter too")
        #expect(regions("SELECT (\n  1\n);") == ["\n  1\n);", "\n  1\n"], "the statement, then the brackets")
        #expect(regions("/* a\nb */\nSELECT 1") == ["\nb */"])
        #expect(regions("-- region x\nSELECT 1;\n-- endregion\n") == ["\nSELECT 1;\n-- endregion"])
        #expect(regions("SELECT '(\n)'") == ["\n)'"], "brackets in a string are text; the statement still spans lines")
    }

    @Test func pastesInAStringAreEscaped() {
        func pasted(_ clipboard: String, _ text: String, at place: Int, _ noBackslashEscapes: Bool = false) -> String? {
            SQLEditing.pastedInString(clipboard, into: text, selection: place..<place, noBackslashEscapes: noBackslashEscapes)?.text
        }
        #expect(pasted("O'Brien", "SELECT ''", at: 8) == "O\\'Brien")
        #expect(pasted("O'Brien", "SELECT ''", at: 8, true) == "O''Brien")
        #expect(pasted("O'Brien", "SELECT 'open", at: 12) == "O\\'Brien", "a string left open")
        #expect(pasted("plain", "SELECT ''", at: 8) == nil, "nothing to escape")
        #expect(pasted("O'Brien", "SELECT ", at: 7) == nil, "outside a string")
        #expect(pasted("O'Brien", "SELECT ''", at: 9) == nil, "just after one")
        #expect(pasted("O'Brien", "SELECT \"\"", at: 8) == nil, "double quotes may be a name")
        #expect(pasted("O'Brien", "-- ''", at: 4) == nil, "a comment")
    }

    @Test func blocksPairUp() {
        func pair(_ text: String, _ caret: Int) -> [String]? {
            let units = Array(text.utf16)
            return SQLEditing.blockPair(at: caret, in: text).map { [$0.0, $0.1].map { String(decoding: units[$0], as: UTF16.self) + "@\($0.lowerBound)" } }
        }
        let body = "BEGIN IF a THEN CASE WHEN 1 THEN 2 END; END IF; END"
        #expect(pair(body, 2) == ["BEGIN@0", "END@48"], "END IF is skipped")
        #expect(pair(body, 18) == ["CASE@16", "END@35"])
        #expect(pair(body, 49) == ["BEGIN@0", "END@48"], "from the END too")
        #expect(pair(body, 8) == nil)
        #expect(pair("SELECT 'BEGIN END'", 10) == nil, "a string")
        #expect(pair("BEGIN CASE WHEN 1 THEN 2 END CASE; END", 2) == ["BEGIN@0", "END@35"], "END CASE closes one CASE")
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
