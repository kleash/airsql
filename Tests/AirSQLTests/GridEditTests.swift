import Foundation
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
        // Shapes and vectors are bytes in the server's own format: edited as hex, never made up.
        #expect(C.type("point").kind == .binary(bytes: 4_294_967_295, fixed: false))
        #expect(C.type("vector(3)").kind == .binary(bytes: 12, fixed: true))
        #expect(GridEditPasteTests.column("geometry").insertValues == [.null, .default])
        #expect(GridEditPasteTests.column("uuid").insertValues == [.null, .default, .uuid])
        #expect(C.type("inet6").kind == .other && C.result(C.type("inet6"), "::1") == "'::1'")
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

    // MARK: Foreign keys

    @Test(arguments: [SchemaFixtures.mariadb118, SchemaFixtures.mysql84])
    func foreignKeyLookupsAreSearchedAndLimited(_ recording: String) async throws {
        let snapshot = try await Self.snapshot(recording)
        let orders = try #require(snapshot.table("airsql_fixture", "orders"))
        let customers = try #require(snapshot.table("airsql_fixture", "customers"))
        let key = try #require(ForeignKeyQueries.foreignKey(of: "customer_id", in: orders))
        #expect(key.name == "orders_customer")
        #expect(ForeignKeyQueries.defaultLabel(customers, key: key.referencedColumns) == "email")
        func lookup(_ label: String?, _ search: String, _ context: EditContext = C.mysql) -> String {
            ForeignKeyQueries.lookup(key, referenced: customers, label: label, search: search, context: context)
        }
        #expect(lookup("email", "") == "SELECT `id`, `email` FROM `airsql_fixture`.`customers` ORDER BY `email` LIMIT 100")
        #expect(lookup("email", " ada_%! ") == "SELECT `id`, `email` FROM `airsql_fixture`.`customers` "
            + "WHERE `email` LIKE '%ada!_!%!!%' ESCAPE '!' ORDER BY `email` LIMIT 100")
        #expect(lookup("email", "12") == "SELECT `id`, `email` FROM `airsql_fixture`.`customers` "
            + "WHERE `email` LIKE '%12%' ESCAPE '!' OR `id` = 12 ORDER BY `email` LIMIT 100")
        #expect(lookup("status", "x").hasSuffix("ORDER BY `id` LIMIT 100"))  // no index starts with status
        #expect(lookup("note", "x").hasSuffix("ORDER BY `id` LIMIT 100"))  // a FULLTEXT index doesn't order
        #expect(lookup(nil, "12") == "SELECT `id` FROM `airsql_fixture`.`customers` WHERE `id` = 12 ORDER BY `id` LIMIT 100")
        #expect(lookup(nil, "x") == "SELECT `id` FROM `airsql_fixture`.`customers` WHERE `id` LIKE '%x%' ESCAPE '!' ORDER BY `id` LIMIT 100")
        #expect(ForeignKeyQueries.lookup(key, referenced: customers, label: "id", search: "", limit: 0, context: C.mysql)
            == "SELECT `id` FROM `airsql_fixture`.`customers` ORDER BY `id` LIMIT 1")
        // Whatever is searched for, the statement stays one read-only SELECT, in either backslash mode (the check refuses
        // any NUL, which NO_BACKSLASH_ESCAPES leaves as it is inside the string).
        for search in Hostile.values {
            for (context, noBackslashEscapes) in [(C.mysql, false), (C.withMode("NO_BACKSLASH_ESCAPES"), true)]
            where !(noBackslashEscapes && search.unicodeScalars.contains("\0")) {
                let sql = lookup("email", search, context)
                #expect(ReadOnlyClassifier.classify(sql, noBackslashEscapes: noBackslashEscapes) == .readOnly, "\(sql)")
            }
        }
        // A key of two columns, and a table with no text column to label it.
        let lines = try #require(snapshot.table("airsql_fixture", "order_lines"))
        let linesKey = try #require(ForeignKeyQueries.foreignKey(of: "number", in: lines))
        #expect(ForeignKeyQueries.defaultLabel(orders, key: linesKey.referencedColumns) == nil)
        #expect(ForeignKeyQueries.lookup(linesKey, referenced: orders, label: nil, search: "EU", context: C.mysql)
            == "SELECT `region`, `number` FROM `airsql_fixture`.`orders` WHERE `region` LIKE '%EU%' ESCAPE '!' "
            + "ORDER BY `region`, `number` LIMIT 100")
        #expect(ForeignKeyQueries.display(label: "Ada", key: ["12"]) == "Ada (12)")
        #expect(ForeignKeyQueries.display(label: nil, key: ["EU", "7"]) == "EU, 7")
    }

    @Test func labelsAndVirtualForeignKeys() async throws {
        let snapshot = try await Self.snapshot(SchemaFixtures.mariadb118)
        let orders = try #require(snapshot.table("airsql_fixture", "orders"))
        let customers = try #require(snapshot.table("airsql_fixture", "customers"))
        let key = try #require(ForeignKeyQueries.foreignKey(of: "customer_id", in: orders))
        #expect(ForeignKeyQueries.labels(key, referenced: customers, label: "email", values: ["7", "x", "9"], context: C.mysql)
                == "SELECT `id`, `email` FROM `airsql_fixture`.`customers` WHERE `id` IN (7, 9)")
        #expect(ForeignKeyQueries.labels(key, referenced: customers, label: "email", values: ["x"], context: C.mysql) == nil)
        // A virtual key from order_lines.qty to customers: the snapshot's copy has it, Related Rows finds it both ways.
        let virtual = SchemaForeignKey(name: "virtual qty", columns: ["qty"], referencedDatabase: "airsql_fixture",
                                       referencedTable: "customers", referencedColumns: ["id"], onUpdate: "NO ACTION", onDelete: "NO ACTION")
        let keyed = snapshot.adding(["airsql_fixture": ["order_lines": [virtual]]])
        #expect(keyed.table("airsql_fixture", "order_lines")?.foreignKeys.last == virtual)
        #expect(snapshot.table("airsql_fixture", "order_lines")?.foreignKeys.contains(virtual) == false)
        let related = ForeignKeyQueries.referencing(database: "airsql_fixture", table: customers, row: ["id": Array("7".utf8)],
                                                    snapshot: keyed, context: C.mysql)
        #expect(related.contains { $0.table == "order_lines" && $0.condition == "`qty` = 7" })
        // Kept with the table's view settings; older settings without them still read.
        var settings = TableViewSettings()
        settings.virtualKeys = [virtual]
        settings.labelColumn = "email"
        let decoded = try JSONDecoder().decode(TableViewSettings.self, from: JSONEncoder().encode(settings))
        let older = try JSONDecoder().decode(TableViewSettings.self, from: Data("{}".utf8))
        #expect(decoded == settings && older.virtualKeys.isEmpty && older.labelColumn == nil)
        let store = TableViewSettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("vk-\(UUID()).json"))
        let connection = UUID()
        store.set(settings, connection: connection, database: "airsql_fixture", table: "order_lines")
        store.set(settings, connection: UUID(), database: "other", table: "t")
        #expect(store.virtualKeys(connection: connection) == ["airsql_fixture": ["order_lines": [virtual]]])
    }

    @Test(arguments: [SchemaFixtures.mariadb118, SchemaFixtures.mysql84])
    func relatedRowsBothWays(_ recording: String) async throws {
        let snapshot = try await Self.snapshot(recording)
        let orders = try #require(snapshot.table("airsql_fixture", "orders"))
        let customers = try #require(snapshot.table("airsql_fixture", "customers"))
        let lines = try #require(snapshot.table("airsql_fixture", "order_lines"))
        func bytes(_ text: String) -> [UInt8]? { Array(text.utf8) }
        let key = try #require(ForeignKeyQueries.foreignKey(of: "customer_id", in: orders))
        let parent = try ForeignKeyQueries.referenced(by: key, from: orders, row: ["customer_id": bytes("12")], context: C.mysql)
        #expect(parent == .init(database: "airsql_fixture", table: "customers", foreignKey: "orders_customer",
                                condition: "`id` = 12", sql: "SELECT * FROM `airsql_fixture`.`customers` WHERE `id` = 12"))
        #expect(throws: EditError("customer_id is NULL, so it refers to no row")) {
            try ForeignKeyQueries.referenced(by: key, from: orders, row: ["customer_id": nil], context: C.mysql)
        }
        #expect(throws: EditError.self) { try ForeignKeyQueries.referenced(by: key, from: orders, row: [:], context: C.mysql) }
        let linesKey = try #require(ForeignKeyQueries.foreignKey(of: "region", in: lines))
        let order = try ForeignKeyQueries.referenced(by: linesKey, from: lines, row: ["region": bytes("E'U"), "number": bytes("7")],
                                                     context: C.mysql)
        #expect(order.condition == "`region` = 'E\\'U' AND `number` = 7")

        let buyers = ForeignKeyQueries.referencing(database: "airsql_fixture", table: customers, row: ["id": bytes("12")],
                                                   snapshot: snapshot, context: C.mysql)
        #expect(buyers.map(\.table) == ["refs", "orders"] && buyers.map(\.database) == ["airsql other", "airsql_fixture"])
        #expect(buyers.map(\.condition) == ["`customer_id` = 12", "`customer_id` = 12"])
        #expect(buyers.last?.sql == "SELECT * FROM `airsql_fixture`.`orders` WHERE `customer_id` = 12")
        let children = ForeignKeyQueries.referencing(database: "airsql_fixture", table: orders,
                                                     row: ["id": bytes("5"), "region": bytes("EU"), "number": bytes("7")],
                                                     snapshot: snapshot, context: C.mysql)
        #expect(children.map(\.foreignKey) == ["lines_order", "orders_parent"])
        #expect(children.map(\.condition) == ["`region` = 'EU' AND `number` = 7", "`parent_id` = 5"])
        // Without the key's values (or with NULL) a row has no children to show.
        #expect(ForeignKeyQueries.referencing(database: "airsql_fixture", table: orders, row: ["id": nil, "region": bytes("EU")],
                                              snapshot: snapshot, context: C.mysql).isEmpty)
    }
}
