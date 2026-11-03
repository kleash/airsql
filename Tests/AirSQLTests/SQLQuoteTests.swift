import AirSQLCore
import Testing

/// Names and values that try to break out of their quotes, for every quoting test (and `DBLabTests`, which sends them
/// through real servers).
enum Hostile {
    static let values = [
        "", "plain", "it's", "''", "\\", "\\'", "'\\", "a\\", "\\\\'", "\"", "`", "``", "x`; DROP TABLE t; --",
        "'; DROP TABLE users; --", "\\'; DROP TABLE users; --", "' OR '1'='1", "\u{0}", "a\u{0}b", "\n", "\r\n", "\t",
        "\u{1A}", "%_", "/* comment */", "*/", "-- ", "#", "😀 émoji ünïcode 中文", "\u{5C}\u{27}", "¥\\'", "\u{2028}",
        String(repeating: "'\\", count: 300), "end with backslash \\",
    ]
    /// Names the servers accept (no NUL, at most 64 characters), still hostile.
    static let names = values.filter { !$0.isEmpty && !$0.contains("\u{0}") && $0.count <= 64 && !$0.hasSuffix(" ") }
}

struct SQLQuoteTests {
    @Test func identifiersDoubleTheirBackticks() {
        #expect(SQLQuote.identifier("orders") == "`orders`")
        #expect(SQLQuote.identifier("my`table") == "`my``table`")
        #expect(SQLQuote.identifier("``") == "``````")
        #expect(SQLQuote.identifier("x`; DROP TABLE t; --") == "`x``; DROP TABLE t; --`")
        #expect(SQLQuote.identifier("shop", "order items", "id`x") == "`shop`.`order items`.`id``x`")
    }

    @Test func unquotedReadsBackWhatIdentifierWrote() {
        for name in Hostile.values { #expect(SQLQuote.unquoted(SQLQuote.identifier(name)) == name) }
        #expect(SQLQuote.unquoted("plain") == "plain" && SQLQuote.unquoted("`") == "`" && SQLQuote.unquoted("'a'") == "'a'")
    }

    @Test func stringsEscapeAsMySQLDoes() {
        #expect(SQLQuote.string("plain") == "'plain'")
        #expect(SQLQuote.string("it's") == "'it\\'s'")
        #expect(SQLQuote.string("\\") == "'\\\\'")
        #expect(SQLQuote.string("\"") == "'\\\"'")
        #expect(SQLQuote.string("a\u{0}b\n\r\u{1A}") == "'a\\0b\\n\\r\\Z'")
        #expect(SQLQuote.string("😀 ü") == "'😀 ü'")
        #expect(SQLQuote.string("") == "''")
    }

    @Test func stringsWithoutBackslashEscapesDoubleQuotesOnly() {
        #expect(SQLQuote.string("it's", noBackslashEscapes: true) == "'it''s'")
        #expect(SQLQuote.string("C:\\dir\\", noBackslashEscapes: true) == "'C:\\dir\\'")
        #expect(SQLQuote.string("\\'", noBackslashEscapes: true) == "'\\'''")
    }

    @Test func hexAndBits() {
        #expect(SQLQuote.hex([]) == "X''")
        #expect(SQLQuote.hex([0x00, 0x7F, 0xFF, 0x27, 0x5C]) == "X'007FFF275C'")
        #expect(SQLQuote.bits(0) == "b'0'")
        #expect(SQLQuote.bits(5) == "b'101'")
        #expect(SQLQuote.bits(.max) == "b'" + String(repeating: "1", count: 64) + "'")
    }

    /// Every hostile value comes back whole from a reader of MySQL's literal syntax, and the literal ends exactly where
    /// the quoted text ends: nothing after it could be read as SQL.
    @Test(arguments: [false, true])
    func hostileValuesStayInsideTheirLiterals(noBackslashEscapes: Bool) throws {
        for value in Hostile.values {
            let quoted = SQLQuote.string(value, noBackslashEscapes: noBackslashEscapes)
            let (read, rest) = try #require(Self.readString(Array(quoted.utf8), noBackslashEscapes: noBackslashEscapes),
                                            "\(quoted)")
            #expect(read == Array(value.utf8), "\(quoted)")
            #expect(rest.isEmpty, "text after the literal: \(quoted)")
        }
        for name in Hostile.values {
            let quoted = Array(SQLQuote.identifier(name).utf8)
            let (read, rest) = try #require(Self.readIdentifier(quoted))
            #expect(read == Array(name.utf8))
            #expect(rest.isEmpty)
        }
    }

    /// The string literal at the start of `sql` as the server reads it (backslash escapes unless NO_BACKSLASH_ESCAPES;
    /// '' always), and what follows it; nil if it never ends.
    static func readString(_ sql: [UInt8], noBackslashEscapes: Bool) -> ([UInt8], ArraySlice<UInt8>)? {
        guard sql.first == UInt8(ascii: "'") else { return nil }
        let escapes: [UInt8: UInt8] = [UInt8(ascii: "0"): 0, UInt8(ascii: "n"): 0x0A, UInt8(ascii: "r"): 0x0D,
                                       UInt8(ascii: "Z"): 0x1A, UInt8(ascii: "t"): 0x09, UInt8(ascii: "b"): 0x08]
        var value: [UInt8] = []
        var i = 1
        while i < sql.count {
            let byte = sql[i]
            if byte == UInt8(ascii: "\\") && !noBackslashEscapes && i + 1 < sql.count {
                value.append(escapes[sql[i + 1]] ?? sql[i + 1])
                i += 2
            } else if byte == UInt8(ascii: "'") {
                if i + 1 < sql.count && sql[i + 1] == UInt8(ascii: "'") {
                    value.append(byte)
                    i += 2
                } else {
                    return (value, sql[(i + 1)...])
                }
            } else {
                value.append(byte)
                i += 1
            }
        }
        return nil
    }

    static func readIdentifier(_ sql: [UInt8]) -> ([UInt8], ArraySlice<UInt8>)? {
        guard sql.first == UInt8(ascii: "`") else { return nil }
        var value: [UInt8] = []
        var i = 1
        while i < sql.count {
            if sql[i] == UInt8(ascii: "`") {
                if i + 1 < sql.count && sql[i + 1] == UInt8(ascii: "`") {
                    value.append(sql[i])
                    i += 2
                } else {
                    return (value, sql[(i + 1)...])
                }
            } else {
                value.append(sql[i])
                i += 1
            }
        }
        return nil
    }
}
