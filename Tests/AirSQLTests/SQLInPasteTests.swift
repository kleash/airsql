import Testing
@testable import AirSQLCore

/// Paste into `IN (…)`: where it applies, how values are quoted, and the commas around what is already there.
@Suite struct SQLInPasteTests {
    /// `sql` after pasting at its `|` (a caret) or between its two `|` (a selection), or nil when the paste stays plain.
    func pasted(_ clipboard: String, _ sql: String, snapshot: SchemaSnapshot? = nil, noBackslashEscapes: Bool = false) -> String? {
        let parts = sql.components(separatedBy: "|")
        let start = parts[0].utf16.count
        let end = parts.count > 2 ? start + parts[1].utf16.count : start
        let text = parts.joined()
        guard let edit = SQLInPaste.edit(pasting: clipboard, into: text, selection: start..<end, snapshot: snapshot, database: "shop",
                                         noBackslashEscapes: noBackslashEscapes) else { return nil }
        let units = Array(text.utf16)
        return String(decoding: units[..<edit.range.lowerBound], as: UTF16.self) + edit.text
            + String(decoding: units[edit.range.upperBound...], as: UTF16.self)
    }

    let list = "a\nb\nc"

    @Test func aListOfValuesIsQuoted() {
        #expect(pasted(list, "SELECT 1 FROM t WHERE x IN (|)") == "SELECT 1 FROM t WHERE x IN ('a', 'b', 'c')")
        #expect(pasted("a\tb\tc", "WHERE x not in (|)") == "WHERE x not in ('a', 'b', 'c')")
        #expect(pasted("a, b,c", "WHERE x IN (|)") == "WHERE x IN ('a', 'b', 'c')")
        #expect(pasted("a\r\nb\r\n", "WHERE x IN (|)") == "WHERE x IN ('a', 'b')")
        #expect(pasted("  a  \n\n\n  b\n\n", "WHERE x IN (|)") == "WHERE x IN ('a', 'b')", "blanks drop out, spaces trim")
        #expect(pasted("a\t\tb\nc\td", "WHERE x IN (|)") == "WHERE x IN ('a', 'b', 'c', 'd')", "a block of cells")
        #expect(pasted("a,\nb,\nc", "WHERE x IN (|)") == "WHERE x IN ('a', 'b', 'c')", "a comma ending a line")
        #expect(pasted("Table\nChair", "WHERE x IN (|)") == "WHERE x IN ('Table', 'Chair')", "a word, not a query")
        #expect(pasted("SELECT a\nFROM t", "WHERE x IN (|)") == nil, "a query goes in as it is")
        #expect(pasted("NULL\nb", "WHERE x IN (|)") == "WHERE x IN ('NULL', 'b')", "NULL is text here")
        #expect(pasted("1\n2", "WHERE x IN (|)") == "WHERE x IN ('1', '2')", "the column's type isn't known")
        #expect(pasted("12 High St, Leeds\n3 Low Rd, York", "WHERE x IN (|)") == "WHERE x IN ('12 High St, Leeds', '3 Low Rd, York')")
        #expect(pasted("é😀\nb", "WHERE é IN (|)") == "WHERE é IN ('é😀', 'b')")
    }

    @Test func escapingFollowsTheSession() {
        #expect(pasted("O'Brien\nC:\\tmp", "WHERE x IN (|)") == "WHERE x IN ('O\\'Brien', 'C:\\\\tmp')")
        #expect(pasted("O'Brien\nC:\\tmp", "WHERE x IN (|)", noBackslashEscapes: true) == "WHERE x IN ('O''Brien', 'C:\\tmp')")
    }

    @Test func aListAlreadyWrittenStays() {
        #expect(pasted("'a', 'b'", "WHERE x IN (|)") == "WHERE x IN ('a', 'b')")
        #expect(pasted("'a','b'\n", "WHERE x IN (|)") == "WHERE x IN ('a','b')")
        #expect(pasted("'a',\n'b',\n", "WHERE x IN (|)") == "WHERE x IN ('a',\n'b')")
        #expect(pasted("\"a\", 7", "WHERE x IN (|)") == "WHERE x IN (\"a\", 7)")
        #expect(pasted("'a'\n'b'", "WHERE x IN (|)") == "WHERE x IN ('a', 'b')", "each line quoted, no commas")
        #expect(pasted("1,2,\n3", "WHERE x IN (|)") == "WHERE x IN ('1', '2', '3')", "numbers aren't quoted yet")
        #expect(pasted("'a' = 'b'", "WHERE x IN (|)") == nil, "not a list: one value")
    }

    @Test func oneValueOrAQueryPastesAsItIs() {
        #expect(pasted("a", "WHERE x IN (|)") == nil)
        #expect(pasted("a\n", "WHERE x IN (|)") == nil)
        #expect(pasted("", "WHERE x IN (|)") == nil)
        #expect(pasted("\n\n", "WHERE x IN (|)") == nil)
        #expect(pasted("SELECT id\nFROM t", "WHERE x IN (|)") == nil)
        #expect(pasted("with c as (select 1)\nselect * from c", "WHERE x IN (|)") == nil)
    }

    @Test func onlyTheBracketsOfAnInCount() {
        #expect(pasted(list, "SELECT |") == nil)
        #expect(pasted(list, "WHERE x = (|)") == nil)
        #expect(pasted(list, "WHERE x IN |()") == nil)
        #expect(pasted(list, "WHERE x IN ()|") == nil)
        #expect(pasted(list, "WHERE x IN (LOWER(|))") == nil, "a call's brackets")
        #expect(pasted(list, "WHERE x IN (SELECT id FROM t WHERE |)") == nil, "a subquery")
        #expect(pasted(list, "SELECT 'x IN (|)'") == nil, "a string")
        #expect(pasted(list, "-- x IN (|)") == nil, "a comment")
        #expect(pasted(list, "/* x IN (|) */") == nil)
        #expect(pasted(list, "`x IN (|)`") == nil)
        #expect(pasted(list, "WHERE x IN ('a|b')") == nil, "inside a value")
        #expect(pasted(list, "WHERE x IN (12|34)") == nil)
        #expect(pasted(list, "WHERE x IN ('open|") == nil, "a string left open")
        #expect(pasted(list, "WHERE x IN (1 -- note|\n)") == nil, "the end of a line comment")
        #expect(pasted(list, "WHERE x /* IN */ (|)") == nil, "a comment's IN")
        #expect(pasted(list, "WHERE x IN (1); SELECT (|)") == nil)
        #expect(pasted(list, "WHERE x IN (1; SELECT (|)") == nil, "the bracket ended with its statement")
        #expect(pasted(list, "WHERE x IN (1; SELECT |") == nil)
        #expect(pasted(list, "a IN (|1), b IN (2|)") == nil, "a selection across two lists")
    }

    @Test func anUnclosedBracketCounts() {
        #expect(pasted(list, "WHERE x IN (|") == "WHERE x IN ('a', 'b', 'c'")
        #expect(pasted(list, "WHERE x IN (|\nORDER BY y") == "WHERE x IN ('a', 'b', 'c'\nORDER BY y")
        #expect(pasted(list, "WHERE x IN (|; SELECT 2") == "WHERE x IN ('a', 'b', 'c'; SELECT 2")
    }

    @Test func commasJoinWhatTheBracketsHold() {
        #expect(pasted(list, "x IN ('z'|)") == "x IN ('z', 'a', 'b', 'c')")
        #expect(pasted(list, "x IN ('z' |)") == "x IN ('z', 'a', 'b', 'c')", "no space before the comma")
        #expect(pasted(list, "x IN ('z',|)") == "x IN ('z', 'a', 'b', 'c')")
        #expect(pasted(list, "x IN ('z', |)") == "x IN ('z', 'a', 'b', 'c')")
        #expect(pasted(list, "x IN (|'z')") == "x IN ('a', 'b', 'c', 'z')")
        #expect(pasted(list, "x IN (| 'z')") == "x IN ('a', 'b', 'c', 'z')")
        #expect(pasted(list, "x IN (|, 'z')") == "x IN ('a', 'b', 'c', 'z')")
        #expect(pasted(list, "x IN ('y', |'z')") == "x IN ('y', 'a', 'b', 'c', 'z')")
        #expect(pasted(list, "x IN ('y' -- first\n|)") == "x IN ('y' -- first\n, 'a', 'b', 'c')", "the comma stays out of the comment")
        #expect(pasted(list, "x IN (|'y', 'z'|)") == "x IN ('a', 'b', 'c')", "a selection goes")
        #expect(pasted(list, "x IN ('y', |'z'|)") == "x IN ('y', 'a', 'b', 'c')")
        #expect(pasted(list, "x IN (LOWER('y')|)") == "x IN (LOWER('y'), 'a', 'b', 'c')")
    }

    @Test func numbersStayBareOnlyOnANumberColumn() {
        var snapshot = SQLNameCheckTests.snapshot()
        var text = snapshot.databases[0].tables[1].columns[0]
        text.name = "code"
        text.dataType = "varchar"
        snapshot.databases[0].tables[1].columns.append(text)  // customers: id, name (int), code
        let numbers = "1\n2.5\n-3"
        func on(_ sql: String) -> String? { pasted(numbers, sql, snapshot: snapshot) }
        #expect(on("SELECT 1 FROM orders WHERE id IN (|)") == "SELECT 1 FROM orders WHERE id IN (1, 2.5, -3)")
        #expect(on("SELECT 1 FROM orders o WHERE o.id NOT IN (|)") == "SELECT 1 FROM orders o WHERE o.id NOT IN (1, 2.5, -3)")
        #expect(on("SELECT 1 FROM customers WHERE `code` IN (|)") == "SELECT 1 FROM customers WHERE `code` IN ('1', '2.5', '-3')")
        #expect(on("SELECT 1 FROM customers c WHERE c.code IN (|)") == "SELECT 1 FROM customers c WHERE c.code IN ('1', '2.5', '-3')")
        #expect(on("SELECT 1 FROM nosuch WHERE id IN (|)") == "SELECT 1 FROM nosuch WHERE id IN ('1', '2.5', '-3')")
        #expect(on("SELECT 1 FROM orders WHERE LOWER(id) IN (|)") == "SELECT 1 FROM orders WHERE LOWER(id) IN ('1', '2.5', '-3')")
        #expect(on("SELECT 1 FROM orders o JOIN customers c WHERE z.id IN (|)") == "SELECT 1 FROM orders o JOIN customers c WHERE z.id IN ('1', '2.5', '-3')")
        #expect(pasted("1\nabc\n007", "SELECT 1 FROM orders WHERE id IN (|)", snapshot: snapshot) == "SELECT 1 FROM orders WHERE id IN (1, 'abc', '007')")
        #expect(pasted("1,2", "SELECT 1 FROM orders WHERE id IN (|)", snapshot: snapshot) == "SELECT 1 FROM orders WHERE id IN (1, 2)")
        // A name in two tables is a number only when it is one in both.
        snapshot.databases[0].tables[1].columns[0].dataType = "varchar"
        #expect(on("SELECT 1 FROM orders o JOIN customers c WHERE id IN (|)")?.hasSuffix("('1', '2.5', '-3')") == true)
    }
}
