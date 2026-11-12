import AirSQLCore
import Foundation
import Testing

private func oid(_ h: String) -> BSONObjectId { BSONObjectId(hex: h)! }

/// One of every type, with values that relaxed Extended JSON keeps too (an int64 outside int32's range).
private let everyType = BSONDocument([
    ("_id", .objectId(oid("57e193d7a9cc81b4027498b5"))),
    ("double", .double(1.5)), ("whole", .double(42)), ("negZero", .double(-0.0)), ("tiny", .double(5e-324)),
    ("big", .double(1.7976931348623157e308)), ("nan", .double(.nan)), ("inf", .double(.infinity)), ("ninf", .double(-.infinity)),
    ("string", .string("héllo \"q\" \\ / \n\r\t\u{8}\u{C}\u{0}\u{1F}\u{7F}\u{2028} 😀")),
    ("document", .document(BSONDocument([("a", .int32(1)), ("a", .int32(2)), ("$odd", .null), ("a.b", .bool(true))]))),
    ("empty", .document(BSONDocument())), ("emptyArray", .array([])),
    ("array", .array([.int32(1), .string("x"), .array([.null]), .document(BSONDocument([("k", .minKey)]))])),
    ("binary", .binary(subtype: 0, data: Data([0, 1, 2, 255]))),
    ("uuid", .binary(subtype: 4, data: Data((0..<16).map { UInt8($0 * 17) }))),
    ("oldBinary", .binary(subtype: 2, data: Data([2, 0, 0, 0, 0xAB, 0xCD]))),
    ("user", .binary(subtype: 0x80, data: Data())),
    ("undefined", .undefined), ("t", .bool(true)), ("f", .bool(false)),
    ("date", .datetime(1_356_351_330_501)), ("epoch", .datetime(0)), ("before1970", .datetime(-284_643_869_501)),
    ("after9999", .datetime(253_402_300_800_000)), ("null", .null),
    ("regex", .regex(pattern: "^a\"/b\\$", options: "imx")),
    ("dbPointer", .dbPointer(namespace: "db.c", id: oid("56e1fc72e0c917e9c4714161"))),
    ("code", .javascript("function() { return \"1\" }")), ("symbol", .symbol("sym")),
    ("codeWithScope", .javascriptWithScope(code: "x", scope: BSONDocument([("x", .int64(5_000_000_000)),("d", .document(BSONDocument()))]))),
    ("int32", .int32(-2_147_483_648)), ("int32max", .int32(2_147_483_647)), ("ts", .timestamp(t: 4_294_967_295, i: 4_000_000_000)),
    ("int64", .int64(.max)), ("int64min", .int64(.min)), ("int64small", .int64(2_147_483_648)),
    ("decimal", .decimal128(BSONDecimal128("-1.230E-8")!)), ("decimalNaN", .decimal128(BSONDecimal128("NaN")!)),
    ("min", .minKey), ("max", .maxKey), ("", .string("empty key")),
])

private func parse(_ text: String) throws -> BSONDocument { try BSONDocument(extendedJSON: text) }

private func errorText(_ text: String) -> String {
    do { _ = try parse(text); return "no error" } catch { return "\(error)" }
}

private func readAll(_ data: Data) throws -> [BSONDocument] {
    var reader = ExtendedJSONReader(data)
    var out: [BSONDocument] = []
    while let d = try reader.next() { out.append(d) }
    return out
}

struct MongoExtJSONTests {
    // MARK: Round trips

    @Test func everyTypeRoundTripsInBothModesAndLayouts() throws {
        #expect(try everyType.bytes().count > 0)  // the fixture is valid BSON
        for mode in [ExtendedJSONMode.canonical, .relaxed] {
            for pretty in [false, true] {
                let text = everyType.extendedJSON(mode, pretty: pretty)
                let read = try parse(text)
                #expect(read.keys == everyType.keys)
                for (a, b) in zip(read.fields, everyType.fields) {
                    #expect(a.value == b.value, "\(mode) pretty=\(pretty): \(b.key) read as \(a.value.extendedJSON(.canonical))")
                }
                #expect(try read.bytes() == everyType.bytes())
            }
        }
    }

    @Test func relaxedIntegersComeBackAsTheSmallestType() throws {
        let d = BSONDocument([("a", .int64(1)), ("b", .int64(-2_147_483_649))])
        #expect(d.extendedJSON(.relaxed) == #"{"a":1,"b":-2147483649}"#)
        #expect(try parse(d.extendedJSON(.relaxed)) == BSONDocument([("a", .int32(1)), ("b", .int64(-2_147_483_649))]))
        #expect(try parse(d.extendedJSON(.canonical)) == d)
    }

    @Test func canonicalAndRelaxedText() {
        let d = BSONDocument([
            ("i", .int32(42)), ("l", .int64(42)), ("d", .double(42.42)), ("w", .double(1)), ("z", .double(-0.0)),
            ("n", .double(.nan)), ("dec", .decimal128(BSONDecimal128("1234.5")!)),
            ("bin", .binary(subtype: 4, data: Data(base64Encoded: "yO2rw/c4TKO2jauSqRR4ow==")!)),
            ("ts", .timestamp(t: 42, i: 1)), ("re", .regex(pattern: "foo*", options: "ix")),
            ("e", .datetime(0)), ("ms", .datetime(1_356_351_330_001)), ("neg", .datetime(-1)), ("u", .undefined),
            ("min", .minKey), ("p", .dbPointer(namespace: "b", id: oid("56e1fc72e0c917e9c4714161"))),
            ("c", .javascriptWithScope(code: "f", scope: BSONDocument())), ("s", .symbol("x")),
        ])
        #expect(d.extendedJSON(.canonical) == #"{"i":{"$numberInt":"42"},"l":{"$numberLong":"42"},"d":{"$numberDouble":"42.42"},"#
            + #""w":{"$numberDouble":"1.0"},"z":{"$numberDouble":"-0.0"},"n":{"$numberDouble":"NaN"},"#
            + #""dec":{"$numberDecimal":"1234.5"},"bin":{"$binary":{"base64":"yO2rw/c4TKO2jauSqRR4ow==","subType":"04"}},"#
            + #""ts":{"$timestamp":{"t":42,"i":1}},"re":{"$regularExpression":{"pattern":"foo*","options":"ix"}},"#
            + #""e":{"$date":{"$numberLong":"0"}},"ms":{"$date":{"$numberLong":"1356351330001"}},"#
            + #""neg":{"$date":{"$numberLong":"-1"}},"u":{"$undefined":true},"min":{"$minKey":1},"#
            + #""p":{"$dbPointer":{"$ref":"b","$id":{"$oid":"56e1fc72e0c917e9c4714161"}}},"c":{"$code":"f","$scope":{}},"#
            + #""s":{"$symbol":"x"}}"#)
        #expect(d.extendedJSON(.relaxed) == #"{"i":42,"l":42,"d":42.42,"w":1.0,"z":-0.0,"n":{"$numberDouble":"NaN"},"#
            + #""dec":{"$numberDecimal":"1234.5"},"bin":{"$binary":{"base64":"yO2rw/c4TKO2jauSqRR4ow==","subType":"04"}},"#
            + #""ts":{"$timestamp":{"t":42,"i":1}},"re":{"$regularExpression":{"pattern":"foo*","options":"ix"}},"#
            + #""e":{"$date":"1970-01-01T00:00:00Z"},"ms":{"$date":"2012-12-24T12:15:30.001Z"},"#
            + #""neg":{"$date":{"$numberLong":"-1"}},"u":{"$undefined":true},"min":{"$minKey":1},"#
            + #""p":{"$dbPointer":{"$ref":"b","$id":{"$oid":"56e1fc72e0c917e9c4714161"}}},"c":{"$code":"f","$scope":{}},"#
            + #""s":{"$symbol":"x"}}"#)
    }

    @Test func prettyIndentsDocumentsAndKeepsWrappersOnOneLine() {
        let d = BSONDocument([("_id", .objectId(oid("57e193d7a9cc81b4027498b5"))), ("a", .array([.int32(1), .document(BSONDocument([("b", .null)]))])),
                              ("e", .document(BSONDocument()))])
        #expect(d.extendedJSON(.relaxed, pretty: true) == """
            {
              "_id": {"$oid": "57e193d7a9cc81b4027498b5"},
              "a": [
                1,
                {
                  "b": null
                }
              ],
              "e": {}
            }
            """)
    }

    @Test func stringsEscapeExactlyAsJSON() throws {
        let d = BSONDocument([("k\"\n", .string("\u{0}\u{1F}\"\\/\u{7F}é😀\u{2028}"))])
        #expect(d.extendedJSON() == "{\"k\\\"\\n\":\"\\u0000\\u001f\\\"\\\\/\u{7F}é😀\u{2028}\"}")
        #expect(try parse(#"{"a":"\u00e9\ud83d\ude00\/\b\f\n\r\t\"\\"}"#)["a"] == .string("é😀/\u{8}\u{C}\n\r\t\"\\"))
    }

    // MARK: Dates

    @Test func datesOutsideRelaxedRangeStayCanonical() throws {
        let last = Int64(253_402_300_799_999)  // 9999-12-31T23:59:59.999Z
        #expect(BSONValue.datetime(last).extendedJSON() == #"{"$date":"9999-12-31T23:59:59.999Z"}"#)
        #expect(BSONValue.datetime(last + 1).extendedJSON() == #"{"$date":{"$numberLong":"253402300800000"}}"#)
        #expect(BSONValue.datetime(-1).extendedJSON() == #"{"$date":{"$numberLong":"-1"}}"#)
        #expect(BSONValue.datetime(.min).extendedJSON() == #"{"$date":{"$numberLong":"-9223372036854775808"}}"#)
        for ms in [Int64.min, -62_198_755_200_001, -1, 0, 1, last, last + 1, .max] {
            #expect(try parse(BSONDocument([("d", .datetime(ms))]).extendedJSON())["d"] == .datetime(ms))
        }
        #expect(try parse(#"{"d":{"$date":"2012-12-24T13:15:30.5+01:00"}}"#)["d"] == .datetime(1_356_351_330_500))
        #expect(errorText(#"{"d":{"$date":"2012-13-01T00:00:00Z"}}"#).contains("ISO 8601"))
    }

    // MARK: Numbers

    @Test func numberBoundaries() throws {
        func number(_ text: String) throws -> BSONValue? { try parse("{\"n\":\(text)}")["n"] }
        #expect(try number("2147483647") == .int32(.max))
        #expect(try number("-2147483648") == .int32(.min))
        #expect(try number("2147483648") == .int64(2_147_483_648))
        #expect(try number("-2147483649") == .int64(-2_147_483_649))
        #expect(try number("9223372036854775807") == .int64(.max))
        #expect(try number("-9223372036854775808") == .int64(.min))
        #expect(try number("9223372036854775808") == .double(9_223_372_036_854_775_808))
        #expect(try number("-0") == .int32(0))
        #expect(try number("-0.0") == .double(-0.0))
        #expect(try number("1.0") == .double(1))
        #expect(try number("1e2") == .double(100))
        #expect(try number("1E-2") == .double(0.01))
        #expect(try number("4.9406564584124654e-324") == .double(5e-324))
        #expect(try number("1.7976931348623157e308") == .double(.greatestFiniteMagnitude))
        #expect(errorText(#"{"n":1e400}"#) == "Line 1, column 6: This number is too large for a double")
        // Any double's text reads back as the same bits.
        var g = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let d = Double(bitPattern: g.next())
            guard d.isFinite else { continue }
            let doc = BSONDocument([("d", .double(d))])
            #expect(try parse(doc.extendedJSON(.relaxed)) == doc)
            #expect(try parse(doc.extendedJSON(.canonical)) == doc)
        }
    }

    @Test func wrappedNumbers() throws {
        #expect(try parse(#"{"a":{"$numberDouble":"-0.0"},"b":{"$numberDouble":"-Infinity"},"c":{"$numberDouble":"NaN"}}"#)
            == BSONDocument([("a", .double(-0.0)), ("b", .double(-.infinity)), ("c", .double(.nan))]))
        #expect(try parse(#"{"a":{"$numberLong":"1"},"b":{"$numberInt":"-5"}}"#) == BSONDocument([("a", .int64(1)), ("b", .int32(-5))]))
        for bad in [#"{"$numberInt":"2147483648"}"#, #"{"$numberInt":"+1"}"#, #"{"$numberInt":"01"}"#, #"{"$numberInt":1}"#,
                    #"{"$numberLong":"9223372036854775808"}"#, #"{"$numberDouble":"inf"}"#, #"{"$numberDouble":"0x10"}"#,
                    #"{"$numberDecimal":"1e99999"}"#] {
            #expect(throws: BSONError.self, "\(bad)") { try parse("{\"a\":\(bad)}") }
        }
    }

    // MARK: The parser's rules

    @Test func wrappersFollowTheSpecsRules() throws {
        // Any key order; options sorted; $uuid read as subtype 4; DBRefs and unknown $ keys left as documents.
        let read = try parse(#"""
            {"c":{"$scope":{"x":1},"$code":"f"},"r":{"$regularExpression":{"options":"xmi","pattern":"p"}},
             "t":{"$timestamp":{"i":2,"t":1}},"u":{"$uuid":"73ffd264-44b3-4c69-90e8-e7d1dfc035d4"},
             "ref":{"$ref":"c","$id":{"$oid":"58921b3e6e32ab156a22b59e"},"$db":"db"},"q":{"$regex":"^a","$options":"i"},
             "$top":{"$type":"string"}}
            """#)
        #expect(read["c"] == .javascriptWithScope(code: "f", scope: BSONDocument([("x", .int32(1))])))
        #expect(read["r"] == .regex(pattern: "p", options: "imx"))
        #expect(read["t"] == .timestamp(t: 1, i: 2))
        #expect(read["u"] == .binary(subtype: 4, data: Data(base64Encoded: "c//SZESzTGmQ6OfR38A11A==")!))
        #expect(read["ref"] == .document(BSONDocument([("$ref", .string("c")), ("$id", .objectId(oid("58921b3e6e32ab156a22b59e"))),
                                                       ("$db", .string("db"))])))
        #expect(read["q"] == .document(BSONDocument([("$regex", .string("^a")), ("$options", .string("i"))])))
        // The top level is always a document, whatever its keys.
        #expect(try parse(#"{"$oid":"58921b3e6e32ab156a22b59e"}"#) == BSONDocument([("$oid", .string("58921b3e6e32ab156a22b59e"))]))
    }

    @Test func duplicateKeysAreKept() throws {
        let read = try parse(#"{"a":1,"a":"two","b":{"x":1,"x":2}}"#)
        #expect(read.keys == ["a", "a", "b"])
        #expect(read.fields[1].value == .string("two"))
        #expect(read.extendedJSON() == #"{"a":1,"a":"two","b":{"x":1,"x":2}}"#)
    }

    @Test func malformedTextSaysWhereAndWhat() {
        let cases: [(String, String)] = [
            ("", "Line 1, column 1: A document starts with ‘{’; found the end of the text"),
            ("[]", "Line 1, column 1: A document starts with ‘{’; found ‘[’"),
            (#"{"a": tru}"#, "Line 1, column 7: Expected true"),
            ("{\"a\": 1,\n}", "Line 2, column 1: Expected a field name in double quotes, found ‘}’"),
            (#"{a: 1}"#, "Line 1, column 2: Expected a field name in double quotes, found ‘a’"),
            (#"{"a" 1}"#, "Line 1, column 6: Expected ‘:’ after the field name a, found ‘1’"),
            (#"{"a": [1 2]}"#, "Line 1, column 10: Expected ‘,’ or ‘]’ in an array, found ‘2’"),
            (#"{"a": "x}"#, "Line 1, column 7: This string has no closing quote"),
            ("{\"a\": \"x\ny\"}", "Line 1, column 9: A string can't hold a line break or control character; write \\n or \\u0000"),
            (#"{"a": "\x"}"#, "Line 1, column 9: ‘\\x’ isn't a JSON escape"),
            (#"{"a": "\ud800"}"#, "Line 1, column 9: A \\u escape is half a character"),
            (#"{"é": 01}"#, "Line 1, column 7: A number can't start with 0"),
            (#"{"a": 1.}"#, "Line 1, column 9: Expected digits after the decimal point, found ‘}’"),
            (#"{"a": NaN}"#, "Line 1, column 7: Expected a value, found ‘N’"),
            (#"{"a": 1} x"#, "Line 1, column 10: Expected the end of the text after the document, found ‘x’"),
            ("{\"a\":\n  {\"$date\": 42}}", "Line 2, column 3: {\"$date\": …} takes an ISO 8601 date in a string or {\"$numberLong\": \"milliseconds\"}; the legacy {\"$date\": milliseconds} isn't read"),
            (#"{"a":{"$oid":"56e1fc72e0c917e9c4714161","b":1}}"#, "Line 1, column 6: {\"$oid\": …} can't have other fields beside it"),
            (#"{"a":{"b":1,"$oid":"56e1fc72e0c917e9c4714161"}}"#, "Line 1, column 6: {\"$oid\": …} can't have other fields beside it"),
            (#"{"a":{"$binary":"AQ==","$type":"00"}}"#, "Line 1, column 6: {\"$binary\": …} can't have other fields beside it"),
            (#"{"a":{"$binary":"AQ=="}}"#, "Line 1, column 6: {\"$binary\": …} takes {\"base64\": \"…\", \"subType\": \"00\"}; the legacy {\"$binary\": \"…\", \"$type\": \"00\"} isn't read"),
            (#"{"a":{"$minKey":true}}"#, "Line 1, column 6: {\"$minKey\": …} takes 1"),
            (#"{"a\u0000":1}"#, "Line 1, column 2: A field name can't contain a NUL character"),
            (#"{"a":{"$regularExpression":{"pattern":"b\u0000","options":""}}}"#, "Line 1, column 6: {\"$regularExpression\": …} takes a pattern and options without NUL characters"),
            (#"{"a":{"$uuid":"73ff-d26444b-34c6-990e8e-7d1dfc035d4"}}"#, "Line 1, column 6: {\"$uuid\": …} takes a UUID in a string, such as \"73ffd264-44b3-4c69-90e8-e7d1dfc035d4\""),
            (#"{"a":{"$timestamp":{"t":"1","i":2}}}"#, "Line 1, column 6: {\"$timestamp\": …} takes {\"t\": seconds, \"i\": increment}, each a whole number from 0 to 4294967295"),
        ]
        for (text, message) in cases {
            #expect(errorText(text) == message, "\(text)")
        }
    }

    @Test func nestingStopsAtBSONsLimit() throws {
        func nested(_ levels: Int, leaf: String = "1") -> String {
            String(repeating: #"{"a":"#, count: levels) + leaf + String(repeating: "}", count: levels)
        }
        // The outermost document is depth 0, as in the BSON reader: 101 levels of documents are allowed.
        let deepest = try parse(nested(BSONDocument.maxDepth + 1, leaf: #"{"$dbPointer":{"$ref":"b","$id":{"$oid":"56e1fc72e0c917e9c4714161"}}}"#))
        #expect(try BSONDocument(bytes: deepest.bytes()) == deepest)
        #expect(errorText(nested(BSONDocument.maxDepth + 2)).hasSuffix("Documents nest more than 100 deep"))
        #expect(errorText("{\"a\":" + String(repeating: "[", count: 100_000)).hasSuffix("nest more than 100 deep"))
    }

    // MARK: Streams

    @Test func writerAndReaderStreamLinesAndArrays() throws {
        let documents = (0..<5).map { BSONDocument([("_id", .int32($0)), ("v", .string("line\n\($0)"))]) }
        for layout in [ExtendedJSONWriter.Layout.lines, .array] {
            for pretty in [false, true] {
                var writer = ExtendedJSONWriter(.canonical, layout: layout, pretty: pretty)
                var text = writer.header()
                for d in documents { text += writer.document(d) }
                text += writer.footer()
                if layout == .lines && !pretty { #expect(text.split(separator: "\n").count == 5) }
                #expect(try readAll(Data(text.utf8)) == documents, "\(layout) \(pretty)")
            }
            var empty = ExtendedJSONWriter(layout: layout)
            #expect(try readAll(Data((empty.header() + empty.footer()).utf8)).isEmpty)
            _ = empty.document(BSONDocument())
        }
        #expect(try readAll(Data("\u{FEFF} [ {\"a\":1} , {\"a\":2} ]\n".utf8)) == [BSONDocument([("a", .int32(1))]), BSONDocument([("a", .int32(2))])])
    }

    @Test func streamErrorsSayWhere() {
        func failure(_ text: String) -> String {
            do { _ = try readAll(Data(text.utf8)); return "no error" } catch { return "\(error)" }
        }
        #expect(failure("{\"a\":1}\n{\"a\":}\n") == "Line 2, column 6: Expected a value, found ‘}’")
        #expect(failure("[{\"a\":1}\n{\"a\":2}]") == "Line 2, column 1: Expected ‘,’ or ‘]’ after a document in the array, found ‘{’")
        #expect(failure("[{\"a\":1},") == "Line 1, column 10: The array has no closing ‘]’")
        #expect(failure("[{\"a\":1}] x") == "Line 1, column 11: Expected the end of the file after the array, found ‘x’")
        #expect(failure("{\"a\":1} 5") == "Line 1, column 9: Expected a document starting with ‘{’, found ‘5’")
    }

    /// The reader hands back the first document before the rest of the input exists: it never needs the whole file.
    @Test func readerStreamsWithoutReadingAhead() throws {
        let pipe = Pipe()
        let rest = DispatchSemaphore(value: 0)
        pipe.fileHandleForWriting.write(Data("{\"n\":0}\n".utf8))
        let writer = Thread {
            rest.wait()
            pipe.fileHandleForWriting.write(Data("{\"n\":1}\n".utf8))
            try? pipe.fileHandleForWriting.close()
        }
        writer.start()
        var reader = ExtendedJSONReader(pipe.fileHandleForReading)
        #expect(try reader.next() == BSONDocument([("n", .int32(0))]))
        rest.signal()
        #expect(try reader.next() == BSONDocument([("n", .int32(1))]))
        #expect(try reader.next() == nil)
    }

    /// A file of many megabytes, read in 64 KB pieces with documents and strings across their edges.
    @Test func readerReadsALargeFileInPieces() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-extjson-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        var writer = ExtendedJSONWriter(.canonical, layout: .array, pretty: true)
        func sample(_ n: Int) -> BSONDocument {
            BSONDocument([("_id", .int64(Int64(n))), ("s", .string(String(repeating: "é😀", count: n % 97))),
                          ("d", .double(Double(n) / 7)), ("when", .datetime(Int64(n) * 86_400_000))])
        }
        var chunk = writer.header()
        let count = 25_000
        for n in 0..<count {
            chunk += writer.document(sample(n))
            if chunk.utf8.count > 1 << 20 { out.write(Data(chunk.utf8)); chunk = "" }
        }
        out.write(Data((chunk + writer.footer()).utf8))
        try out.close()
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int > 8 << 20)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var reader = ExtendedJSONReader(input)
        var n = 0
        while let d = try reader.next() {
            if d != sample(n) { Issue.record("document \(n) differs"); break }
            n += 1
        }
        #expect(n == count)
    }

    // MARK: CSV

    @Test func csvColumnsCellsAndQuoting() {
        let documents = [
            BSONDocument([("_id", .objectId(oid("57e193d7a9cc81b4027498b5"))), ("name", .string("a, \"b\"\nc")),
                          ("addr", .document(BSONDocument([("city", .string("Pune")), ("geo", .document(BSONDocument([("lat", .double(1.5))])))]))),
                          ("tags", .array([.string("x"), .int32(2)])), ("n", .null)]),
            BSONDocument([("_id", .int32(2)), ("name", .string("null")), ("addr", .string("flat")), ("extra", .int64(7)),
                          ("empty", .document(BSONDocument()))]),
        ]
        let paths = MongoCSVWriter.paths(of: documents)
        #expect(paths == ["_id", "name", "addr.city", "addr.geo.lat", "tags", "n", "addr", "extra", "empty"])
        var shell = MongoCSVWriter(paths: paths)
        var text = shell.header()
        for d in documents { text += shell.row(d) }
        #expect(text == """
            _id,name,addr.city,addr.geo.lat,tags,n,addr,extra,empty
            "ObjectId(""57e193d7a9cc81b4027498b5"")","a, ""b""
            c",Pune,1.5,"[ ""x"", 2 ]",null,"{ city: ""Pune"", geo: { lat: 1.5 } }",,
            2,"null",,,,,flat,NumberLong(7),{}

            """)
        var relaxed = MongoCSVWriter(paths: ["_id", "tags", "addr.geo", "missing", "tags.1"], form: .relaxedJSON)
        #expect(relaxed.row(documents[0])
            == #""{""$oid"":""57e193d7a9cc81b4027498b5""}","[""x"",2]","{""lat"":1.5}",,2"# + "\n")
        var options = CopyOptions(headers: false, nullText: "")
        options.separator = ";"
        options.lineEnding = "\r\n"
        var custom = MongoCSVWriter(paths: ["n", "missing", "name"], options: options)
        #expect(custom.header() == "")
        #expect(custom.row(documents[0]) == ";\"\";\"a, \"\"b\"\"\nc\"\r\n")
    }

    // MARK: The BSON corpus

    /// MongoDB's BSON corpus, as in BSONTests (its licence keeps it out of this repository): runs only when
    /// AIRSQL_BSON_CORPUS names a folder holding its JSON files. Every valid case's canonical Extended JSON reads to
    /// its BSON and writes back to the same JSON; relaxed and degenerate forms read to the same values; parse errors throw.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRSQL_BSON_CORPUS"] != nil))
    func corpus() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AIRSQL_BSON_CORPUS"]!)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var checked = 0
        for file in files {
            let suite = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            let name = file.lastPathComponent
            for test in suite["valid"] as? [[String: Any]] ?? [] {
                let what = "\(name): \(test["description"]!)"
                let bson = Self.hex(test["canonical_bson"] as! String)
                let lossy = test["lossy"] as? Bool ?? false
                let expected = try BSONDocument(bytes: bson)
                let canonical = test["canonical_extjson"] as! String
                let read: BSONDocument
                do { read = try BSONDocument(extendedJSON: canonical) } catch { Issue.record("\(what): \(error)"); continue }
                if !lossy { #expect(try read.bytes() == bson, "\(what)") }
                #expect(Self.sameJSON(expected.extendedJSON(.canonical), canonical), "\(what): \(expected.extendedJSON(.canonical))")
                if let relaxed = test["relaxed_extjson"] as? String {
                    #expect(try BSONDocument(extendedJSON: expected.extendedJSON(.relaxed)) == BSONDocument(extendedJSON: relaxed), "\(what)")
                    #expect(Self.sameJSON(expected.extendedJSON(.relaxed), relaxed), "\(what): \(expected.extendedJSON(.relaxed))")
                }
                if let degenerate = test["degenerate_extjson"] as? String, !lossy {
                    #expect(try BSONDocument(extendedJSON: degenerate).bytes() == bson, "\(what)")
                }
                checked += 1
            }
            for test in suite["parseErrors"] as? [[String: Any]] ?? [] {
                var text = test["string"] as! String
                if name.hasPrefix("decimal128") { text = "{\"d\":{\"$numberDecimal\":\"\(text)\"}}" }
                #expect(throws: BSONError.self, "\(name): \(test["description"]!)") { try BSONDocument(extendedJSON: text) }
                checked += 1
            }
        }
        #expect(checked > 900)
    }

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var it = s.makeIterator()
        while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
        return out
    }

    /// The same JSON, by Foundation's reading (only in this test): numbers compared as numbers, keys in any order, and
    /// case ignored ("1.2345678921232E+18" is "1.2345678921232e+18").
    static func sameJSON(_ a: String, _ b: String) -> Bool {
        guard let x = try? JSONSerialization.jsonObject(with: Data(a.lowercased().utf8)) as? NSDictionary,
              let y = try? JSONSerialization.jsonObject(with: Data(b.lowercased().utf8)) as? NSDictionary else { return false }
        return x == y
    }
}
