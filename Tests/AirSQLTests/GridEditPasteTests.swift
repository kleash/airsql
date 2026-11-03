import Foundation
import Testing
@testable import AirSQLCore

/// Paste from Excel, Numbers and CSV: the rectangle of cells, then each cell converted for its column.
struct GridEditPasteTests {
    typealias C = EditContexts
    static let us = Locale(identifier: "en_US"), german = Locale(identifier: "de_DE"), british = Locale(identifier: "en_GB")

    static func column(_ definition: String, nullable: Bool = true, generated: Bool = false) -> SchemaColumn {
        SchemaColumn(name: "c", dataType: String(definition.prefix { $0 != "(" && $0 != " " }), columnType: definition,
                     nullable: nullable, defaultValue: nullable ? .null : .none, autoIncrement: false, onUpdate: nil,
                     generated: generated ? .init(expression: "1 + 1", stored: false) : nil, invisible: false,
                     isJSON: false, charset: "utf8mb4", collation: nil, comment: "")
    }

    /// One pasted column converted for `definition`: each cell's SQL, or "!" and the failure's reason.
    static func pasted(_ texts: [String], _ definition: String, nullable: Bool = true, locale: Locale = us,
                       context: EditContext = C.mysql) -> [String] {
        let (values, failures) = Paste.convert(texts.map { [$0] }, columns: [column(definition, nullable: nullable)],
                                               format: PasteFormat(locale: locale), context: context)
        return values.enumerated().map { row, cells in
            cells[0] ?? failures.first { $0.row == row }.map { "!" + $0.reason } ?? "(unchanged)"
        }
    }

    @Test func spreadsheetTextBecomesARectangle() {
        // Excel: CRLF rows, a quoted cell with a line break, quotes written twice.
        #expect(Paste.cells("a\tb\r\n\"line1\nline2\"\t\"say \"\"hi\"\"\"\r\n") == [["a", "b"], ["line1\nline2", "say \"hi\""]])
        #expect(Paste.cells("1\t2\n3\t4\n") == [["1", "2"], ["3", "4"]])
        #expect(Paste.cells("a\rb") == [["a"], ["b"]])
        #expect(Paste.cells("a\t\tc\nd") == [["a", "", "c"], ["d", "", ""]])
        #expect(Paste.cells("a\t") == [["a", ""]])
        #expect(Paste.cells("5\" pipe\tx") == [["5\" pipe", "x"]])
        #expect(Paste.cells("\"unclosed") == [["unclosed"]])
        #expect(Paste.cells("") == [])
        #expect(Paste.cells("\n") == [[""]])
        // Without a tab, auto never splits: a lone 1,234.56 stays one cell.
        #expect(Paste.cells("1,234.56") == [["1,234.56"]])
        #expect(Paste.cells("1,5\n2,5") == [["1,5"], ["2,5"]])
        #expect(Paste.cells("id,name\n1,\"Smith, J\"\n", separator: .comma) == [["id", "name"], ["1", "Smith, J"]])
        #expect(Paste.cells("1;2,5\n3;4,5", separator: .semicolon) == [["1", "2,5"], ["3", "4,5"]])
    }

    @Test func numbersAreReadTheWayTheyWereWritten() {
        #expect(Paste.decimalSeparator(["1.234,56"], locale: Self.us) == ",")
        #expect(Paste.decimalSeparator(["1,234.56"], locale: Self.german) == ".")
        #expect(Paste.decimalSeparator(["1.234.567"], locale: Self.us) == ",")
        #expect(Paste.decimalSeparator(["1,5"], locale: Self.us) == ",")
        #expect(Paste.decimalSeparator(["1,234"], locale: Self.us) == ".")
        #expect(Paste.decimalSeparator(["1,234"], locale: Self.german) == ",")
        #expect(Paste.decimalSeparator(["1,234", "2,5"], locale: Self.us) == ",")
        #expect(Self.pasted(["1.234,56", "-7,5", "1 234,5", "1\u{A0}000", "−3"], "decimal(10,2)")
            == ["1234.56", "-7.5", "1234.5", "1000", "-3"])
        #expect(Self.pasted(["1,234.56", "1'234.5", "7"], "decimal(10,2)", locale: Self.german) == ["1234.56", "1234.5", "7"])
        #expect(Self.pasted(["1,234"], "int", locale: Self.us) == ["1234"])
        #expect(Self.pasted(["1,234"], "int", locale: Self.german)[0].hasPrefix("!int holds whole numbers"))
        #expect(Self.pasted(["1,5E+3"], "double", locale: Self.german) == ["1.5E+3"])
        #expect(Self.pasted(["12%"], "decimal(5,2)")[0].hasPrefix("!decimal(5,2) holds numbers"))
        #expect(Self.pasted(["TRUE", "FALSE"], "tinyint(1)") == ["1", "0"])
    }

    @Test func datesFollowTheColumnsOrder() {
        #expect(Self.pasted(["3/11/2026", "25/12/2026"], "date") == ["'2026-11-03'", "'2026-12-25'"])
        #expect(Self.pasted(["11/25/2026", "3/4/2026"], "date") == ["'2026-11-25'", "'2026-03-04'"])
        #expect(Self.pasted(["03/04/2026"], "date", locale: Self.us) == ["'2026-03-04'"])
        #expect(Self.pasted(["03/04/2026"], "date", locale: Self.british) == ["'2026-04-03'"])
        #expect(Self.pasted(["03.11.26", "1.2.1999"], "date", locale: Self.german) == ["'2026-11-03'", "'1999-02-01'"])
        #expect(Self.pasted(["2026-11-03", "2026/11/04"], "date", locale: Self.german) == ["'2026-11-03'", "'2026-11-04'"])
        #expect(Self.pasted(["3/11/2026 2:05 PM", "3/11/2026 12:30 AM", "3/11/2026 14:05:06"], "datetime")
            == ["'2026-03-11 14:05:00'", "'2026-03-11 00:30:00'", "'2026-03-11 14:05:06'"])
        #expect(Self.pasted(["2026-11-03T14:05:06.5"], "datetime(1)") == ["'2026-11-03 14:05:06.5'"])
        #expect(Self.pasted(["3/11/2026 0:00"], "date") == ["'2026-03-11'"])
        #expect(Self.pasted(["3/11/2026 14:05"], "date") == ["!DATE keeps no time of day: 14:05 would be lost"])
        #expect(Self.pasted(["2:05 PM", "26:03:04", "1 02:03:04"], "time") == ["'14:05:00'", "'26:03:04'", "'26:03:04'"])
        #expect(Self.pasted(["31/02/2026"], "date", locale: Self.british) == ["!February 2026 has 28 days"])
        #expect(Self.pasted(["0000-00-00"], "date", context: C.mysql)[0].contains("NO_ZERO_DATE"))
        #expect(Self.pasted(["0000-00-00"], "date", context: C.mariadb) == ["'0000-00-00'"])
    }

    @Test func emptyCellsNullsAndFailuresAreReported() {
        #expect(Self.pasted([""], "int") == ["NULL"])
        #expect(Self.pasted([""], "int", nullable: false) == ["(unchanged)"])
        #expect(Self.pasted([""], "varchar(5)") == ["''"])
        #expect(Self.pasted([""], "set('a')", nullable: false) == ["''"])
        let format = PasteFormat(nullText: "\\N", locale: Self.us)
        let columns = [Self.column("varchar(9)"), Self.column("varchar(9)", nullable: false), Self.column("int", generated: true)]
        let (values, failures) = Paste.convert([["\\N", "\\N", "2", "extra"], ["NULL", "x", "", ""]], columns: columns,
                                               format: format, context: C.mysql)
        #expect(values == [["NULL", nil, nil, nil], ["'NULL'", "'x'", nil, nil]])
        #expect(failures == [
            PasteFailure(row: 0, column: 1, text: "\\N", reason: "The column is NOT NULL"),
            PasteFailure(row: 0, column: 2, text: "2", reason: "Generated (virtual) from 1 + 1: the server works it out"),
            PasteFailure(row: 0, column: 3, text: "extra", reason: "No column here to paste into"),
            PasteFailure(row: 1, column: 2, text: "", reason: "Generated (virtual) from 1 + 1: the server works it out"),
            PasteFailure(row: 1, column: 3, text: "", reason: "No column here to paste into"),
        ])
    }
}
