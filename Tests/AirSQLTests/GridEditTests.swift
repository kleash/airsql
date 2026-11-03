import Testing
@testable import AirSQLCore

/// Auto-generated values, Insert Value, editing keys, foreign-key queries and join editing, on the fixture schema as
/// MariaDB 11.8 and MySQL 8.4 describe it (SchemaFixtures.swift).
struct GridEditTests {
    typealias C = EditContexts

    static func snapshot(_ recording: String) async throws -> SchemaSnapshot {
        try await SchemaTests.loaded(recording).0.snapshot
    }

    @Test(arguments: [SchemaFixtures.mariadb118, SchemaFixtures.mysql84])
    func newRowsLeaveAutoDefaultAndGeneratedColumnsToTheServer(_ recording: String) async throws {
        let snapshot = try await Self.snapshot(recording)
        let customers = try #require(snapshot.table("airsql_fixture", "customers"))
        func column(_ name: String) throws -> SchemaColumn { try #require(customers.column(name)) }
        #expect(try column("id").newRowValue == .auto && column("id").newRowValue.placeholder == "auto")
        #expect(try column("email").newRowValue == .required && !column("email").newRowValue.leftOutOfInsert)
        #expect(try column("name").newRowValue == .default("it's"))
        #expect(try column("note").newRowValue == .null && column("note").newRowValue.placeholder == "NULL")
        #expect(try column("status").newRowValue == .default("new"))
        #expect(try column("created").newRowValue.placeholder == "default")
        #expect(try column("token").newRowValue == .default("uuid()"))
        #expect(try column("email_domain").newRowValue == .generated && column("email_domain").newRowValue.leftOutOfInsert)
        let reason = try #require(try column("email_domain").readOnlyReason)
        #expect(reason.hasPrefix("Generated (virtual) from substring_index(") && reason.hasSuffix(": the server works it out"))
        #expect(try column("name_upper").readOnlyReason?.hasPrefix("Generated (stored) from ") == true)
        #expect(try column("name").readOnlyReason == nil)
        #expect(try column("updated").valueNote?.contains("whenever the row changes") == true)
        #expect(try column("id").valueNote?.hasPrefix("AUTO_INCREMENT") == true)
        #expect(try column("email").valueNote == "Needs a value in new rows: NOT NULL with no default")

        // Insert Value offers what fits each column, and sends it as SQL for the server to work out.
        #expect(try column("id").insertValues == [.unixTimestamp, .random])
        #expect(try column("email").insertValues == [.uuid, .uuidWithoutDashes, .random])
        #expect(try column("note").insertValues == [.null, .default, .uuid, .uuidWithoutDashes, .random])
        #expect(try column("status").insertValues == [.default, .random])
        #expect(try column("created").insertValues == [.default, .now, .utcNow, .random])
        #expect(try column("prefs").insertValues == [.null, .default])
        #expect(try column("email_domain").insertValues.isEmpty)
        let updated = ColumnType(try column("updated")), created = ColumnType(try column("created"))
        #expect(InsertValue.now.sql(for: updated, C.mysql) == "NOW(3)" && InsertValue.now.sql(for: created, C.mysql) == "NOW()")
        #expect(InsertValue.now.title(for: updated, C.mysql) == "NOW(3)")
        #expect(InsertValue.random.title(for: updated, C.mysql) == "Random Value")
    }

    @Test func insertValuesAreServerExpressions() {
        let golden: [(InsertValue, String, String)] = [
            (.utcNow, "datetime(6)", "UTC_TIMESTAMP(6)"), (.currentTime, "time", "CURTIME()"), (.utcTime, "time(2)", "UTC_TIME(2)"),
            (.currentDate, "date", "CURDATE()"), (.uuidBinary, "binary(16)", "UNHEX(REPLACE(UUID(), '-', ''))"),
            (.uuidWithoutDashes, "char(32)", "REPLACE(UUID(), '-', '')"), (.uuidShort, "bigint unsigned", "UUID_SHORT()"),
            (.random, "bigint unsigned", "FLOOR(RAND() * 9007199254740992)"), (.random, "tinyint(4)", "FLOOR(RAND() * 128)"),
            (.random, "tinyint(1)", "FLOOR(RAND() * 2)"), (.random, "bit(64)", "FLOOR(RAND() * 9007199254740992)"),
            (.random, "bit(3)", "FLOOR(RAND() * 8)"), (.random, "decimal(10,2)", "TRUNCATE(RAND() * 100000000, 2)"),
            (.random, "decimal(5,5)", "TRUNCATE(RAND() * 1, 5)"), (.random, "varchar(10)", "LEFT(MD5(RAND()), 10)"),
            (.random, "binary(16)", "LEFT(UNHEX(SHA2(RAND(), 256)), 16)"), (.random, "enum('a','it''s')", "ELT(1 + FLOOR(RAND() * 2), 'a', 'it\\'s')"),
            (.null, "int", "NULL"), (.default, "int", "DEFAULT"),
        ]
        for (value, definition, sql) in golden {
            #expect(value.sql(for: C.type(definition), C.mysql) == sql, "\(value) for \(definition)")
        }
        #expect(InsertValue.random.sql(for: C.type("set('it''s')"), C.withMode("NO_BACKSLASH_ESCAPES"))
            == "ELT(1 + FLOOR(RAND() * 1), 'it''s')")
        #expect(InsertValue.allCases.allSatisfy { !$0.help.isEmpty && !$0.help.hasSuffix(".") })
    }

    @Test(arguments: [SchemaFixtures.mariadb118, SchemaFixtures.mysql84])
    func rowsAreAddressedByThePrimaryKeyOrANotNullUniqueKey(_ recording: String) async throws {
        let snapshot = try await Self.snapshot(recording)
        let database = try #require(snapshot.database("airsql_fixture"))
        #expect(database.table("customers")?.editingKey == ["id"])
        #expect(database.table("order_lines")?.editingKey == ["region", "number", "line"])
        #expect(database.table("log")?.editingKey == nil)
        #expect(database.table("log")?.editingRefusal?.contains("no primary key or NOT NULL unique key") == true)
        #expect(database.table("customer_emails")?.editingRefusal?.hasPrefix("A view has no key") == true)
        #expect(database.table("customers")?.editingRefusal == nil)
        if snapshot.server?.flavour == .mariadb {
            #expect(database.table("order_seq")?.editingRefusal?.hasPrefix("A sequence") == true)
        }
        // Without its primary key, orders is addressed by its NOT NULL unique key; customers' email likewise.
        var orders = try #require(database.table("orders"))
        orders.indexes.removeAll(where: \.isPrimary)
        #expect(orders.editingKey == ["region", "number"])
        var customers = try #require(database.table("customers"))
        customers.indexes.removeAll(where: \.isPrimary)
        #expect(customers.editingKey == ["email"])
        // A unique key over a nullable column doesn't address a row.
        var refs = try #require(snapshot.table("airsql other", "refs"))
        refs.indexes = refs.indexes.map { index in var index = index; index.unique = true; return index }.filter { !$0.isPrimary }
        #expect(refs.editingKey == nil)
    }

    @Test(arguments: [SchemaFixtures.mariadb118, SchemaFixtures.mysql84])
    func insertedRowsAreReadBackByKey(_ recording: String) async throws {
        let snapshot = try await Self.snapshot(recording)
        let customers = try #require(snapshot.table("airsql_fixture", "customers"))
        let sql = try customers.readBackQuery(database: "airsql_fixture", values: ["email": "'a@example.com'"], insertID: 7)
        #expect(sql.hasPrefix("SELECT `id`, `email`, `name`, "))
        #expect(sql.hasSuffix(" FROM `airsql_fixture`.`customers` WHERE `id` = 7"))
        #expect(throws: EditError.self) { try customers.readBackQuery(database: "airsql_fixture", values: [:], insertID: 0) }
        let lines = try #require(snapshot.table("airsql_fixture", "order_lines"))
        let keyed = try lines.readBackQuery(database: "airsql_fixture",
                                            values: ["region": "'EU'", "number": "12", "line": "1", "qty": "3"], insertID: 0)
        #expect(keyed.hasSuffix("WHERE `region` = 'EU' AND `number` = 12 AND `line` = 1"))
        #expect(throws: EditError.self) {
            try lines.readBackQuery(database: "airsql_fixture", values: ["region": "'EU'", "number": "12"], insertID: 5)
        }
        let weird = try #require(snapshot.table("airsql_fixture", "we`ird 'name' ✓"))
        #expect(throws: EditError.self) { try weird.readBackQuery(database: "airsql_fixture", values: [:], insertID: 1) }
    }
}
