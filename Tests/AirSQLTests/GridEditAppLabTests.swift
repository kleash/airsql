import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

extension AppTests {
    /// Every column type of the fixture's all_types, typed into a table tab and applied: what the server keeps is what
    /// was typed (lab servers MariaDB 11.4 and 11.8, MySQL 8.4). Also Insert Value, the AUTO_INCREMENT key read back,
    /// and a pasted block. Writes only in lane_l3b_ui_<server>, dropped afterwards.
    @MainActor @Suite(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh")) struct GridEditAppLabTests {
        nonisolated static let servers = Lab.direct

        /// Typed text, and how the server shows it back (HEX for bytes, BIN for bits, +0 for ZEROFILL).
        static let values: [(column: String, typed: String, back: String)] = [
            ("c_tinyint", "-7", "-7"), ("c_tinyint_unsigned", "255", "255"), ("c_smallint", "1234", "1234"),
            ("c_mediumint", "-8388608", "-8388608"), ("c_int", "2147483647", "2147483647"), ("c_int_unsigned", "4294967295", "4294967295"),
            ("c_bigint", "-9223372036854775808", "-9223372036854775808"),
            ("c_bigint_unsigned", "18446744073709551615", "18446744073709551615"), ("c_zerofill", "42", "42"), ("c_boolean", "1", "1"),
            ("c_decimal", "1234567.123456789012345678901234567890", "1234567.123456789012345678901234567890"),
            ("c_money", "19.99", "19.99"), ("c_float", "1.5", "1.5"), ("c_double", "2.718281828459045", "2.718281828459045"),
            ("c_bit1", "1", "1"), ("c_bit10", "1010101010", "1010101010"),
            ("c_bit64", String(repeating: "1", count: 64), String(repeating: "1", count: 64)),
            ("c_date", "2026-11-03", "2026-11-03"), ("c_datetime", "2026-11-03 12:34:56", "2026-11-03 12:34:56"),
            ("c_datetime6", "2026-11-03 12:34:56.123456", "2026-11-03 12:34:56.123456"),
            ("c_timestamp", "2026-11-03 12:34:56", "2026-11-03 12:34:56"),
            ("c_timestamp3", "2026-11-03 12:34:56.789", "2026-11-03 12:34:56.789"),
            ("c_time", "-838:59:59", "-838:59:59"), ("c_time3", "12:34:56.789", "12:34:56.789"), ("c_year", "2155", "2155"),
            ("c_char", "char", "char"), ("c_varchar", "it's \\ \"odd\" 😀", "it's \\ \"odd\" 😀"), ("c_tinytext", "tiny", "tiny"),
            ("c_text", "line one\nline two", "line one\nline two"), ("c_mediumtext", "medium", "medium"), ("c_longtext", "long", "long"),
            ("c_binary16", "0x0123456789ABCDEF0123456789ABCDEF", "0123456789ABCDEF0123456789ABCDEF"),
            ("c_varbinary", "0x00FF", "00FF"), ("c_tinyblob", "0x01", "01"), ("c_blob", "0xDEADBEEF", "DEADBEEF"),
            ("c_mediumblob", "0xCAFE", "CAFE"), ("c_longblob", "0x0102", "0102"), ("c_enum", "large", "large"),
            ("c_set", "write,read", "read,write"), ("c_json", "{\"a\": \"b\"}", "{\"a\": \"b\"}"),
        ]

        static func readBack(_ column: String) -> String {
            switch column {
            case "c_binary16", "c_varbinary", "c_tinyblob", "c_blob", "c_mediumblob", "c_longblob", "c_point": return "HEX(\(column))"
            case "c_bit1", "c_bit10", "c_bit64": return "BIN(\(column))"
            case "c_zerofill": return "\(column) + 0"
            default: return column
            }
        }

        @Test(arguments: servers)
        func everyTypeRoundTripsThroughTheTableTab(_ lab: Lab.Server) async throws {
            let database = "lane_l3b_ui_\(lab.name)", quoted = SQLQuote.identifier(database)
            let connection = Connection(options: DBLab.options(lab), log: DBLab.log)
            defer { Task { await connection.disconnect() } }
            let admin = try await connection.session(.schema)
            for sql in ["DROP DATABASE IF EXISTS \(quoted)", "CREATE DATABASE \(quoted)", "CREATE TABLE \(quoted).t LIKE fixture.all_types",
                        "INSERT INTO \(quoted).t SELECT * FROM fixture.all_types"] {
                _ = try await admin.query(sql)
            }
            let schema = SchemaCache(source: admin, includes: { $0 == database })
            try await schema.load()
            let saved = SavedConnection(name: "Lab \(lab.name)", host: "127.0.0.1", user: "airsql")
            let model = testModel([saved])
            model.data.settings.rowsPerPage = 2  // so a new row isn't among the rows that load again after Apply
            let (main, _) = appWindow(model)
            let tab = TableDataController(model: model, context: EditorContext(connection: saved, sessions: connection, schema: schema),
                                          database: database, table: "t")
            main.select(main.open(tab, title: "t", connection: saved.id))
            await ready { tab.loading != nil || tab.source == nil }
            tab.loadMore(nil)
            await ready { tab.loading != nil }
            let source = try #require(tab.source)
            #expect(tab.grid.rowCount == 3 && tab.editContext != nil, "\(lab.name)")
            func column(_ name: String) -> Int { source.columns.firstIndex { $0.name == name } ?? -1 }
            func applied() async {
                tab.applyChanges(nil)
                _ = await eventually(timeout: 30) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    return source.changes.isEmpty && tab.loading == nil
                }
            }

            // Row 3 holds NULLs: each column gets its typed value, the way an editor keeps it (checked by type first).
            for value in Self.values {
                tab.keep(.text(value.typed), row: 2, column: column(value.column))
                #expect(source.mark(2, column(value.column)) == .edited, "\(lab.name) \(value.column) refused \(value.typed)")
            }
            // A shape's bytes as the server sent them go back as they are.
            let point = try #require(source.value(0, column("c_point")))
            tab.keep(.text(point), row: 2, column: column("c_point"))
            await applied()
            #expect(source.changes.isEmpty, "\(lab.name): \(tab.problem ?? "not applied")")
            let names = Self.values.map(\.column) + ["c_point"]
            let back = try await admin.rows("SELECT " + names.map(Self.readBack).joined(separator: ", ") + " FROM \(quoted).t WHERE id = 3")
            let expected = Self.values.map(\.back) + [String(point.dropFirst(2))]
            for (index, name) in names.enumerated() {
                #expect(back.first?[index] == expected[index], "\(lab.name) \(name)")
            }

            // A new row: Insert Value's server values and the AUTO_INCREMENT key, read back where the row was added.
            tab.addRow(nil)
            let new = tab.grid.rowCount - 1
            tab.grid.selection.select(GridPosition(row: new, column: column("c_datetime")))
            let now = try #require(tab.insertValueItems().first { $0.title == "NOW()" })
            tab.insertCellValue(now)
            tab.grid.selection.select(GridPosition(row: new, column: column("c_varchar")))
            let uuid = try #require(tab.insertValueItems().first { $0.title == "UUID()" })
            tab.insertCellValue(uuid)
            await applied()
            let id = try await admin.rows("SELECT MAX(id) FROM \(quoted).t").first?.first ?? nil
            #expect(source.saved.count == 1 && source.value(new, 0) == id && id == "4" && tab.grid.rowCount == 4, "\(lab.name)")
            #expect(source.value(new, column("c_varchar"))?.count == 36 && source.value(new, column("c_datetime")) != nil, "\(lab.name)")

            // A pasted block from a spreadsheet: comma decimals and day-first dates, as new rows.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("1.234,5\t31.12.2026\n7\t01.02.2026\n", forType: .string)
            tab.grid.selection.select(GridPosition(row: 0, column: column("c_money")))
            tab.viewer.setHidden(true, columns: Array(column("c_float")..<column("c_date")))  // c_money, then c_date
            tab.grid.selection.select(GridPosition(row: 0, column: try #require(tab.grid.columnOrder.firstIndex(of: column("c_money")))))
            tab.pasteAsNewRows(nil)
            await applied()
            let pasted = try await admin.rows("SELECT c_money, c_date FROM \(quoted).t WHERE id > 4 ORDER BY id")
            #expect(pasted == [["1234.50", "2026-12-31"], ["7.00", "2026-02-01"]], "\(lab.name)")
            _ = try await admin.query("DROP DATABASE \(quoted)")
        }
    }
}
