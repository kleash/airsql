@testable import AirSQLCore
import Foundation
import Testing

@Suite struct ImportTests {
    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = URL(fileURLWithPath: try scratch()).appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func aReaderTakesOtherQuotesEscapesEncodingsAndTrims() throws {
        var single = CSVReader()
        single.quote = 0x27
        single.trim = true
        #expect(try single.read(Data("'a,b', c ,\"d\"\n".utf8)) + single.finish() == [["a,b", "c", "\"d\""]])
        var none = CSVReader()
        none.quote = nil
        #expect(try none.read(Data("\"a,b\n".utf8)) + none.finish() == [["\"a", "b"]])
        var escape = CSVReader()
        escape.escape = 0x5C
        #expect(try escape.read(Data(#""a\"b\\c",d"#.utf8)) + escape.finish() == [[#"a"b\c"#, "d"]])
        var roman = CSVReader()
        roman.encoding = .macOSRoman
        #expect(try roman.read(Data([0x8E, 0x2C, 0x61, 0x0A])) + roman.finish() == [["é", "a"]])
        #expect(!roman.readWindows1252)
    }

    /// UTF-16 from its BOM, cut anywhere, a surrogate pair included.
    @Test func utf16IsFoundByItsBOMAndReadInAnyPieces() throws {
        let text = "a\tb😀\n1\t2\n"
        for (bom, encoding) in [([UInt8(0xFF), 0xFE], String.Encoding.utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian)] {
            let bytes = bom + Array(try #require(text.data(using: encoding)))
            var reader = CSVReader(separator: 0x09), records: [[String]] = []
            for byte in bytes { records += reader.read(Data([byte])) }
            #expect(try records + reader.finish() == [["a", "b😀"], ["1", "2"]])
        }
    }

    @Test func thePreviewSkipsRowsAndGuessesTheSeparator() throws {
        var options = CSVImport.Options()
        options.skipRecords = 1
        let (separator, records) = try CSVImport.preview(.text("Report of May\na;b\n1;2\n"), options: options, guess: false)
        #expect(separator == UInt8(ascii: ","))
        #expect(records == [["a;b"], ["1;2"]])
        let guessed = try CSVImport.preview(.text("a;b\n1;2\n"), options: CSVImport.Options(), guess: true)
        #expect(guessed.separator == UInt8(ascii: ";") && guessed.records == [["a", "b"], ["1", "2"]])
    }

    private func type(_ values: [String], emptyIsNull: Bool = true, hex: Bool = false) -> String {
        var guess = ImportDetect.Guess(emptyIsNull: emptyIsNull, hexIsBinary: hex)
        values.forEach { guess.add($0) }
        return guess.type
    }

    /// Only what the server stores as it is becomes a number or date: anything else stays whole, as text.
    @Test func valuesGiveTheNarrowestTypeThatChangesNothing() {
        #expect(type(["1", "-2", ""]) == "INT")
        #expect(type(["1", "3000000000"]) == "BIGINT")
        #expect(type(["1", "99999999999999999999"]) == "DECIMAL(20,0)")
        #expect(type(["1.50", "20.125"]) == "DECIMAL(5,3)")
        #expect(type(["1e3", "2.5"]) == "DOUBLE")
        #expect(type(["007", "12"]) == "VARCHAR(32)")
        #expect(type(["+44", "12"]) == "VARCHAR(32)")
        #expect(type([String(repeating: "9", count: 70)]) == "VARCHAR(96)")
        #expect(type(["2026-02-28", "2024-02-29"]) == "DATE")
        #expect(type(["2026-02-29"]) == "VARCHAR(32)")
        #expect(type(["2026-02-28", "2026-03-01 10:20:30"]) == "DATETIME")
        #expect(type(["2026-03-01T10:20:30.125"]) == "DATETIME(3)")
        #expect(type(["2026-03-01T10:20:30Z"]) == "VARCHAR(32)")
        #expect(type(["01/02/2026"]) == "VARCHAR(32)")
        #expect(type(["10:20:30", "838:00:00"]) == "TIME")
        #expect(type(["true", "false"]) == "VARCHAR(32)")
        #expect(type([]) == "VARCHAR(255)")
        #expect(type(["1", ""], emptyIsNull: false) == "VARCHAR(32)")
        #expect(type([String(repeating: "é", count: 300)]) == "TEXT")
        #expect(type([String(repeating: "é", count: 40_000)]) == "MEDIUMTEXT")
        #expect(type(["0x00FF"], hex: true) == "LONGBLOB")
        #expect(type(["0x00FF"]) == "VARCHAR(32)")
        #expect(type([ImportSource.null, "1"]) == "INT")
    }

    @Test func aNewTableIsProposedFromEveryValue() throws {
        var options = CSVImport.Options()
        let text = "id, Name ,,id\n1,Ada,x,7\n2,Grace,y,8,extra\n"
        let columns = try ImportDetect.columns(.text(text), options: options, cancellation: Cancellation())
        #expect(columns.map(\.name) == ["id", "Name", "column_3", "id_2", "column_5"])
        #expect(columns.map(\.type) == ["INT", "VARCHAR(32)", "VARCHAR(32)", "INT", "VARCHAR(32)"])
        options.header = false
        #expect(try ImportDetect.columns(.text("1\n"), options: options, cancellation: Cancellation()).map(\.name) == ["column_1"])
        let sql = ImportDetect.createTable(database: "shop", table: "o`rders", columns: [.init(name: "a`b", type: "INT")])
        #expect(sql == "CREATE TABLE `shop`.`o``rders` (\n  `a``b` INT\n) DEFAULT CHARSET=utf8mb4")
        #expect(ImportDetect.createdTable(sql)?.table == "o`rders" && ImportDetect.createdTable(sql)?.database == "shop")
    }

    /// The box takes one plain CREATE TABLE: nothing else runs from it.
    @Test func onlyOneCreateTableIsTakenFromTheBox() {
        #expect(ImportDetect.createdTable("CREATE TABLE t (a INT)")?.table == "t")
        #expect(ImportDetect.createdTable("CREATE TABLE t (a INT); DROP TABLE u") == nil)
        #expect(ImportDetect.createdTable("DROP TABLE t") == nil)
        #expect(ImportDetect.createdTable("CREATE TABLE t AS SELECT * FROM u") == nil)
        #expect(ImportDetect.createdTable("CREATE VIEW v AS SELECT 1") == nil)
        #expect(ImportDetect.createdTable("") == nil)
    }

    @Test func aDecimalCommaIsReadInNumbersOnly() throws {
        #expect(ImportDetect.pointNumber("1.234,56") == "1234.56")
        #expect(ImportDetect.pointNumber("2,5") == "2.5")
        #expect(ImportDetect.pointNumber("Ada, Grace") == "Ada, Grace")
        var options = CSVImport.Options()
        options.decimalComma = true
        options.separator = UInt8(ascii: ";")
        #expect(try ImportDetect.columns(.text("a\n1.234,56\n"), options: options, cancellation: Cancellation())[0].type == "DECIMAL(6,2)")
    }

    /// Keys in the order first seen, digits as written, nested values as their JSON, null apart from empty text.
    @Test func jsonKeepsItsKeysDigitsAndNestedValues() throws {
        let text = #"[{"b": 1.10, "a": "x\n\"y\"", "n": null, "o": {"k": [1, "}"]}}, {"c": true, "a": "", "b": 12345678901234567890123}]"#
        let rows = try JSONRecords.rows(Data(text.utf8))
        #expect(rows == [["b", "a", "n", "o", "c"], ["1.10", "x\n\"y\"", ImportSource.null, #"{"k": [1, "}"]}"#, ""],
                         ["12345678901234567890123", "", "", "", "1"]])
        #expect(try JSONRecords.rows(Data("{\"a\":1}\n{\"a\":2}\n".utf8)) == [["a"], ["1"], ["2"]])
        #expect(throws: AirSQLError.self) { try JSONRecords.rows(Data("[1, 2]".utf8)) }
        #expect(throws: AirSQLError.self) { try JSONRecords.rows(Data(#"{"a": "#.utf8)) }
        #expect(throws: AirSQLError.self) { try JSONRecords.rows(Data("[]".utf8)) }
        let url = try file("people.json", Data(#"[{"id": 1}]"#.utf8))
        #expect(ImportSource.file(url).kind == .json)
        #expect(try CSVImport.preview(.file(url), options: CSVImport.Options()).records == [["id"], ["1"]])
    }

    /// AirSQL's own workbook, then the same zipped with DEFLATE as Excel does, and one made by hand with shared
    /// strings, a gap, a date format and a formula's value.
    @Test func workbooksReadBack() throws {
        let path = try scratch() + "/w.xlsx"
        let columns = [GridColumn(name: "id", kind: .number), GridColumn(name: "name")]
        let writer = try XLSXWriter(url: URL(fileURLWithPath: path), columns: columns, headers: true)
        try writer.add(["1", "Ada & co"])
        try writer.add(["2", nil])
        try writer.finish()
        let plain = try XLSXReader.rows(Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(plain == [["id", "name"], ["1", "Ada & co"], ["2"]])

        let folder = try scratch() + "/book"
        func put(_ name: String, _ text: String) throws {
            let url = URL(fileURLWithPath: folder + "/" + name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try put("xl/workbook.xml", #"<workbook xmlns:r="x"><sheets><sheet name="A" sheetId="1" r:id="rId7"/></sheets></workbook>"#)
        try put("xl/_rels/workbook.xml.rels", #"<Relationships><Relationship Id="rId7" Target="worksheets/data.xml"/></Relationships>"#)
        try put("xl/sharedStrings.xml", "<sst><si><t>name</t></si><si><r><t>Ad</t></r><r><t>a</t></r><rPh><t>x</t></rPh></si></sst>")
        try put("xl/styles.xml", #"<styleSheet><numFmts><numFmt numFmtId="170" formatCode="yyyy\-mm"/><numFmt numFmtId="171" formatCode="&quot;d&quot;0"/></numFmts><cellXfs><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="170"/><xf numFmtId="171"/></cellXfs></styleSheet>"#)
        try put("xl/worksheets/data.xml", #"""
            <worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="inlineStr"><is><t>when</t></is></c></row>
            <row r="3"><c r="A3" t="s"><v>1</v></c><c r="B3" t="b"><v>1</v></c><c r="C3" s="1"><v>46000</v></c>
            <c r="D3" s="2"><v>46000.5</v></c><c r="E3" s="3"><v>7</v></c><c r="F3"><f>1+1</f><v>2</v></c></row></sheetData></worksheet>
            """#)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = URL(fileURLWithPath: folder)
        zip.arguments = ["-q", "-r", "book.xlsx", "xl"]
        try zip.run()
        zip.waitUntilExit()
        let rows = try XLSXReader.rows(Data(contentsOf: URL(fileURLWithPath: folder + "/book.xlsx")))
        #expect(rows == [["name", "", "when"], [""], ["Ada", "1", "2025-12-09", "2025-12-09 12:00:00", "7", "2"]])
        #expect(throws: AirSQLError.self) { try XLSXReader.rows(Data("not a zip, and long enough to look for its end".utf8)) }
    }

    @Test func aRefusalOfTheRowIsToldFromTheEndOfTheConnection() {
        #expect(CSVImport.isTheRow(AirSQLError(.duplicate, "", code: 1062)))
        #expect(CSVImport.isTheRow(AirSQLError(.foreignKey, "", code: 1452)))
        #expect(CSVImport.isTheRow(AirSQLError(.other, "", code: 1406)))
        #expect(CSVImport.isTheRow(AirSQLError(.other, "", code: 3819)))
        #expect(!CSVImport.isTheRow(AirSQLError(.deadlock, "", code: 1213)))
        #expect(!CSVImport.isTheRow(AirSQLError(.lockTimeout, "", code: 1205)))
        #expect(!CSVImport.isTheRow(AirSQLError(.disconnected, "", code: 2013)))
        #expect(!CSVImport.isTheRow(AirSQLError(.accessDenied, "", code: 1142)))
        #expect(!CSVImport.isTheRow(AirSQLError(.other, "not the server's")))
    }
}
