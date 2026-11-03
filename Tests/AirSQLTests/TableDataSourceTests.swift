import CMariaDB
import Foundation
import Testing
@testable import AirSQLCore

/// A table's rows in the grid: the pages' SQL, loaded pages, pending changes drawn over them, new rows after the loaded
/// ones, and the local filter.
struct TableDataSourceTests {
    static func table(key: Bool = true) -> SchemaTable {
        var table = SchemaTable(name: "items", kind: .table, engine: "InnoDB")
        table.columns = [cachedColumn("id", "int unsigned", autoIncrement: true), cachedColumn("name", "varchar(20)", nullable: true, defaultValue: .null),
                         cachedColumn("photo", "blob", nullable: true), cachedColumn("price", "decimal(8,2)", defaultValue: .value("0.00"))]
        if key {
            table.indexes = [SchemaIndex(name: "PRIMARY", unique: true, type: "BTREE",
                                         parts: [.init(column: "id", expression: nil, prefixLength: nil, descending: false)],
                                         visible: true, comment: "")]
        }
        return table
    }

    /// A page of rows (id, name, photo, price), as the server sends them.
    static func page(_ rows: [(Int, String?)]) -> ResultStore {
        let store = ResultStore(columns: [.init(name: "id", type: MYSQL_TYPE_LONG), .init(name: "name", type: MYSQL_TYPE_VAR_STRING),
                                          .init(name: "photo", type: MYSQL_TYPE_BLOB, charset: 63),
                                          .init(name: "price", type: MYSQL_TYPE_NEWDECIMAL)])
        for (id, name) in rows {
            _ = store.append([Array(String(id).utf8), name.map { Array($0.utf8) }, [0x00, 0xAB], Array("1.50".utf8)])
        }
        return store
    }

    @Test func pagesFollowTheFilterAndTheSortOrTheKey() {
        let source = TableDataSource(database: "shop", table: Self.table())
        #expect(source.columns.map(\.kind) == [.number, .text, .binary, .number])
        #expect(source.columns.map(\.isKey) == [true, false, false, false])
        #expect(source.pageSQL(offset: 0, limit: 1_000)
                == "SELECT `id`, `name`, `photo`, `price` FROM `shop`.`items` ORDER BY `id` ASC LIMIT 1000")
        source.filter = "WHERE price > 1"
        source.sort = [.init(column: "name", ascending: false)]
        #expect(source.pageSQL(offset: 2_000, limit: 1_000).hasSuffix(" WHERE price > 1 ORDER BY `name` DESC LIMIT 1000 OFFSET 2000"))
        #expect(source.pageSQL(offset: 10, limit: nil).hasSuffix("LIMIT 18446744073709551615 OFFSET 10"))
        #expect(source.countSQL == "SELECT COUNT(*) FROM `shop`.`items` WHERE price > 1")
        let plain = TableDataSource(database: "shop", table: Self.table(key: false))
        #expect(plain.pageSQL(offset: 0, limit: 5) == "SELECT `id`, `name`, `photo`, `price` FROM `shop`.`items` LIMIT 5")
        #expect(plain.key == nil && plain.readOnlyReason != nil && !plain.canEdit(0, 1))
    }

    @Test func loadedPagesAndMoreToLoad() {
        let source = TableDataSource(database: "shop", table: Self.table())
        source.append(Self.page([(1, "Ann"), (2, nil)]), requested: 2)
        #expect(source.rowCount == 2 && source.hasMore)
        source.append(Self.page([(3, "Cy")]), requested: 2)
        #expect(source.rowCount == 3 && !source.hasMore)
        #expect(source.cell(2, 1) == .text("Cy") && source.cell(1, 1) == .null)
        #expect(source.cell(0, 2) == .text("0x00AB") && source.value(0, 2) == "0x00AB")
        #expect(source.rowKey(2) == ["3"])
        source.reset()
        #expect(source.rowCount == 0 && source.hasMore)
    }

    @Test func pendingChangesShowOverTheRows() {
        let source = TableDataSource(database: "shop", table: Self.table())
        source.append(Self.page([(1, "Ann"), (2, "Bob"), (3, "Cy")]), requested: 10)
        source.set(.text("Anna"), row: 0, column: 1)
        source.set(.null, row: 1, column: 3)
        source.changes.delete([["3"]])
        #expect(source.cell(0, 1) == .text("Anna") && source.mark(0, 1) == .edited && source.mark(0, 0) == .none)
        #expect(source.cell(1, 3) == .null && source.mark(1, 3) == .edited)
        #expect(source.mark(2, 0) == .deleted && !source.canEdit(2, 1))
        let id = source.changes.addRow()
        #expect(source.rowCount == 4 && source.row(3) == .inserted(id) && source.mark(3, 2) == .inserted)
        // A new row shows what the server will put in the columns it leaves out.
        #expect(source.cell(3, 0) == .text("(auto)") && source.cell(3, 1) == .null && source.cell(3, 3) == .text("0.00"))
        #expect(source.value(3, 0) == nil, "the server's AUTO_INCREMENT value isn't data yet: copies leave it out")
        source.set(.text("Dee"), row: 3, column: 1)
        #expect(source.cell(3, 1) == .text("Dee") && source.index(of: id) == 3)
        // Typing the loaded value again takes the edit away.
        source.set(.text("Ann"), row: 0, column: 1)
        #expect(source.mark(0, 1) == .none)
    }

    @Test func localFilterShowsTheMatchingLoadedRows() {
        let source = TableDataSource(database: "shop", table: Self.table())
        source.append(Self.page([(1, "Ann"), (2, "Bob"), (3, "Joanna")]), requested: 10)
        source.changes.addRow()
        source.localFilter = { GridFilter.matches("ann", $0) }
        #expect(source.rowCount == 3 && source.rowKey(1) == ["3"] && source.index(of: ["3"]) == 1)
        source.localFilter = nil
        #expect(source.rowCount == 4)
        source.localSort = [(column: 1, ascending: false)]
        #expect((0..<3).map { source.value($0, 1) } == ["Joanna", "Bob", "Ann"] && source.rowKey(0) == ["3"])
        source.localSort = []
        #expect(source.rowKey(0) == ["1"])
    }

    @Test func longValuesAreShortenedOnScreenButNotKeys() {
        var table = Self.table()
        table.columns[1] = cachedColumn("name", "text", nullable: true)
        let source = TableDataSource(database: "shop", table: table)
        let long = String(repeating: "x", count: 1_500)
        source.append(Self.page([(1, long)]), requested: 10)
        #expect(source.cell(0, 1) == .text(String(repeating: "x", count: 1_000) + "…"))
        #expect(source.value(0, 1) == long)
    }
}
