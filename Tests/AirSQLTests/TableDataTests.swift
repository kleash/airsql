import AirSQLCore
import Foundation
import Testing

/// The table tab's statements besides its pages (`TableDataSourceTests`), and the header details its schema gives.
struct TableDataTests {
    @Test func aCommentEndingTheFilterKeepsTheOrderAndLimit() {
        let source = TableDataSource(database: "shop", table: TableDataSourceTests.table())
        source.filter = "  total > 500 -- big ones "
        #expect(source.pageSQL(offset: 2_000, limit: 1_000) == "SELECT `id`, `name`, `photo`, `price` FROM `shop`.`items` "
            + "WHERE (total > 500 -- big ones\n) ORDER BY `id` ASC LIMIT 1000 OFFSET 2000")
        #expect(source.countSQL == "SELECT COUNT(*) FROM `shop`.`items` WHERE (total > 500 -- big ones\n)")
    }

    @Test func quotesHostileNames() {
        for name in Hostile.names {
            var table = TableDataSourceTests.table()
            table.name = name
            table.columns[1].name = name
            let source = TableDataSource(database: name, table: table)
            let quoted = SQLQuote.identifier(name)
            #expect(source.countSQL == "SELECT COUNT(*) FROM \(quoted).\(quoted)")
            #expect(source.topValuesSQL(1, limit: 5).hasPrefix("SELECT \(quoted), COUNT(*) FROM \(quoted).\(quoted) GROUP BY \(quoted)"))
            for flag in [false, true] {
                let literal = SQLQuote.string(name, noBackslashEscapes: flag)
                #expect(source.estimateSQL(noBackslashEscapes: flag) == "SELECT TABLE_ROWS, DATA_LENGTH FROM information_schema.TABLES "
                    + "WHERE TABLE_SCHEMA = \(literal) AND TABLE_NAME = \(literal)")
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

/// The status bar's figures and Go to Row's text.
struct GridReadingTests {
    @Test func figuresAddDecimalsExactlyAndSkipNulls() {
        let figures = GridAggregate(["3905.20", "540.00", "2118.75", nil])
        #expect(figures.count == 3 && figures.nulls == 1 && figures.distinct == 3)
        #expect(figures.sum == Decimal(string: "6563.95"))
        let posix = Locale(identifier: "en_US")
        #expect(figures.text(.sum, locale: posix) == "6,563.95")
        #expect(figures.text(.average, locale: posix) == "2,187.9833")
        #expect(figures.text(.median, locale: posix) == "2,118.75")
        #expect(figures.text(.minimum, locale: posix) == "540.00" && figures.text(.maximum, locale: posix) == "3,905.20")
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
}

/// Column Summary's statements and figures.
struct ColumnSummaryTests {
    @Test func summaryStatementsQuoteTheColumnAndKeepTheFilter() {
        var table = TableDataSourceTests.table()
        table.columns[1].name = "st`atus"
        let source = TableDataSource(database: "shop", table: table)
        source.filter = "total > 5"
        #expect(source.summarySQL(1) == "SELECT COUNT(DISTINCT `st``atus`), COUNT(*) - COUNT(`st``atus`), MIN(`st``atus`), "
            + "MAX(`st``atus`), COUNT(*) FROM `shop`.`items` WHERE (total > 5\n)")
        #expect(source.topValuesSQL(1, limit: 50) == "SELECT `st``atus`, COUNT(*) FROM `shop`.`items` WHERE (total > 5\n) "
            + "GROUP BY `st``atus` ORDER BY COUNT(*) DESC, `st``atus` LIMIT 50")
    }

    @Test func summaryFromValuesInMemory() {
        let summary = ColumnSummary(values: ["10", "9", "10", nil, "100", "10"])
        #expect(summary.distinct == 3 && summary.nulls == 1 && summary.rows == 6)
        #expect(summary.minimum == "9" && summary.maximum == "100")
        #expect(summary.top.map(\.value) == ["10", nil, "100", "9"] && summary.top.map(\.count) == [3, 1, 1, 1])
        let words = ColumnSummary(values: ["b", "a", "b"], limit: 1)
        #expect(words.minimum == "a" && words.top.count == 1 && words.top[0].value == "b")
    }
}
