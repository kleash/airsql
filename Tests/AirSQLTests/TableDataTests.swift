import AirSQLCore
import Foundation
import Testing

/// The table tab's statements and the header details its schema gives (L2).
struct TableDataTests {
    @Test func pagesTheTableWithItsFilterAndSort() {
        var query = TableQuery(database: "shop", table: "orders")
        #expect(query.page(limit: 1000, offset: 0) == "SELECT * FROM `shop`.`orders` LIMIT 1000 OFFSET 0")
        #expect(query.count == "SELECT COUNT(*) FROM `shop`.`orders`")
        query.filter = "  total > 500 -- big ones "
        query.sort = [.init(column: "created_at", ascending: false), .init(column: "id", ascending: true)]
        #expect(query.page(limit: 1000, offset: 2000) == "SELECT * FROM `shop`.`orders` WHERE (total > 500 -- big ones\n) "
            + "ORDER BY `created_at` DESC, `id` LIMIT 1000 OFFSET 2000")
        #expect(query.count == "SELECT COUNT(*) FROM `shop`.`orders` WHERE (total > 500 -- big ones\n)")
    }

    @Test func quotesHostileNames() {
        for name in Hostile.names {
            let query = TableQuery(database: name, table: name, sort: [.init(column: name, ascending: true)])
            let quoted = SQLQuote.identifier(name)
            #expect(query.page(limit: 1, offset: 0) == "SELECT * FROM \(quoted).\(quoted) ORDER BY \(quoted) LIMIT 1 OFFSET 0")
            for flag in [false, true] {
                let literal = SQLQuote.string(name, noBackslashEscapes: flag)
                #expect(query.estimate(noBackslashEscapes: flag) == "SELECT TABLE_ROWS FROM information_schema.TABLES WHERE "
                    + "TABLE_SCHEMA = \(literal) AND TABLE_NAME = \(literal)")
            }
        }
    }

    @Test func headerDetailsComeFromTheSchema() async throws {
        let (cache, _) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
        let orders = try #require(cache.snapshot.table("airsql_fixture", "orders"))
        func described(_ name: String) -> GridColumn {
            var column = GridColumn(name: name, type: "int")
            column.describe(orders)
            return column
        }
        let id = described("ID")
        #expect(id.isKey && id.marks == [.primary, .autoIncrement] && id.typeLine == "bigint(20) · auto")
        let customer = described("customer_id")
        #expect(!customer.isKey && customer.marks == [.foreign, .indexed, .nullable])
        #expect(customer.typeLine == "int(10) unsigned · null")
        #expect(customer.details == "customer_id · int(10) unsigned\nforeign key, indexed, NULL allowed")
        #expect(described("region").marks == [.unique] && described("number").marks == [.unique])
        #expect(described("total").typeLine == "decimal(12,2)")
        // A column the table doesn't have (an expression) keeps what the result said.
        #expect(described("1 + 1") == GridColumn(name: "1 + 1", type: "int"))
    }

    @Test func aUniqueNotNullKeyAddressesRowsWithoutAPrimaryKey() async throws {
        let (cache, _) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
        var orders = try #require(cache.snapshot.table("airsql_fixture", "orders"))
        orders.indexes.removeAll { $0.isPrimary }
        let keys = ["id", "region", "number", "customer_id"].map { name -> Bool in
            var column = GridColumn(name: name)
            column.describe(orders)
            return column.isKey
        }
        #expect(keys == [false, true, true, false])
    }

    @Test func commentsAndDefaultsShowInTheHeader() async throws {
        let (cache, _) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
        let tables = try #require(cache.snapshot.database("airsql_fixture")).tables
        let commented = try #require(tables.first { $0.columns.contains { !$0.comment.isEmpty } })
        let note = try #require(commented.columns.first { !$0.comment.isEmpty })
        var column = GridColumn(name: note.name)
        column.describe(commented)
        #expect(column.details.hasSuffix("\n“\(note.comment)”"))
        let defaulted = try #require(tables.first { $0.columns.contains { $0.defaultValue != .none && $0.defaultValue != .null } })
        let value = try #require(defaulted.columns.first { $0.defaultValue != .none && $0.defaultValue != .null })
        column = GridColumn(name: value.name)
        column.describe(defaulted)
        #expect(column.typeLine.contains(" · default") && column.details.contains("has a default"))
    }
}

/// The status bar's figures, Go to Row's text and Open Table's names (L2).
struct GridReadingTests {
    @Test func figuresAddDecimalsExactlyAndSkipNulls() {
        let figures = GridAggregate(["3905.20", "540.00", "2118.75", nil])
        #expect(figures.count == 3 && figures.nulls == 1 && figures.distinct == 3)
        #expect(figures.sum == Decimal(string: "6563.95"))
        let posix = Locale(identifier: "en_US")
        #expect(figures.text(.sum, locale: posix) == "6,563.95")
        #expect(figures.text(.average, locale: posix) == "2,187.9833")
        #expect(figures.text(.median, locale: posix) == "2,118.75")
        #expect(figures.text(.minimum, locale: posix) == "540" && figures.text(.maximum, locale: posix) == "3,905.2")
        #expect(figures.copyText(.sum) == "6563.95" && figures.copyText(.count) == "3")
        // 0.1 + 0.2 is 0.3 here, not 0.30000000000000004.
        #expect(GridAggregate(["0.1", "0.2"]).copyText(.sum) == "0.3")
    }

    @Test func wordsHaveNoSumButAMinimumAndMaximum() {
        let figures = GridAggregate(["paid", "shipped", "paid", "12"])
        #expect(figures.sum == nil && figures.text(.sum) == nil && figures.text(.average) == nil)
        #expect(figures.minimum == "12" && figures.maximum == "shipped" && figures.distinct == 3)
        #expect(GridAggregate([nil, nil]).text(.sum) == nil && GridAggregate([String?]()).count == 0)
        #expect(GridAggregate(["-1e3", "+2", ".5"]).copyText(.sum) == "-997.5")
    }

    @Test func selectedCellsAreEachCountedOnce() {
        var selection = GridSelection()
        selection.select(GridPosition(row: 1, column: 1))
        selection.select(GridPosition(row: 2, column: 2), extend: true)
        #expect(selection.cellCount(rows: 10, columns: 5) == 4)
        selection.selectColumn(2, add: true)
        #expect(selection.cellCount(rows: 10, columns: 5) == 14)
        let cells = selection.cells(rows: 10, columns: 5, limit: 100)
        #expect(cells?.count == 12 && cells?.first == GridPosition(row: 0, column: 2))
        #expect(selection.cells(rows: 10, columns: 5, limit: 13) == nil)
        selection.selectAll()
        #expect(selection.cellCount(rows: 1_000_000, columns: 50) == 50_000_000)
        #expect(selection.cells(rows: 1_000_000, columns: 50, limit: 100_000) == nil)
    }

    @Test func goToRowTakesANumberOrColumnAndRow() {
        #expect(GridGoTo("120") == GridGoTo("120"))
        #expect(GridGoTo(" 1,200 ")?.row == 1_199 && GridGoTo("120")?.column == nil)
        let target = GridGoTo("Email:7")
        #expect(target?.row == 6 && target?.columnIndex(in: ["id", "name", "email"]) == 2)
        #expect(GridGoTo("2:7")?.columnIndex(in: ["id", "name"]) == 1)
        #expect(GridGoTo("a:b:3")?.column == "a:b")
        #expect(GridGoTo("0") == nil && GridGoTo("x") == nil && GridGoTo("") == nil && GridGoTo("-4") == nil)
        #expect(GridGoTo("nope:3")?.columnIndex(in: ["id"]) == nil)
    }

    @Test func openTableReadsDatabaseAndTableNames() {
        func parsed(_ text: String, _ current: String? = "shop") -> [String]? {
            TableQuery(name: text, database: current).map { [$0.database, $0.table] }
        }
        #expect(parsed("orders") == ["shop", "orders"])
        #expect(parsed(" sales.orders ") == ["sales", "orders"])
        #expect(parsed("`my.db`.`order``s.x`") == ["my.db", "order`s.x"])
        #expect(parsed("`a b` ") == ["shop", "a b"])
        #expect(parsed("orders", nil) == nil && parsed("") == nil && parsed("`open") == nil && parsed("shop.") == nil)
        #expect(parsed("a.b.c") == ["a", "b.c"])
    }
}
