import AirSQLCore
import Foundation

/// A made-up table for the grid's tests, screenshots and frame-rate check: every cell is worked out from its position,
/// so a million rows cost nothing to hold. It has an id key and, column by column, names, numbers, dates, NULLs, empty
/// strings, long, emoji and right-to-left text, JSON and bytes.
final class FakeGridSource: GridSource {
    let columns: [GridColumn]
    let rowCount: Int

    /// 1,000,000 rows of 50 columns: the grid's size target.
    static func large() -> FakeGridSource { FakeGridSource(rows: 1_000_000, columns: 50) }
    /// 300 columns, with a 60-character column name: the wide target.
    static func wide() -> FakeGridSource { FakeGridSource(rows: 10_000, columns: 300) }

    init(rows: Int, columns: Int) {
        rowCount = rows
        self.columns = (0..<columns).map { c in
            let kinds: [(String, String, GridColumn.Kind)] = [
                ("name", "varchar(60)", .text), ("amount", "decimal(12,2)", .number), ("created", "datetime", .date),
                ("note", "varchar(255)", .text), ("status", "varchar(20)", .text), ("comment", "text", .text),
                ("payload", "json", .json), ("hash", "varbinary(16)", .binary), ("quantity", "int", .number),
            ]
            if c == 0 { return GridColumn(name: "id", type: "bigint unsigned", kind: .number, isKey: true) }
            let (name, type, kind) = kinds[(c - 1) % kinds.count]
            // One very long name (60 characters) to check headers shorten it rather than overlap.
            let label = c == 7 ? "a_column_name_that_runs_to_sixty_characters_to_test_layout_x" : "\(name)_\(c)"
            return GridColumn(name: label, type: type, kind: kind)
        }
    }

    func cell(_ row: Int, _ column: Int) -> GridCell {
        if column == 0 { return .text(String(row + 1)) }
        let n = row &* 31 &+ column
        switch (column - 1) % 9 {
        case 0: return .text("Customer \(row) \(Self.names[n % Self.names.count])")
        case 1: return .text(String(format: "%d.%02d", (n &* 37) % 100_000, n % 100))
        case 2: return .text(String(format: "2026-%02d-%02d %02d:%02d:%02d", n % 12 + 1, n % 28 + 1, n % 24, n % 60,
                                    (n / 7) % 60))
        case 3: return row % 7 == 3 ? .null : .text("note \(n)")
        case 4: return row % 5 == 2 ? .text("") : .text(["active", "paused", "closed"][n % 3])
        case 5: return .text(Self.longTexts[n % Self.longTexts.count])
        case 6: return row % 11 == 5 ? .null : .text("{\"id\": \(row), \"tags\": [\"a\", \"b\"], \"ok\": true}")
        case 7: return .text(String(format: "0x%08X%08X", UInt32(truncatingIfNeeded: n &* 2_654_435_761),
                                    UInt32(truncatingIfNeeded: row)))
        default: return .text(String(n % 1000))
        }
    }

    private static let names = ["Ada", "Grace", "Linus", "Margaret", "Ken", "Barbara", "Dennis", "Frances"]
    private static let longTexts = [
        "short",
        String(repeating: "A long value that keeps going to show how the grid shortens text. ", count: 4),
        "Emoji 😀🎉👍🏽 and accents: café, naïve, Zürich",
        "نص عربي من اليمين إلى اليسار",
        "Line one\nline two\ttabbed",
    ]
}
