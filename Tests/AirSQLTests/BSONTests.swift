import AirSQLCore
import Foundation
import Testing

private func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var it = s.makeIterator()
    while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
    return out
}

private func oid(_ h: String) -> BSONObjectId { BSONObjectId(hex: h)! }

/// One of every type, nested, with a duplicate key and keys holding `.` and `$`.
private let everyType = BSONDocument([
    ("double", .double(1.5)), ("negZero", .double(-0.0)), ("nan", .double(.nan)), ("inf", .double(-.infinity)),
    ("string", .string("héllo \"q\" \n\u{0} 😀")),
    ("document", .document(BSONDocument([("a", .int32(1)), ("a", .int32(2))]))),
    ("array", .array([.int32(1), .string("x"), .array([]), .document(BSONDocument())])),
    ("binary", .binary(subtype: 0, data: Data([0, 1, 2, 255]))),
    ("uuid", .binary(subtype: 4, data: Data(hex("00112233445566778899aabbccddeeff")))),
    ("oldBinary", .binary(subtype: 2, data: Data([2, 0, 0, 0, 0xAB, 0xCD]))),
    ("user", .binary(subtype: 0x80, data: Data())),
    ("undefined", .undefined), ("oid", .objectId(oid("5f2b1c3d4e5f6a7b8c9d0e1f"))), ("t", .bool(true)), ("f", .bool(false)),
    ("date", .datetime(1_700_000_000_123)), ("oldDate", .datetime(-62_198_755_200_001)), ("null", .null),
    ("regex", .regex(pattern: "^a.*b$", options: "im")), ("regexSlash", .regex(pattern: "a/b\\", options: "x")),
    ("dbPointer", .dbPointer(namespace: "db.c", id: oid("000000000000000000000001"))),
    ("code", .javascript("function() { return 1 }")), ("symbol", .symbol("sym")),
    ("codeWithScope", .javascriptWithScope(code: "x", scope: BSONDocument([("x", .int64(1))]))),
    ("int32", .int32(-2_147_483_648)), ("ts", .timestamp(t: 4_294_967_295, i: 7)), ("int64", .int64(.max)),
    ("smallLong", .int64(-5)), ("decimal", .decimal128(BSONDecimal128("-1.230E-8")!)), ("min", .minKey), ("max", .maxKey),
    ("a.b", .string("dotted")), ("$odd", .null), ("", .string("empty key")),
])

struct BSONTests {
    // MARK: Bytes

    @Test func everyTypeRoundTripsByteForByte() throws {
        let bytes = try everyType.bytes()
        let read = try BSONDocument(bytes: bytes)
        #expect(read == everyType)
        #expect(try read.bytes() == bytes)
        #expect(read.keys == everyType.keys)
        #expect(read.fields.map(\.value.typeByte) == everyType.fields.map(\.value.typeByte))
    }

    @Test func knownBytes() throws {
        #expect(try BSONDocument([("a", .int32(1))]).bytes() == hex("0c0000001061000100000000"))
        #expect(try BSONDocument([("d", .double(-0.0))]).bytes() == hex("10000000016400000000000000008000"))
        #expect(try BSONDocument([("a", .array([.bool(true)]))]).bytes() == hex("1100000004610009000000083000010000"))
        // Timestamp: increment in the low four bytes, seconds in the high four.
        #expect(try BSONDocument([("a", .timestamp(t: 1, i: 2))]).bytes() == hex("100000001161000200000001000000" + "00"))
        let read = try BSONDocument(bytes: hex("10000000016400000000000000008000"))
        guard case .double(let d)? = read["d"] else { Issue.record("not a double"); return }
        #expect(d == 0 && d.sign == .minus)
    }

    @Test func malformedBytesThrow() {
        let good = try! BSONDocument([("s", .string("abc")), ("d", .document(BSONDocument([("x", .int32(1))])))]).bytes()
        let bad: [(String, [UInt8])] = [
            ("empty", []), ("short length", hex("0400000000")), ("too long", hex("0600000000")), ("no terminator", hex("0500000001")),
            ("string length 0", hex("0d000000027300000000000000")),
            ("string length past end", hex("0f000000027300ffffff7f616200" + "00")),
            ("string without NUL", hex("0e00000002730002000000616200")),
            ("bad UTF-8", hex("0e0000000273000200000080" + "0000")),
            ("overlong UTF-8", hex("0f00000002730003000000c08000" + "00")),
            ("UTF-16 surrogate in UTF-8", hex("1000000002730004000000eda08000" + "00")),
            ("boolean 2", hex("090000000862000200")),
            ("unknown type", hex("0800000014610000")),
            ("key without NUL", hex("0a0000001061616161")),
            ("negative binary length", hex("0d000000056200ffffffff0000")),
            ("old binary inner length", hex("13000000056200060000000205000000010200")),
            ("code with scope too short", hex("170000000f63000e00000002000000610005000000" + "0000")),
            ("extra bytes", hex("050000000000")),
            ("truncated double", hex("0b0000000164000000f03f00")),
        ]
        for (name, bytes) in bad {
            #expect(throws: BSONError.self, "\(name)") { try BSONDocument(bytes: bytes) }
        }
        // Every truncation of a good document fails cleanly.
        for n in 0..<good.count {
            #expect(throws: BSONError.self) { try BSONDocument(bytes: good.prefix(n)) }
        }
    }

    @Test func codeWithScopeLengthsMustMatch() throws {
        let good = try BSONDocument([("c", .javascriptWithScope(code: "a", scope: BSONDocument()))]).bytes()
        #expect(try BSONDocument(bytes: good)["c"] != nil)
        var longer = good
        longer[7] += 1  // the code-with-scope total, now one more than its contents
        #expect(throws: BSONError.self) { try BSONDocument(bytes: longer) }
    }

    @Test func randomDamageNeverCrashes() throws {
        let good = try everyType.bytes()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            var bytes = good
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            if let read = try? BSONDocument(bytes: bytes) { #expect(try BSONDocument(bytes: read.bytes()) == read) }
            _ = try? BSONDocument.topLevelKeys(in: bytes)
            _ = try? BSONDocument.value(at: ["document", "a"], in: bytes)
        }
    }

    @Test func deepNestingIsRefused() throws {
        func nested(_ depth: Int) -> BSONDocument {
            var d = BSONDocument()
            for _ in 0..<depth { d = BSONDocument([("a", .document(d))]) }
            return d
        }
        // The deepest document allowed survives every recursive walk on a test's secondary-thread stack.
        let deepest = try BSONDocument(bytes: nested(BSONDocument.maxDepth).bytes())
        #expect(try BSONDocument(shellForm: deepest.shellForm(pretty: true)) == deepest)
        var count = 0
        deepest.walk { _, _ in count += 1 }
        #expect(count == BSONDocument.maxDepth)
        #expect(throws: BSONError.self) { try BSONDocument(bytes: nested(BSONDocument.maxDepth + 1).bytes()) }
        let text = String(repeating: "[", count: 1000) + String(repeating: "]", count: 1000)
        #expect(throws: BSONError.self) { try BSONValue(shellForm: text) }
    }

    @Test func writerRefusesNULInCStrings() {
        #expect(throws: BSONError.self) { try BSONDocument([("a\u{0}b", .null)]).bytes() }
        #expect(throws: BSONError.self) { try BSONDocument([("r", .regex(pattern: "a\u{0}", options: ""))]).bytes() }
        #expect(throws: BSONError.self) { try BSONValue(shellForm: "{\"a\\u0000\": 1}") }
    }

    @Test func peeksWithoutDecodingEverything() throws {
        let bytes = try everyType.bytes()
        #expect(try BSONDocument.topLevelKeys(in: bytes) == everyType.keys)
        #expect(try BSONDocument.value(at: ["document", "a"], in: bytes) == .int32(1))
        #expect(try BSONDocument.value(at: ["array", "1"], in: bytes) == .string("x"))
        #expect(try BSONDocument.value(at: ["array", "9"], in: bytes) == nil)
        #expect(try BSONDocument.value(at: ["string", "x"], in: bytes) == nil)
        #expect(try BSONDocument.value(at: ["a.b"], in: bytes) == .string("dotted"))
    }

    @Test func bigDocumentDecodes() throws {
        let big = BSONDocument((0..<20000).map { ("k\($0)", .string(String(repeating: "x", count: 700))) })
        let bytes = try big.bytes()
        #expect(bytes.count > 14_000_000)
        let read = try BSONDocument(bytes: bytes)
        #expect(read.fields.count == 20000)
        #expect(read.shellForm(maxLength: 40).count == 41)
    }

    // MARK: Decimal128 and doubles

    @Test func decimal128Text() {
        let cases: [(String, String)] = [
            ("0", "0"), ("-0", "-0"), ("1", "1"), ("-1", "-1"), ("1.0", "1.0"), ("1.00", "1.00"), ("0.1", "0.1"),
            ("0.001234", "0.001234"), ("0.0000001234", "1.234E-7"), ("123E+3", "1.23E+5"), ("1E3", "1E+3"),
            ("12345689012345789012345", "12345689012345789012345"), ("-0.00000000", "-0E-8"), ("0E+8000", "0E+6111"),
            ("0E-8000", "0E-6176"), ("1E6112", "1.0E+6112"), ("1.23E+6144", "1.230000000000000000000000000000000E+6144"),
            ("9.999999999999999999999999999999999E+6144", "9.999999999999999999999999999999999E+6144"),
            ("1E-6176", "1E-6176"), ("-1.1111111111111111111111111111123450", "-1.111111111111111111111111111112345"),
            ("+0345678.5432", "345678.5432"), (".5", "0.5"), ("5.", "5"), ("inf", "Infinity"), ("-Infinity", "-Infinity"),
            ("nAn", "NaN"), ("1e+09", "1E+9"), ("10e-11", "1.0E-10"), ("0.000001", "0.000001"), ("0.0000001", "1E-7"),
        ]
        for (text, expected) in cases { #expect(BSONDecimal128(text)?.description == expected, "\(text)") }
        for bad in ["", "e", "1e", ".", "1..2", "1e1.0", " 1", "1 ", "Infi", "NaNq", "1E+6145", "1E-6177", "7e10000",
                    "1.11111111111111111111111111111234549", "1,0", "--1", "0x10", "١"] {
            #expect(BSONDecimal128(bad) == nil, "\(bad)")
        }
        #expect(BSONDecimal128("1E+3") == BSONDecimal128(low: 1, high: 0x3046_0000_0000_0000))
        #expect(BSONDecimal128("0") == BSONDecimal128(low: 0, high: 0x3040_0000_0000_0000))
        #expect(BSONDecimal128("NaN") == BSONDecimal128(low: 0, high: 0x7C00_0000_0000_0000))
        // Non-canonical coefficients read as zero.
        #expect(BSONDecimal128(low: 0, high: 0x6C10_0000_0000_0000).description == "0")
        #expect(BSONDecimal128(low: .max, high: 0x3041_FFFF_FFFF_FFFF).description == "0")
    }

    @Test func doubleText() throws {
        let cases: [(Double, String)] = [
            (1, "1.0"), (-0.0, "-0.0"), (0, "0.0"), (.nan, "NaN"), (.infinity, "Infinity"), (-.infinity, "-Infinity"),
            (0.1, "0.1"), (1.2345678921232e18, "1.2345678921232e+18"), (5e-324, "5e-324"), (3e9, "3000000000.0"),
        ]
        for (v, text) in cases {
            #expect(BSONValue.doubleText(v) == text)
            #expect(try BSONValue(shellForm: text) == .double(v))
        }
        for v in [0.1 + 0.2, .pi, 1e300, -2.5e-300, Double.greatestFiniteMagnitude, Double.leastNormalMagnitude] {
            #expect(try BSONValue(shellForm: BSONValue.doubleText(v)) == .double(v))
        }
    }

    // MARK: Shell form

    @Test func formatsAsMongosh() throws {
        let d = BSONDocument([("_id", .objectId(oid("5f2b1c3d4e5f6a7b8c9d0e1f"))), ("n", .int32(1)), ("x", .double(1)),
                              ("l", .int64(5)), ("big", .int64(.min)), ("when", .datetime(0)), ("tags", .array([.string("a")])),
                              ("e", .document(BSONDocument())), ("odd key", .null)])
        #expect(d.shellForm() == """
            { _id: ObjectId("5f2b1c3d4e5f6a7b8c9d0e1f"), n: 1, x: 1.0, l: NumberLong(5), \
            big: NumberLong("-9223372036854775808"), when: ISODate("1970-01-01T00:00:00.000Z"), tags: [ "a" ], e: {}, \
            "odd key": null }
            """)
        #expect(BSONDocument([("a", .array([.int32(1)])), ("b", .null)]).shellForm(pretty: true) == """
            {
              a: [
                1
              ],
              b: null
            }
            """)
        let values: [(BSONValue, String)] = [
            (.decimal128(BSONDecimal128("1.10")!), "NumberDecimal(\"1.10\")"),
            (.timestamp(t: 1, i: 2), "Timestamp({ t: 1, i: 2 })"),
            (.binary(subtype: 4, data: Data(hex("00112233445566778899aabbccddeeff"))), "UUID(\"00112233-4455-6677-8899-aabbccddeeff\")"),
            (.binary(subtype: 0, data: Data([1, 2, 3])), "BinData(0, \"AQID\")"),
            (.regex(pattern: "^a", options: "i"), "/^a/i"),
            (.regex(pattern: "a/b", options: ""), "BSONRegExp(\"a/b\", \"\")"),
            (.regex(pattern: "a", options: "x"), "BSONRegExp(\"a\", \"x\")"),
            (.minKey, "MinKey()"), (.int64(1 << 53), "NumberLong(9007199254740992)"),
            (.int64(1 << 53 + 1), "NumberLong(\"9007199254740993\")"), (.string("a\"\\\u{1}"), "\"a\\\"\\\\\\u0001\""),
            (.datetime(253_402_300_799_999), "ISODate(\"9999-12-31T23:59:59.999Z\")"),
            (.datetime(253_402_300_800_000), "new Date(253402300800000)"),
            (.datetime(-1), "ISODate(\"1969-12-31T23:59:59.999Z\")"),
            (.datetime(-62_167_219_200_000), "ISODate(\"0000-01-01T00:00:00.000Z\")"),
            (.datetime(951_782_400_000), "ISODate(\"2000-02-29T00:00:00.000Z\")"),
        ]
        for (v, text) in values {
            #expect(v.shellForm() == text)
            #expect(try BSONValue(shellForm: text) == v, "\(text)")
        }
    }

    @Test func everyTypeRoundTripsThroughShellForm() throws {
        for pretty in [false, true] {
            let text = everyType.shellForm(pretty: pretty)
            #expect(try BSONDocument(shellForm: text) == everyType, "\(text)")
        }
        for (_, value) in everyType.fields {
            #expect(try BSONValue(shellForm: value.shellForm()) == value, "\(value.shellForm())")
        }
        for ms: Int64 in [.min, .max, 0, -86_400_000, 1_709_164_800_000, -62_167_219_200_001] {
            #expect(try BSONValue(shellForm: BSONValue.datetime(ms).shellForm()) == .datetime(ms))
        }
    }

    @Test func parsesWhatPeopleType() throws {
        let d = try BSONDocument(shellForm: """
            {
              _id: ObjectId('5F2B1C3D4E5F6A7B8C9D0E1F'), "quoted key": 'single', n: 42, big: 3000000000, f: 2.5, e: 1e3,
              neg: -0, l: NumberLong("9223372036854775807"), l2: Long(7), i: NumberInt("5"), i2: Int32(6),
              dec: NumberDecimal(0.10), dec2: Decimal128("1E+2"), dbl: Double(3),
              d: ISODate("2024-05-01"), d2: ISODate("2024-05-01T12:30:00+02:00"), d3: new Date(1000),
              ts: Timestamp(5, 6), u: UUID("00112233445566778899aabbccddeeff"), r: /a[/]b\\/x/mi,
              arr: [1, [2], {}, ], esc: "\\u00e9\\ud83d\\ude00\\x41\\0\\t", inf: -Infinity, nan: NaN, mk: MaxKey,
            }
            """)
        let expected: [(String, BSONValue)] = [
            ("_id", .objectId(oid("5f2b1c3d4e5f6a7b8c9d0e1f"))), ("quoted key", .string("single")), ("n", .int32(42)),
            ("big", .double(3_000_000_000)), ("f", .double(2.5)), ("e", .double(1000)), ("neg", .double(-0.0)),
            ("l", .int64(.max)), ("l2", .int64(7)), ("i", .int32(5)), ("i2", .int32(6)),
            ("dec", .decimal128(BSONDecimal128("0.10")!)), ("dec2", .decimal128(BSONDecimal128("1E+2")!)), ("dbl", .double(3)),
            ("d", .datetime(1_714_521_600_000)), ("d2", .datetime(1_714_559_400_000)), ("d3", .datetime(1000)),
            ("ts", .timestamp(t: 5, i: 6)), ("u", .binary(subtype: 4, data: Data(hex("00112233445566778899aabbccddeeff")))),
            ("r", .regex(pattern: "a[/]b\\/x", options: "im")),
            ("arr", .array([.int32(1), .array([.int32(2)]), .document(BSONDocument())])),
            ("esc", .string("é😀A\u{0}\t")), ("inf", .double(-.infinity)), ("nan", .double(.nan)), ("mk", .maxKey),
        ]
        #expect(throws: BSONError.self) { try BSONValue(shellForm: "/a/g") }  // not a MongoDB option
        #expect(d.keys == expected.map(\.0))
        for (key, value) in expected { #expect(d[key] == value, "\(key)") }
    }

    @Test func parseErrorsSayWhereAndWhat() {
        func message(_ text: String) -> String {
            do { _ = try BSONDocument(shellForm: text); return "" } catch { return "\(error)" }
        }
        #expect(message("{ a: 1,\n  b: }") == "Line 2, column 6: Expected a value, found ‘}’")
        #expect(message("{ a: 1 b: 2 }") == "Line 1, column 8: Expected ‘,’ or ‘}’ after a field, found ‘b’")
        #expect(message("[1]") == "Line 1, column 1: A document starts with ‘{’; found ‘[’")
        #expect(message("{ a: \"x }").hasPrefix("Line 1, column 6: This string has no closing quote"))
        #expect(message("{ a: ObjectId(\"12\") }").contains("ObjectId(…) takes 24 hex digits"))
        #expect(message("{ a: db.dropDatabase() }").contains("isn't a value"))
        #expect(message("{ a: function() {} }").contains("isn't a value"))
        #expect(message("{ a: eval(\"1\") }").contains("runs no code"))
        #expect(message("{ é: 1 }").hasPrefix("Line 1, column 3:"))
        #expect(message("{ a: 1 } x").contains("Expected the end"))
        for bad in ["NumberInt(2147483648)", "NumberLong(1.5)", "NumberDecimal(\"1e99999\")", "ISODate(\"2023-02-29\")",
                    "ISODate(\"2024-01-01T00:00:00.0001Z\")", "Timestamp({ t: -1, i: 0 })", "BinData(256, \"\")",
                    "BinData(0, \"%%\")", "UUID(\"0011\")", "01", "1.", "-", "'a\nb'", "//", "{a:1", "[1 2]", "tru"] {
            #expect(throws: BSONError.self, "\(bad)") { try BSONValue(shellForm: bad) }
        }
    }

    @Test func numbersKeepTheirTypes() throws {
        #expect(try BSONValue(shellForm: "1") == .int32(1))
        #expect(try BSONValue(shellForm: "2147483648") == .double(2_147_483_648))
        #expect(try BSONValue(shellForm: "-2147483648") == .int32(.min))
        #expect(try BSONValue(shellForm: "1.0") == .double(1))
        #expect(try BSONValue(shellForm: "NumberLong(1)") == .int64(1))
        #expect(try BSONValue(shellForm: "NumberLong(\"-9223372036854775808\")") == .int64(.min))
    }

    @Test func cutsLongCells() {
        let long = BSONValue.string(String(repeating: "é", count: 100_000))
        #expect(long.shellForm(maxLength: 10) == "\"ééééééééé…")
        #expect(BSONValue.int32(5).shellForm(maxLength: 10) == "5")
        let bin = BSONValue.binary(subtype: 0, data: Data(count: 1_000_000)).shellForm(maxLength: 20)
        #expect(bin.count == 21 && bin.hasSuffix("…"))
        #expect(everyType.shellForm(pretty: true, maxLength: 30).count == 31)
    }

    // MARK: Equality, $type, walking

    @Test func typeExactEquality() {
        #expect(BSONValue.int32(1) != .double(1))
        #expect(BSONValue.int32(1) != .int64(1))
        #expect(BSONValue.double(1) != .decimal128(BSONDecimal128("1")!))
        #expect(BSONValue.double(-0.0) != .double(0))
        #expect(BSONValue.double(.nan) == .double(-.nan))
        #expect(BSONValue.decimal128(BSONDecimal128("1.0")!) != .decimal128(BSONDecimal128("1.00")!))
        #expect(BSONValue.string("é") != .string("e\u{301}"))  // Swift's == would call these equal
        #expect(BSONValue.document(BSONDocument([("a", .null), ("b", .null)])) != .document(BSONDocument([("b", .null), ("a", .null)])))
        #expect(BSONValue.array([.int32(1)]) != .array([.int32(1), .int32(1)]))
        #expect(BSONValue.null != .undefined)
        #expect(BSONValue.binary(subtype: 3, data: Data(count: 16)) != .binary(subtype: 4, data: Data(count: 16)))
        #expect(everyType == everyType)
    }

    @Test func typeAliases() {
        let aliases = everyType.fields.map(\.value.typeAlias)
        for alias in ["double", "string", "object", "array", "binData", "undefined", "objectId", "bool", "date", "null",
                      "regex", "dbPointer", "javascript", "symbol", "javascriptWithScope", "int", "timestamp", "long",
                      "decimal", "minKey", "maxKey"] {
            #expect(aliases.contains(alias), "\(alias)")
        }
        #expect(everyType.fields.filter(\.value.isReadOnly).map(\.key) == ["undefined", "dbPointer", "symbol", "codeWithScope"])
        #expect(everyType.keys.filter(BSONDocument.keyNeedsCare) == ["a.b", "$odd"])
    }

    @Test func walksEveryValueWithItsPath() throws {
        let d = try BSONDocument(shellForm: "{ a: { b: [1, { $where: 'x' }] }, c: 2 }")
        var seen: [String] = []
        d.walk { path, value in seen.append(path.dotted + "=" + value.typeAlias) }
        #expect(seen == ["a=object", "a.b=array", "a.b.0=int", "a.b.1=object", "a.b.1.$where=string", "c=int"])
        var operators: [[BSONPathSegment]] = []
        d.walk { path, _ in if case .key(let k)? = path.last, k.hasPrefix("$") { operators.append(path) } }
        #expect(operators == [[.key("a"), .key("b"), .index(1), .key("$where")]])
    }

    // MARK: The BSON corpus

    /// MongoDB's BSON corpus (github.com/mongodb/specifications, source/bson-corpus/tests, checked at commit
    /// 35911416a85117920e0e870543a13d539b1d9bc1). Its licence (CC BY-NC-SA) keeps it out of this repository, so this
    /// runs only when AIRSQL_BSON_CORPUS names a folder holding those JSON files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRSQL_BSON_CORPUS"] != nil))
    func corpus() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AIRSQL_BSON_CORPUS"]!)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count >= 30)
        var checked = 0
        for file in files {
            let suite = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            let name = file.lastPathComponent
            for test in suite["valid"] as? [[String: Any]] ?? [] {
                let what = "\(name): \(test["description"]!)"
                let canonical = hex(test["canonical_bson"] as! String)
                let document = try BSONDocument(bytes: canonical)
                #expect(try document.bytes() == canonical, "\(what)")
                if let degenerate = test["degenerate_bson"] as? String { _ = try BSONDocument(bytes: hex(degenerate)) }
                let lossy = test["lossy"] as? Bool ?? false
                // Lossy vectors are non-canonical decimals, which read as their canonical value.
                if !lossy { #expect(try BSONDocument(shellForm: document.shellForm()) == document, "\(what)") }
                let extjson = test["canonical_extjson"] as! String
                if name.hasPrefix("decimal128"), case .decimal128(let d)? = document["d"] {
                    let text = Self.extValue(extjson, "$numberDecimal")
                    #expect(d.description == text, "\(what)")
                    if !lossy { #expect(BSONDecimal128(text) == d, "\(what)") }
                    if !lossy, let degenerate = test["degenerate_extjson"] as? String {
                        #expect(BSONDecimal128(Self.extValue(degenerate, "$numberDecimal")) == d, "\(what)")
                    }
                }
                if name == "double.json", case .double(let v)? = document["d"] {
                    #expect(BSONValue.doubleText(v).lowercased() == Self.extValue(extjson, "$numberDouble").lowercased(), "\(what)")
                }
                checked += 1
            }
            for test in suite["decodeErrors"] as? [[String: Any]] ?? [] {
                #expect(throws: BSONError.self, "\(name): \(test["description"]!)") {
                    try BSONDocument(bytes: hex(test["bson"] as! String))
                }
                checked += 1
            }
            if name.hasPrefix("decimal128") {
                for test in suite["parseErrors"] as? [[String: Any]] ?? [] {
                    #expect(BSONDecimal128(test["string"] as! String) == nil, "\(name): \(test["description"]!)")
                    checked += 1
                }
            }
        }
        #expect(checked > 900)
    }

    /// The text of `{"d": {"$numberX": "…"}}`.
    static func extValue(_ json: String, _ key: String) -> String {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: [String: String]]
        return object["d"]![key]!
    }
}
