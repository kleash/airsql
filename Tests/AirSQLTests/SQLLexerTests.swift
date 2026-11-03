import AirSQLCore
import Foundation
import Testing

/// "kind text" for each token: the readable form of the lexer's output.
func lexed(_ sql: String, noBackslashEscapes: Bool = false) -> [String] {
    let ns = sql as NSString
    return SQLLexer.tokens(sql, noBackslashEscapes: noBackslashEscapes).map {
        "\($0.kind) \(ns.substring(with: NSRange($0.range)))" + ($0.isClosed ? "" : " (open)")
    }
}

struct SQLLexerTests {
    @Test func wordsSymbolsAndNumbers() {
        #expect(lexed("SELECT a, b FROM t WHERE x >= 1.5;") == [
            "word SELECT", "word a", "symbol ,", "word b", "word FROM", "word t", "word WHERE", "word x", "symbol >=",
            "number 1.5", "symbol ;",
        ])
    }

    @Test(arguments: [
        ("0x1F", "number"), ("X'1F'", "number"), ("x'1f'", "number"), ("b'101'", "number"), ("0b101", "number"),
        ("12", "number"), ("1.5", "number"), (".5", "number"), ("1.", "number"), ("1e5", "number"), ("1E-5", "number"),
        ("1.5e+3", "number"), ("5abc", "word"), ("0x1G", "word"), ("0X1F", "word"), ("1ex", "word"), ("0b12", "word"),
        ("12_3", "word"), ("$x", "word"), ("_utf8mb4", "word"),
    ])
    func numbersAndNamesThatStartLikeNumbers(sql: String, kind: String) {
        #expect(lexed(sql) == ["\(kind) \(sql)"])
    }

    @Test func partAfterNameDotIsAName() {
        #expect(lexed("t.1e5") == ["word t", "symbol .", "word 1e5"])
        #expect(lexed("db.5f(1)") == ["word db", "symbol .", "word 5f", "symbol (", "number 1", "symbol )"])
        #expect(lexed("`t`.5") == ["quotedName `t`", "symbol .", "word 5"])
        #expect(lexed("t .5") == ["word t", "number .5"])
        #expect(lexed("t.*") == ["word t", "symbol .", "symbol *"])
    }

    @Test func quotedNamesDoubleTheirBackticks() {
        #expect(lexed("`a``b` `c\\`") == ["quotedName `a``b`", "quotedName `c\\`"])
        #expect(lexed("`abc") == ["quotedName `abc (open)"])
    }

    @Test func stringsInBothQuotes() {
        #expect(lexed(#"'it''s' "say ""hi""" N'n' _utf8mb4'u'"#) == [
            "string 'it''s'", #"string "say ""hi""""#, "string N'n'", "word _utf8mb4", "string 'u'",
        ])
        #expect(lexed("'abc") == ["string 'abc (open)"])
    }

    @Test func backslashEscapesFollowTheMode() {
        #expect(lexed(#"'a\'c' x"#) == [#"string 'a\'c'"#, "word x"])
        #expect(lexed(#"'a\'c' x"#, noBackslashEscapes: true) == [#"string 'a\'"#, "word c", "string ' x (open)"])
        #expect(lexed(#"'a\'b' x"#, noBackslashEscapes: true) == [#"string 'a\'"#, "number b' x (open)"])
        #expect(lexed(#""a\"b""#, noBackslashEscapes: true) == [#"string "a\""#, "word b", #"string " (open)"#])
        // An even run of backslashes ends the same way in both modes.
        #expect(lexed(#"'C:\\' x"#) == lexed(#"'C:\\' x"#, noBackslashEscapes: true))
    }

    @Test func operators() {
        #expect(lexed("a<=>b<=c>=d<>e!=f:=g||h&&i->j->>k<<l>>m") == [
            "word a", "symbol <=>", "word b", "symbol <=", "word c", "symbol >=", "word d", "symbol <>", "word e",
            "symbol !=", "word f", "symbol :=", "word g", "symbol ||", "word h", "symbol &&", "word i", "symbol ->",
            "word j", "symbol ->>", "word k", "symbol <<", "word l", "symbol >>", "word m",
        ])
    }

    @Test func dashDashNeedsSpaceOrControlCharacter() {
        #expect(lexed("1--1") == ["number 1", "symbol -", "symbol -", "number 1"])
        #expect(lexed("1 --x\n2") == ["number 1", "symbol -", "symbol -", "word x", "number 2"])
        #expect(lexed("1 -- x\n2") == ["number 1", "comment -- x", "number 2"])
        #expect(lexed("1 --\tx\n2") == ["number 1", "comment --\tx", "number 2"])
        #expect(lexed("1 --") == ["number 1", "comment --"])
    }

    @Test func lineCommentsEndAtLineFeedOnly() {
        #expect(lexed("1 # x\n2") == ["number 1", "comment # x", "number 2"])
        #expect(lexed("1 # x\r2") == ["number 1", "comment # x\r2"])
    }

    @Test func blockCommentsAndHints() {
        #expect(lexed("1 /* a ; */ 2 /**/") == ["number 1", "comment /* a ; */", "number 2", "comment /**/"])
        #expect(lexed("SELECT /*+ BKA(t) */ 1") == ["word SELECT", "hint /*+ BKA(t) */", "number 1"])
        #expect(lexed("/* /* */ x") == ["comment /* /* */", "word x"])
        #expect(lexed("1 /* a") == ["number 1", "comment /* a (open)"])
        #expect(lexed("2*/3") == ["number 2", "symbol *", "symbol /", "number 3"])
    }

    @Test func executableCommentsAreCode() {
        #expect(lexed("/*!50003 CREATE*/") == ["codeStart /*!50003", "word CREATE", "codeEnd */"])
        #expect(lexed("/*M!100100 SELECT 1 */") == ["codeStart /*M!100100", "word SELECT", "number 1", "codeEnd */"])
        #expect(lexed("/*! x */") == ["codeStart /*!", "word x", "codeEnd */"])
        #expect(lexed("/*!123 x */") == ["codeStart /*!", "number 123", "word x", "codeEnd */"])
        #expect(lexed("/*!50000 a /* b */ c */") == [
            "codeStart /*!50000", "word a", "comment /* b */", "word c", "codeEnd */",
        ])
        // A */ inside a string inside the comment would put the comment's end in one place for a server that runs the
        // body as code and another for a server that skips the whole comment. No real statement does this, so the
        // lexer reads the whole thing as the skippable comment it is to a server over the gate (R4): the quote can't
        // swallow a */ and hide code after it.
        #expect(lexed("/*!50000 '*/' */") == ["comment /*!50000 '*/", "string ' */ (open)"])
        #expect(lexed("/*!99999 ' */ DROP TABLE t -- '") == [
            "comment /*!99999 ' */", "word DROP", "word TABLE", "word t", "comment -- '",
        ])
    }

    @Test func variables() {
        #expect(lexed("@a @a.b @'x y' @@global.sql_mode @@version @`q`") == [
            "variable @a", "variable @a.b", "variable @'x y'", "variable @@global.sql_mode", "variable @@version",
            "variable @`q`",
        ])
    }

    @Test func rangesCountUTF16() {
        let sql = "SELECT 'é😀', ünï FROM t"
        let tokens = SQLLexer.tokens(sql)
        #expect(tokens.map(\.range) == [0..<6, 7..<12, 12..<13, 14..<17, 18..<22, 23..<24])
        #expect(lexed("SLEEP\u{A0}(1)") == ["word SLEEP\u{A0}", "symbol (", "number 1", "symbol )"])
    }
}
