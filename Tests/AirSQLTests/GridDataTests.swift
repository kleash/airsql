import Foundation
import Testing
@testable import AirSQLCore

/// The grid's copy and export formats (grid-spec §6), filters, sorting and pending changes: golden text for every
/// format, hostile values kept inside their quotes.
struct GridDataTests {
    static let columns = [GridColumn(name: "id", type: "int", kind: .number, isKey: true),
                          GridColumn(name: "name", type: "varchar"),
                          GridColumn(name: "price", type: "decimal", kind: .number)]
    static let rows: [[String?]] = [["1", "Ann", "12.50"], ["2", nil, "-3"]]

    func text(_ format: CopyFormat, _ options: CopyOptions = CopyOptions()) -> String {
        CopyWriter.text(format, columns: Self.columns, rows: Self.rows, database: "shop", table: "items", options: options)
    }

    @Test func tabAndCommaSeparated() {
        #expect(text(.tsv) == "1\tAnn\t12.50\n2\tNULL\t-3\n")
        #expect(text(.tsv, CopyOptions(headers: true, nullText: "")) == "id\tname\tprice\n1\tAnn\t12.50\n2\t\t-3\n")
        #expect(text(.csv, CopyOptions(headers: true)) == "id,name,price\n1,Ann,12.50\n2,NULL,-3\n")
        let awkward: [[String?]] = [["3", "a,b", "\"x\""], ["4", "two\nlines", "tab\there"]]
        #expect(CopyWriter.text(.csv, columns: Self.columns, rows: awkward)
                == "3,\"a,b\",\"\"\"x\"\"\"\n4,\"two\nlines\",tab\there\n")
        #expect(CopyWriter.text(.tsv, columns: Self.columns, rows: awkward)
                == "3\ta,b\t\"\"\"x\"\"\"\n4\t\"two\nlines\"\t\"tab\there\"\n")
    }

    @Test func jsonKeepsNumbersNullsAndOrder() {
        #expect(text(.json) == "[\n  {\"id\": 1, \"name\": \"Ann\", \"price\": 12.50},\n  {\"id\": 2, \"name\": null, \"price\": -3}\n]\n")
        #expect(text(.jsonLines) == "{\"id\": 1, \"name\": \"Ann\", \"price\": 12.50}\n{\"id\": 2, \"name\": null, \"price\": -3}\n")
        #expect(CopyWriter.text(.json, columns: Self.columns, rows: []) == "[]\n")
        // Not a JSON number (leading zeros, ZEROFILL): a string. A JSON column's valid JSON goes in as it is.
        let odd = [GridColumn(name: "n", kind: .number), GridColumn(name: "j", kind: .json)]
        #expect(CopyWriter.text(.jsonLines, columns: odd, rows: [["007", "{\"a\": [1]}"], ["1e3", "not json"]])
                == "{\"n\": \"007\", \"j\": {\"a\": [1]}}\n{\"n\": 1e3, \"j\": \"not json\"}\n")
        // Every hostile value reads back as itself.
        let one = [GridColumn(name: "v`\"")]
        for value in Hostile.values {
            let line = CopyWriter.text(.jsonLines, columns: one, rows: [[value]])
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
            #expect(object == ["v`\"": value], "\(value.debugDescription)")
        }
    }

    @Test func markdownHTMLAndXML() {
        #expect(text(.markdown) == "| id | name | price |\n| ---: | --- | ---: |\n| 1 | Ann | 12.50 |\n| 2 | NULL | -3 |\n")
        #expect(text(.html) == "<table>\n<thead><tr><th>id</th><th>name</th><th>price</th></tr></thead>\n<tbody>\n"
                + "<tr><td>1</td><td>Ann</td><td>12.50</td></tr>\n<tr><td>2</td><td>NULL</td><td>-3</td></tr>\n</tbody>\n</table>\n")
        #expect(text(.xml) == """
            <?xml version="1.0" encoding="UTF-8"?>
            <table name="items">
              <row>
                <field name="id">1</field>
                <field name="name">Ann</field>
                <field name="price">12.50</field>
              </row>
              <row>
                <field name="id">2</field>
                <field name="name" null="true"/>
                <field name="price">-3</field>
              </row>
            </table>

            """)
        let tricky: [[String?]] = [["1", "a|b <i>&</i>\nnext", "0"]]
        #expect(CopyWriter.text(.markdown, columns: Self.columns, rows: tricky).hasSuffix("| 1 | a\\|b <i>&</i><br>next | 0 |\n"))
        #expect(CopyWriter.text(.html, columns: Self.columns, rows: tricky)
                .contains("<td>a|b &lt;i&gt;&amp;&lt;/i&gt;<br>next</td>"))
        // Every hostile value, in a hostile column name, is well-formed XML that reads back as itself (less the control
        // characters XML can't hold).
        for value in Hostile.values {
            let xml = CopyWriter.text(.xml, columns: [GridColumn(name: value)], rows: [[value]], table: value)
            #expect((try? XMLDocument(xmlString: xml)) != nil, "\(value.debugDescription)")
        }
    }

    @Test func sqlStatements() {
        #expect(text(.insert) == "INSERT INTO `shop`.`items` (`id`, `name`, `price`) VALUES (1, 'Ann', 12.50);\n"
                + "INSERT INTO `shop`.`items` (`id`, `name`, `price`) VALUES (2, NULL, -3);\n")
        #expect(text(.insertIgnore).hasPrefix("INSERT IGNORE INTO `shop`.`items` ("))
        #expect(text(.replace).hasPrefix("REPLACE INTO `shop`.`items` ("))
        #expect(text(.update) == "UPDATE `shop`.`items` SET `name` = 'Ann', `price` = 12.50 WHERE `id` = 1;\n"
                + "UPDATE `shop`.`items` SET `name` = NULL, `price` = -3 WHERE `id` = 2;\n")
        #expect(text(.delete) == "DELETE FROM `shop`.`items` WHERE `id` = 1;\nDELETE FROM `shop`.`items` WHERE `id` = 2;\n")
        #expect(text(.whereClause) == "(`id` = 1 AND `name` = 'Ann' AND `price` = 12.50)\nOR (`id` = 2 AND `name` IS NULL AND `price` = -3)")
        let id = [Self.columns[0]]
        #expect(CopyWriter.text(.whereClause, columns: id, rows: [["1"], [nil], ["2"]]) == "`id` IN (1, 2) OR `id` IS NULL")
        #expect(CopyWriter.text(.whereClause, columns: id, rows: [[nil]]) == "`id` IN (NULL) OR `id` IS NULL")
        // No key among the columns copied: every column addresses the row. Bits, hex and odd numbers as SQL reads them.
        let plain = [GridColumn(name: "flags", type: "bit"), GridColumn(name: "blob", kind: .binary),
                     GridColumn(name: "n", kind: .number)]
        #expect(CopyWriter.text(.delete, columns: plain, rows: [["101", "0x0aFF", "1; DROP TABLE t"]])
                == "DELETE FROM `table` WHERE `flags` = b'101' AND `blob` = X'0AFF' AND `n` = '1; DROP TABLE t';\n")
        #expect(CopyWriter.text(.insert, columns: plain, rows: [["2", "0xABC", "0x12"]])
                .hasSuffix("VALUES ('2', '0xABC', '0x12');\n"))
    }

    @Test(arguments: [false, true])
    func sqlValuesStayInsideTheirQuotes(noBackslashEscapes: Bool) {
        var options = CopyOptions()
        options.noBackslashEscapes = noBackslashEscapes
        for value in Hostile.values {
            let sql = CopyWriter.text(.insert, columns: [GridColumn(name: value)], rows: [[value]], table: value, options: options)
            #expect(sql == "INSERT INTO \(SQLQuote.identifier(value)) (\(SQLQuote.identifier(value))) VALUES ("
                    + SQLQuote.string(value, noBackslashEscapes: noBackslashEscapes) + ");\n")
        }
    }

    @Test func numbersAndHexAreRecognisedExactly() {
        for number in ["0", "-0", "12", "12.50", "-3.25e-7", "1E+3"] { #expect(CopyWriter.isNumber(number), "\(number)") }
        for text in ["", "-", "01", ".5", "5.", "1e", "1,5", "١٢", "0x10", " 1", "1 ", "Infinity", "NaN"] {
            #expect(!CopyWriter.isNumber(text), "\(text)")
        }
        #expect(CopyWriter.hexDigits("0x00ff") == "00FF")
        #expect(CopyWriter.hexDigits("0x") == "")
        for text in ["0xABC", "0xZZ", "00FF", "0x00…", "0x１２"] { #expect(CopyWriter.hexDigits(text) == nil, "\(text)") }
    }

    @Test func excelWorkbookIsAValidZipOfWellFormedParts() throws {
        let directory = try scratch()
        let url = URL(fileURLWithPath: directory).appendingPathComponent("rows.xlsx")
        let writer = try XLSXWriter(url: url, columns: Self.columns)
        for row in Self.rows + [["3", "<&> \"quoted\" \u{1}", "x"]] { try writer.add(row) }
        try writer.finish()
        #expect(try run("/usr/bin/unzip", ["-tq", url.path]).contains("No errors detected"))
        let sheet = try run("/usr/bin/unzip", ["-p", url.path, "xl/worksheets/sheet1.xml"])
        let document = try XMLDocument(xmlString: sheet)
        let cells = try document.nodes(forXPath: "//*[local-name()='row']").map { row in
            (row.children ?? []).map { $0.stringValue ?? "" }
        }
        #expect(cells == [["id", "name", "price"], ["1", "Ann", "12.50"], ["2", "", "-3"], ["3", "<&> \"quoted\" ", "x"]])
        #expect(sheet.contains("<c><v>12.50</v></c>") && sheet.contains("<c/>"))
        // unzip reads names as patterns: [ starts a set.
        for part in ["\\[Content_Types\\].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels"] {
            #expect((try? XMLDocument(xmlString: try run("/usr/bin/unzip", ["-p", url.path, part]))) != nil, "\(part)")
        }
    }

    @Test func crcMatchesTheStandard() {
        var crc = CRC32()
        crc.update(Data("123456789".utf8))
        #expect(crc.value == 0xCBF4_3926)
    }

    func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
