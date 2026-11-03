import Testing
@testable import AirSQLCore

/// The session facts each flavour's default sql_mode gives (MySQL 8.4 and MariaDB 11.8, as the lab's servers run).
enum EditContexts {
    static let mysql = EditContext(flavour: .mysql, version: [8, 4, 13], sqlMode:
        "ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION")
    static let mariadb = EditContext(flavour: .mariadb, version: [11, 8, 9], sqlMode:
        "STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION")

    /// A column type from its COLUMN_TYPE: "decimal(10,2)" has DATA_TYPE "decimal".
    static func type(_ definition: String, charset: String? = nil, json: Bool = false) -> ColumnType {
        let base = definition.prefix { $0 != "(" && $0 != " " }
        return ColumnType(dataType: String(base), columnType: definition, isJSON: json, charset: charset)
    }

    /// The literal, or "!" and the error's message.
    static func result(_ type: ColumnType, _ text: String, _ context: EditContext = mysql) -> String {
        do { return try type.literal(text, context) } catch { return "!" + ((error as? EditError)?.message ?? "\(error)") }
    }
}

struct GridEditValueTests {
    typealias C = EditContexts

    /// The fixture's columns as each flavour describes them become the same editing types (MariaDB's JSON included).
    @Test(arguments: [SchemaFixtures.mariadb118, SchemaFixtures.mysql84])
    func columnTypesFromEitherFlavour(_ recording: String) async throws {
        let (cache, _) = try await SchemaTests.loaded(recording)
        let customers = try #require(cache.snapshot.table("airsql_fixture", "customers"))
        func kind(_ name: String) -> ColumnType.Kind? { customers.column(name).map { ColumnType($0).kind } }
        #expect(kind("id") == .integer(bytes: 4) && customers.column("id").map { ColumnType($0).unsigned } == true)
        #expect(kind("status") == .enumeration(["new", "active", "gone"]))
        #expect(kind("flags") == .set(["a", "b"]))
        #expect(kind("balance") == .decimal(precision: 10, scale: 2))
        #expect(kind("bits") == .bit(width: 3))
        #expect(kind("created") == .timestamp(fraction: 0))
        #expect(kind("updated") == .datetime(fraction: 3))
        #expect(kind("prefs") == .json)
        #expect(kind("token") == .text(characters: 36, bytes: nil))
        #expect(kind("note") == .text(characters: nil, bytes: 65_535))
        #expect(customers.column("email").flatMap { ColumnType($0).charset } == "utf8mb4")
        let lines = try #require(cache.snapshot.table("airsql_fixture", "order_lines"))
        #expect(lines.column("line").map { ColumnType($0).kind } == .integer(bytes: 2))
    }

    /// Golden cases: the column type, what is typed, and the literal (or "!" and part of the error).
    static let numbers: [(String, String, String)] = [
        ("int(11)", "42", "42"), ("int(11)", " 42 ", "42"), ("int(11)", "+0042", "42"), ("int(11)", "-0", "0"),
        ("int(11)", "-2147483648", "-2147483648"), ("int(11)", "2147483647", "2147483647"),
        ("int(11)", "2147483648", "!int(11) holds -2147483648 to 2147483647"), ("int(11)", "12.00", "12"),
        ("int(11)", "12.5", "!holds whole numbers"), ("int(11)", "1e3", "!holds whole numbers"),
        ("int(11)", "1,000", "!holds whole numbers"), ("int(11)", "", "!holds whole numbers"),
        ("int unsigned", "4294967295", "4294967295"), ("int unsigned", "-1", "!holds 0 to 4294967295"),
        ("tinyint(4)", "-128", "-128"), ("tinyint(4)", "128", "!holds -128 to 127"), ("mediumint unsigned", "16777215", "16777215"),
        ("bigint unsigned", "18446744073709551615", "18446744073709551615"),
        ("bigint unsigned", "18446744073709551616", "!holds 0 to 18446744073709551615"),
        ("bigint", "-9223372036854775808", "-9223372036854775808"), ("tinyint(1)", "TRUE", "1"), ("tinyint(1)", "false", "0"),
        ("tinyint", "true", "!holds whole numbers"),
        ("decimal(10,2)", "1234.56", "1234.56"), ("decimal(10,2)", "00012.30", "12.30"), ("decimal(10,2)", "-0.5", "-0.5"),
        ("decimal(10,2)", "12.3400", "12.34"), ("decimal(10,2)", ".5", "0.5"), ("decimal(10,2)", "-0.00", "0.00"),
        ("decimal(10,2)", "99999999.99", "99999999.99"), ("decimal(10,2)", "12.345", "!keeps 2 digits after the point"),
        ("decimal(10,2)", "123456789.1", "!at most 8 digits before the point"), ("decimal(10,2)", "1.5e3", "!no exponent"),
        ("decimal(10,2)", "1,234.56", "!no grouping"), ("decimal(10,2) unsigned", "-1", "!no negative numbers"),
        ("decimal(5,0)", "12.0", "12"), ("decimal(38,10)", "1234567890123456789012345678.0123456789",
                                         "1234567890123456789012345678.0123456789"),
        ("double", "1.5", "1.5"), ("double", "+2.5e-3", "2.5e-3"), ("double", ".5", ".5"), ("double", "-5.", "-5."),
        ("double", "1e400", "!holds numbers such as"), ("float", "1e39", "!holds numbers such as"), ("float", "1e38", "1e38"),
        ("double", "nan", "!holds numbers such as"), ("double", "0x1p3", "!holds numbers such as"), ("double", "1e", "!holds"),
        ("double unsigned", "-1", "!no negative numbers"),
    ]

    @Test func numbersStayExactAndInRange() {
        for (definition, text, expected) in Self.numbers {
            let result = C.result(C.type(definition), text)
            #expect(expected.hasPrefix("!") ? result.contains(expected.dropFirst()) : result == expected, "\(definition) ← \(text)")
        }
    }

    static let bitsAndBytes: [(String, String, String)] = [
        ("bit(3)", "101", "b'101'"), ("bit(3)", "0101", "b'101'"), ("bit(3)", "b'11'", "b'11'"), ("bit(3)", "0b1", "b'1'"),
        ("bit(3)", "000", "b'0'"), ("bit(3)", "1000", "!up to 3 binary digits"), ("bit(3)", "2", "!up to 3 binary digits"),
        ("bit(1)", "true", "b'1'"), ("bit(64)", String(repeating: "1", count: 64), "b'" + String(repeating: "1", count: 64) + "'"),
        ("bit(64)", "1" + String(repeating: "0", count: 64), "!up to 64 binary digits"),
        ("varbinary(4)", "0x00FF", "X'00FF'"), ("varbinary(4)", "X'00ff'", "X'00FF'"), ("varbinary(4)", "00 ff 10", "X'00FF10'"),
        ("varbinary(4)", "", "X''"), ("varbinary(4)", "0x0", "!two per byte"), ("varbinary(4)", "0xGG", "!two per byte"),
        ("varbinary(4)", "0x0102030405", "!at most 4 bytes; this is 5"), ("binary(16)", "0x" + String(repeating: "AB", count: 16),
                                                                          "X'" + String(repeating: "AB", count: 16) + "'"),
        ("blob", "'; DROP TABLE t; --", "!two per byte"),
    ]

    @Test func bitsInFullAndBytesAsHex() {
        for (definition, text, expected) in Self.bitsAndBytes {
            let result = C.result(C.type(definition), text)
            #expect(expected.hasPrefix("!") ? result.contains(expected.dropFirst()) : result == expected, "\(definition) ← \(text)")
        }
        // Every bit of a wide BIT shows and edits (HeidiSQL #56 showed 8).
        #expect(C.type("bit(64)").editorText(stored: Array(repeating: 0xFF, count: 8)) == String(repeating: "1", count: 64))
        #expect(C.type("bit(10)").editorText(stored: [0x02, 0x05]) == "1000000101")
        #expect(C.type("bit(3)").editorText(stored: [0x05]) == "101")
        #expect(C.type("varbinary(300)").editorText(stored: Array(repeating: 0xAB, count: 300)).count == 602)
        #expect(C.type("blob").editorText(stored: [0x00, 0x7F]) == "0x007F")
    }

    @Test func textFitsItsLengthAndCharacterSet() {
        #expect(C.result(C.type("varchar(5)", charset: "utf8mb4"), "naïve") == "'naïve'")
        #expect(C.result(C.type("varchar(5)", charset: "utf8mb4"), "naïves").contains("holds 5 characters; this is 6"))
        #expect(C.result(C.type("varchar(1)", charset: "utf8mb4"), "😀") == "'😀'")
        #expect(C.result(C.type("varchar(9)", charset: "utf8mb3"), "a😀").contains("(utf8mb3) has no 😀 (U+1F600)"))
        #expect(C.result(C.type("varchar(9)", charset: "latin1"), "café €") == "'café €'")
        #expect(C.result(C.type("varchar(9)", charset: "latin1"), "中").contains("(latin1) has no 中"))
        #expect(C.result(C.type("varchar(9)", charset: "ascii"), "é").contains("(ascii) has no é"))
        #expect(C.result(C.type("tinytext", charset: "utf8mb4"), String(repeating: "é", count: 128)).contains("holds 255 bytes; this is 256"))
        #expect(C.result(C.type("tinytext", charset: "latin1"), String(repeating: "é", count: 255)).hasPrefix("'"))
        #expect(C.result(C.type("text", charset: "utf8mb4"), "") == "''")
        #expect(C.result(C.type("text", charset: "utf8mb4"), "  keep spaces\n") == "'  keep spaces\\n'")
        for value in Hostile.values {
            #expect(C.result(C.type("longtext", charset: "utf8mb4"), value) == SQLQuote.string(value))
            #expect(C.result(C.type("longtext", charset: "utf8mb4"), value, C.withMode("NO_BACKSLASH_ESCAPES"))
                == SQLQuote.string(value, noBackslashEscapes: true))
        }
    }

    @Test func enumAndSetTakeTheColumnsOwnMembers() {
        // As the lab's MariaDB 11.4 and MySQL 8.4 write them: a quote or a backslash twice, a tab as it is.
        #expect(ColumnType.members("enum('a','it''s','b,c','','x\\\\y','b\"c','t\tb')")
            == ["a", "it's", "b,c", "", "x\\y", "b\"c", "t\tb"])
        let status = C.type("enum('new','active','gone')")
        #expect(C.result(status, "active") == "'active'")
        #expect(C.result(status, "ACTIVE") == "'active'")
        #expect(C.result(status, "x") == "!Choose one of “new”, “active”, “gone”")
        #expect(C.result(C.type("enum('it''s')"), "it's") == "'it\\'s'")
        let flags = C.type("set('a','b','c')")
        #expect(C.result(flags, "c, a") == "'a,c'")
        #expect(C.result(flags, "B,b") == "'b'")
        #expect(C.result(flags, "") == "''")
        #expect(C.result(flags, "a,d") == "!“d” isn't one of “a”, “b”, “c”")
        #expect(flags.setText(["c", "A"]) == "a,c")
    }

    @Test func jsonIsCheckedAndLaidOutWithoutChangingValues() throws {
        let escape = "\\" + "u00E9"  // a JSON escape, kept as typed
        let text = #"{"a":[1,2.50,12345678901234567890123],"b":{},"c":[],"d":"x\"y"# + escape + #""}"#
        let pretty = try JSONText.pretty(text)
        #expect(pretty == """
            {
              "a": [
                1,
                2.50,
                12345678901234567890123
              ],
              "b": {},
              "c": [],
              "d": "x\\"y\(escape)"
            }
            """)
        #expect(try JSONText.compact(#"[ ""# + escape + #"" ]"#) == #"[""# + escape + #""]"#)
        #expect(C.result(C.type("json", json: true), #"["\"# + "u12" + #""]"#).contains("four hex digits"))
        #expect(try JSONText.compact(pretty) == text)
        #expect(try JSONText.compact(" [ true , false , null , -0.5e+3 ] ") == "[true,false,null,-0.5e+3]")
        #expect(try JSONText.compact(#""scalar""#) == #""scalar""#)
        let problems: [(String, String)] = [
            (#"{"a":1,}"#, "line 1, column 8: Expected a key in double quotes"), ("[1 2]", "line 1, column 4: Expected , or ]"),
            ("", "It's empty"), ("01", "can't start with 0"), (#"{"a":1} x"#, "Nothing may follow"), ("{\n  \"a\" 1}", "line 2, column 7: Expected :"),
            (#"["x]"#, "line 1, column 2: A string isn't closed"), ("[\"a\tb\"]", "raw line break"), (#"["\q"]"#, "Unknown escape \\q"),
            ("tru", "Expected a value"), ("[1.]", "digits after it"), (String(repeating: "[", count: 101), "deeper than 100"),
        ]
        for (text, message) in problems {
            #expect(C.result(C.type("json", json: true), text).contains(message), "\(text)")
        }
        // As deep as each server takes (the lab's MariaDB 11.4 and 11.8 refuse 32 levels, MySQL 8.4 101).
        let deep = { (levels: Int) in String(repeating: "[", count: levels) + String(repeating: "]", count: levels) }
        #expect(C.result(C.type("json", json: true), deep(100)).hasPrefix("'"))
        #expect(C.result(C.type("json", json: true), deep(31), C.mariadb).hasPrefix("'"))
        #expect(C.result(C.type("json", json: true), deep(32), C.mariadb).contains("deeper than 31 levels"))
        // MariaDB's JSON is LONGTEXT with a JSON_VALID check: checked the same way.
        #expect(C.result(C.type("longtext", charset: "utf8mb4", json: true), #"{"a": 1}"#, C.mariadb) == #"'{\"a\": 1}'"#)
    }

    /// Golden dates and times: the type, what is typed, then the literal on MySQL 8.4 and on MariaDB 11.8 with their
    /// default sql_mode (MySQL's refuses zero dates and zero parts, MariaDB's keeps them as typed).
    static let dates: [(String, String, String, String)] = [
        ("date", "2026-11-03", "'2026-11-03'", "'2026-11-03'"), ("date", " 2026-1-3 ", "'2026-01-03'", "'2026-01-03'"),
        ("date", "0000-00-00", "!(NO_ZERO_DATE) refuses the zero date", "'0000-00-00'"),
        ("date", "2026-00-10", "!(NO_ZERO_IN_DATE) refuses a 0 month or day", "'2026-00-10'"),
        ("date", "2026-02-29", "!February 2026 has 28 days", "!February 2026 has 28 days"),
        ("date", "2024-02-29", "'2024-02-29'", "'2024-02-29'"), ("date", "2026-13-01", "!Months run", "!Months run"),
        ("date", "", "!Type the date as YYYY-MM-DD", "!Type the date as YYYY-MM-DD"),
        ("date", "03/11/2026", "!Type the date as YYYY-MM-DD", "!Type the date as YYYY-MM-DD"),
        ("time", "838:59:59", "'838:59:59'", "'838:59:59'"), ("time", "-838:59:59", "'-838:59:59'", "'-838:59:59'"),
        ("time", "839:00:00", "!TIME holds -838:59:59 to 838:59:59", "!TIME holds"), ("time", "1 02:03:04", "'26:03:04'", "'26:03:04'"),
        ("time", "12:34", "'12:34:00'", "'12:34:00'"), ("time", "-00:00:00", "'00:00:00'", "'00:00:00'"),
        ("time", "12:60:00", "!Minutes and seconds run", "!Minutes and seconds run"),
        ("time", "12:00:00.5", "!keeps whole seconds", "!keeps whole seconds"), ("time", "12:00:00.000", "'12:00:00'", "'12:00:00'"),
        ("time(6)", "-12:00:00.123456", "'-12:00:00.123456'", "'-12:00:00.123456'"), ("time", "noon", "!Type the time", "!Type the time"),
        ("datetime(3)", "2026-11-03 14:05:06.123", "'2026-11-03 14:05:06.123'", "'2026-11-03 14:05:06.123'"),
        ("datetime(3)", "2026-11-03T14:05:06.1", "'2026-11-03 14:05:06.1'", "'2026-11-03 14:05:06.1'"),
        ("datetime(3)", "2026-11-03 14:05:06.1234", "!keeps 3 digits after the seconds", "!keeps 3 digits"),
        ("datetime(3)", "2026-11-03 14:05:06.1230", "'2026-11-03 14:05:06.123'", "'2026-11-03 14:05:06.123'"),
        ("datetime", "2026-11-03", "'2026-11-03 00:00:00'", "'2026-11-03 00:00:00'"),
        ("datetime", "2026-11-03 9:05", "'2026-11-03 09:05:00'", "'2026-11-03 09:05:00'"),
        ("datetime", "2026-11-03 24:00:00", "!runs from 00:00:00 to 23:59:59", "!runs from 00:00:00"),
        ("datetime", "2026-11-03 14:05:06+02:00", "!Type the date and time", "!Type the date and time"),
        ("datetime", "0000-00-00 00:00:00", "!(NO_ZERO_DATE)", "'0000-00-00 00:00:00'"),
        ("timestamp", "1969-12-31 23:59:59", "!TIMESTAMP holds dates from 1970 to 2038", "!TIMESTAMP holds dates from 1970 to 2106"),
        ("timestamp", "2040-01-01 00:00:00", "!TIMESTAMP holds dates from 1970 to 2038", "'2040-01-01 00:00:00'"),
        ("timestamp", "0000-00-00 00:00:00", "!(NO_ZERO_DATE)", "'0000-00-00 00:00:00'"),
        ("timestamp", "2026-00-10 00:00:00", "!(NO_ZERO_IN_DATE)", "!TIMESTAMP has no 0 month or day"),
        ("timestamp(6)", "2026-11-03 14:05:06.000001", "'2026-11-03 14:05:06.000001'", "'2026-11-03 14:05:06.000001'"),
        ("year", "2024", "2024", "2024"), ("year", "0000", "0", "0"), ("year", "0", "0", "0"), ("year", "99", "!YEAR holds four digits", "!YEAR"),
        ("year", "1900", "!YEAR holds", "!YEAR holds"),
    ]

    @Test func datesFollowTheSessionsSQLMode() {
        for (definition, text, mysql, mariadb) in Self.dates {
            for (context, expected) in [(C.mysql, mysql), (C.mariadb, mariadb)] {
                let result = C.result(C.type(definition), text, context)
                #expect(expected.hasPrefix("!") ? result.contains(expected.dropFirst()) : result == expected,
                        "\(definition) ← \(text) on \(context.flavour): \(result)")
            }
        }
        // ALLOW_INVALID_DATES takes any day 1–31 in DATE and DATETIME, never in TIMESTAMP; MariaDB before 11.5 stops at 2038.
        let loose = C.withMode("ALLOW_INVALID_DATES")
        #expect(C.result(C.type("date"), "2026-02-31", loose) == "'2026-02-31'")
        #expect(C.result(C.type("timestamp"), "2026-02-31 00:00:00", loose).contains("February 2026 has 28 days"))
        let mariadb114 = EditContext(flavour: .mariadb, version: [11, 4, 13], sqlMode: "")
        #expect(C.result(C.type("timestamp"), "2040-01-01 00:00:00", mariadb114).contains("from 1970 to 2038"))
        // Zero dates without strict mode are kept: the server warns but saves them as typed.
        #expect(C.result(C.type("date"), "0000-00-00", C.withMode("NO_ZERO_DATE")) == "'0000-00-00'")
        #expect(C.mysql.timeZoneNote.contains("the server's own time zone"))
        #expect(EditContext(flavour: .mysql, version: [8], sqlMode: "", timeZone: "+02:00").timeZoneNote.contains("(+02:00)"))
    }

    /// A NULL cell passed through stays NULL: its editor starts empty, and empty is no date (never NOW(), t=9771).
    @Test func nullCellsStartEmptyAndNeverBecomeNow() {
        for definition in ["date", "time", "datetime(6)", "timestamp", "year", "int", "decimal(5,2)", "bit(8)", "blob",
                           "varchar(10)", "json", "enum('a')", "set('a')"] {
            #expect(C.type(definition).editorText(stored: nil) == "")
        }
        for definition in ["date", "time", "datetime(6)", "timestamp", "year", "int", "decimal(5,2)", "bit(8)", "json", "enum('a')"] {
            let result = C.result(C.type(definition, json: definition == "json"), "")
            #expect(result.hasPrefix("!") && !result.uppercased().contains("NOW()"), "\(definition): \(result)")
        }
    }

    @Test func storedValuesBecomeExactLiterals() {
        let context = C.mysql
        #expect(C.type("int").literal(stored: Array("42".utf8), context) == "42")
        #expect(C.type("decimal(5,2)").literal(stored: Array("-1.50".utf8), context) == "-1.50")
        #expect(C.type("varchar(9)").literal(stored: Array("it's".utf8), context) == "'it\\'s'")
        #expect(C.type("varchar(9)").literal(stored: Array("it's".utf8), C.withMode("NO_BACKSLASH_ESCAPES")) == "'it''s'")
        #expect(C.type("binary(2)").literal(stored: [0x00, 0xFF], context) == "X'00FF'")
        #expect(C.type("bit(3)").literal(stored: [0x05], context) == "b'101'")
        #expect(C.type("bit(64)").literal(stored: Array(repeating: 0xFF, count: 8), context) == SQLQuote.bits(.max))
        #expect(C.type("int").literal(stored: nil, context) == "NULL")
        #expect(C.type("int").literal(stored: Array("1; DROP".utf8), context) == "'1; DROP'")
        #expect(C.type("date").literal(stored: Array("2026-11-03".utf8), context) == "'2026-11-03'")
    }
}

extension EditContexts {
    /// MySQL 8.4 with another sql_mode.
    static func withMode(_ mode: String) -> EditContext { EditContext(flavour: .mysql, version: [8, 4, 13], sqlMode: mode) }
}
