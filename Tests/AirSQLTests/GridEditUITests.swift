import Foundation
import Testing
@testable import AirSQLCore

/// What the grid's editors build on (grid-spec §5): ↑ and ↓ stepping a date's part, pasted cells as pending values,
/// and Apply's statements writing each value by its column's type, with Insert Value's expressions sent as they are.
struct GridEditUITests {
    typealias C = EditContexts

    @Test func arrowsStepThePartUnderTheCursor() {
        let date = C.type("date"), stamp = C.type("datetime(3)"), time = C.type("time"), year = C.type("year")
        func step(_ type: ColumnType, _ text: String, _ at: Int, _ by: Int) -> String? { type.step(text, at: at, by: by)?.text }
        // A new month keeps the day inside it; days, months, hours and minutes wrap within their part.
        #expect(date.step("2026-01-31", at: 6, by: 1).map { [$0.text, NSStringFromRange($0.part)] } == ["2026-02-28", "{5, 2}"])
        #expect(step(date, "2026-02-28", 9, 1) == "2026-02-01" && step(date, "2024-02-28", 9, 1) == "2024-02-29")
        #expect(step(date, "2026-12-03", 5, 1) == "2026-01-03" && step(date, "2026-11-03", 0, -1) == "2025-11-03")
        #expect(step(stamp, "2026-11-03 23:59:59.999", 11, 1) == "2026-11-03 00:59:59.999")
        #expect(step(stamp, "2026-11-03 23:59:59.999", 21, 1) == "2026-11-03 23:59:59.000")
        #expect(step(stamp, "2026-11-03 23:59:59.999", 14, -1) == "2026-11-03 23:58:59.999")
        // TIME runs past a day, to 838 hours; YEAR stays within 1901 to 2155.
        #expect(step(time, "838:59:59", 1, 1) == "838:59:59" && step(time, "-01:00:00", 1, 1) == "-02:00:00")
        #expect(step(year, "2155", 2, 1) == "2155" && step(year, "1999", 0, 1) == "2000")
        // Nothing to step: an empty cell (never a made-up NOW()), words, or a column without parts.
        #expect(step(date, "", 0, 1) == nil && step(date, "today", 2, 1) == nil && step(C.type("varchar(10)"), "2026-11-03", 0, 1) == nil)
    }

    @Test func pastedCellsBecomePendingValuesAsLiteralReadsThem() async throws {
        let snapshot = try await GridEditTests.snapshot(SchemaFixtures.mariadb118)
        let customers = try #require(snapshot.table("airsql_fixture", "customers"))
        let columns = try ["balance", "note", "updated"].map { try #require(customers.column($0)) }
        let format = PasteFormat(decimalSeparator: ",", dateOrder: .dayMonthYear, nullText: "NULL")
        let (values, failures) = Paste.values([["1.234,5", "", "03.11.2026 14:05"], ["x", "NULL", "31/02/2026"]],
                                              columns: columns, format: format, context: C.mariadb)
        #expect(values[0] == [.text("1234.5"), .text(""), .text("2026-11-03 14:05")])
        #expect(values[1] == [nil, .null, nil] && failures.map(\.column) == [0, 2])
        // convert gives the same values as the literals Apply sends.
        let literals = Paste.convert([["1.234,5", "", "03.11.2026 14:05"]], columns: columns, format: format, context: C.mariadb)
        #expect(literals.values == [["1234.5", "''", "'2026-11-03 14:05:00'"]])
    }

    @Test func applyWritesValuesByTheirTypeAndRefusesOnesThatDontFit() throws {
        var changes = PendingChanges(keyColumns: ["id"])
        let id = changes.addRow(["created": .sql("NOW()"), "balance": .text("12.5"), "bits": .text("101")])
        changes.set(.text("ok"), column: "word", key: ["7"], original: "no")
        let types = ["balance": C.type("decimal(10,2)"), "bits": C.type("bit(3)"), "word": C.type("varchar(10)"),
                     "id": C.type("int(10) unsigned")]
        let typed: (String, String) throws -> String = { text, column in try types[column]!.literal(text, C.mariadb) }
        let columns = ["id", "balance", "bits", "created", "word"].map { GridColumn(name: $0, kind: $0 == "id" ? .number : .text) }
        let statements = try changes.statements(database: "shop", table: "customers", columns: columns, noBackslashEscapes: false,
                                                typed: typed)
        #expect(statements.map(\.sql) == ["UPDATE `shop`.`customers` SET `word` = 'ok' WHERE `id` = 7",
                                          "INSERT INTO `shop`.`customers` (`balance`, `bits`, `created`) VALUES (12.5, b'101', NOW())"])
        changes.set(.text("12.345"), column: "balance", insert: id)
        #expect {
            _ = try changes.statements(database: "shop", table: "customers", columns: columns, noBackslashEscapes: false, typed: typed)
        } throws: { error in
            guard let failure = error as? ApplyFailure, case .insert(id) = failure.statement.target else { return false }
            return failure.errorDescription?.hasPrefix("balance: decimal(10,2) keeps 2 digits after the point") == true
        }
    }
}
