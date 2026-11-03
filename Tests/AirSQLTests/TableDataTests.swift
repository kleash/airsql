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
