import Foundation
import Testing
@testable import AirSQLCore

/// The editors on MySQL 8.4 and MariaDB 11.4 (AIRSQL_LAB=1): generated CREATE and ALTER statements run, and the schema
/// read back is the design; objects replaced through their code; the fixture drawn as a diagram.
@Suite(.serialized, .enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
struct EditorsLabTests {
    static let database = "lane_l5b_editors"
    static let servers = [Lab.mysql84, Lab.mariadb114]

    func connected(_ server: Lab.Server) async throws -> DBConnection {
        let session = DBConnection(options: DBLab.options(server), role: .tools, log: DBLab.log)
        try await session.connect()
        return session
    }

    func run(_ statements: [String], on session: DBConnection) async throws {
        for statement in statements { _ = try await session.query(statement) }
    }

    /// The table as the editor reads it: a fresh schema cache, the options and column checks.
    func read(_ name: String, on session: DBConnection) async throws -> (design: TableDesign, server: SchemaServer) {
        let database = Self.database
        let cache = SchemaCache(source: session, includes: { $0 == database })
        try await cache.load()
        let server = try #require(cache.snapshot.server)
        let table = try #require(cache.snapshot.table(database, name), "\(name) isn't there")
        let (options, checks) = try await EditorQueries.table(database, name, server: server, from: session)
        return (TableDesign(table, options: options, columnChecks: checks, server: server), server)
    }

    /// What a design says, the way both servers write it back: expressions without quotes, spaces, parentheses or case;
    /// integers without a display width; ENUM values as values.
    func summary(_ table: TableDesign, next: Bool) -> [String] {
        func plain(_ sql: String?) -> String {
            (sql ?? "").lowercased().filter { !"`() ".contains($0) }
        }
        var lines = ["table \(table.name) engine=\(table.options.engine ?? "") comment=\(table.options.comment)"
                     + " collation=\(table.options.collation ?? "")" + (next ? " next=\(table.options.autoIncrement ?? 0)" : "")]
        for column in table.columns {
            var type = column.type
            if column.columnType?.integer == true { type.length = "" }
            let values = (try? TypeSpec.values(type.length, noBackslashEscapes: false)).map { "\($0)" } ?? type.length
            var line = "column \(column.name) \(type.name)(\(column.columnType?.length == .values ? values : type.length))"
            line += (type.unsigned ? " unsigned" : "") + (column.nullable ? " null" : " not null")
            switch column.defaultValue {
            case .none: break
            case .null: line += " default null"
            case .value(let value): line += " default '\(value)'"
            case .expression(let expression): line += " default " + plain(expression)
            }
            if column.autoIncrement { line += " auto_increment" }
            if let onUpdate = column.onUpdate { line += " on update " + plain(onUpdate) }
            if let generated = column.generated { line += " as " + plain(generated.expression) + (generated.stored ? " stored" : "") }
            if column.invisible { line += " invisible" }
            if let collation = column.collation { line += " collate " + collation }
            if !column.comment.isEmpty { line += " comment " + column.comment }
            if let check = column.check { line += " check " + plain(check) }
            lines.append(line)
        }
        for index in table.indexes.sorted(by: { $0.name < $1.name }) {
            lines.append("index \(index.kind) \(index.name) " + index.parts.map {
                ($0.column ?? plain($0.expression)) + ($0.prefixLength.map { "(\($0))" } ?? "") + ($0.descending ? " desc" : "")
            }.joined(separator: ","))
        }
        for key in table.foreignKeys.sorted(by: { $0.name < $1.name }) {
            lines.append("key \(key.name) \(key.columns) -> \(key.referencedTable)\(key.referencedColumns) "
                         + "update \(key.onUpdate) delete \(key.onDelete)")
        }
        for check in table.checks.sorted(by: { $0.name < $1.name }) {
            lines.append("check \(check.name) " + plain(check.clause) + (check.enforced ? "" : " not enforced"))
        }
        return lines
    }

    /// What was read back and what was designed, to compare (the next AUTO_INCREMENT only where the design sets it).
    func compared(_ back: TableDesign, _ design: TableDesign) -> ([String], [String]) {
        let next = design.options.autoIncrement != nil
        return (summary(back, next: next), summary(made(design), next: next))
    }

    /// A design as the server would show it once made: every part named as it is.
    func made(_ table: TableDesign) -> TableDesign {
        var table = table
        for index in table.columns.indices { table.columns[index].original = table.columns[index].name }
        for index in table.indexes.indices { table.indexes[index].original = table.indexes[index].name }
        for index in table.foreignKeys.indices { table.foreignKeys[index].original = table.foreignKeys[index].name }
        for index in table.checks.indices { table.checks[index].original = table.checks[index].name }
        return table
    }

    func column(_ name: String, _ type: String, null: Bool = false, _ value: SchemaDefault = .none, collation: String? = nil,
                comment: String = "") -> ColumnDesign {
        var column = ColumnDesign(name: name, type: TypeSpec(columnType: type))
        column.nullable = null
        column.defaultValue = value
        column.collation = collation
        column.comment = comment
        return column
    }

    @Test(arguments: servers)
    func appliesTableChangesAndReadsBackWhatWasDesigned(_ lab: Lab.Server) async throws {
        let session = try await connected(lab)
        defer { Task { await session.close() } }
        try await run(["DROP DATABASE IF EXISTS " + SQLQuote.identifier(Self.database),
                       "CREATE DATABASE " + SQLQuote.identifier(Self.database) + " CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"],
                      on: session)
        let server = SchemaServer(version: lab.flavor == .mariadb ? lab.version + "-MariaDB" : lab.version)
        let mariadb = lab.flavor == .mariadb
        let text = "utf8mb4_unicode_ci", hostile = "it's a \\ `x` \"q\" é中"

        var customers = TableDesign(name: "customers")
        var id = column("id", "int unsigned")
        id.autoIncrement = true
        customers.columns = [id, column("email", "varchar(120)", collation: text)]
        customers.indexes = [IndexDesign(name: "PRIMARY", kind: .primary, parts: [.init(column: "id")]),
                             IndexDesign(name: "email", kind: .unique, parts: [.init(column: "email")])]
        customers.options = TableOptions(engine: "InnoDB", collation: "utf8mb4_bin", comment: "")

        var orders = TableDesign(name: "orders")
        var orderID = column("id", "bigint unsigned")
        orderID.autoIncrement = true
        var created = column("created_at", "timestamp(3)", .expression("CURRENT_TIMESTAMP(3)"))
        created.onUpdate = "CURRENT_TIMESTAMP(3)"
        var total = column("total", "decimal(12,2)", .value("0.00"))
        if mariadb { total.check = "`total` < 1000000" }
        var taxed = column("total_with_tax", "decimal(14,2)", null: true)
        taxed.generated = SchemaColumn.Generated(expression: "`total` * 1.21", stored: true)
        var hidden = column("hidden", "int", null: true, .null)
        hidden.invisible = true
        orders.columns = [orderID, column("customer_id", "int unsigned"),
                          column("status", "enum('paid')", .value("paid"), collation: text),
                          total, taxed, column("note", "varchar(50)", null: true, .value(hostile), collation: text, comment: hostile),
                          created, column("meta", "json", null: true, .null), hidden]
        orders.columns[2].type.length = SQLQuote.string(hostile) + ",'paid'"
        orders.indexes = [IndexDesign(name: "PRIMARY", kind: .primary, parts: [.init(column: "id")]),
                          IndexDesign(name: "by_customer", kind: .index, parts: [.init(column: "customer_id")])]
        var key = ForeignKeyDesign(name: "orders_customer", columns: ["customer_id"], referencedDatabase: Self.database,
                                   referencedTable: "customers", referencedColumns: ["id"])
        key.onDelete = "RESTRICT"
        orders.foreignKeys = [key]
        orders.checks = [CheckDesign(name: "total_positive", clause: "`total` >= 0")]
        orders.options = TableOptions(engine: "InnoDB", collation: "utf8mb4_bin", comment: "Orders")

        for table in [customers, orders] {
            try await run(try table.statements(database: Self.database, from: nil, server: server), on: session)
            let (back, designed) = compared(try await read(table.name, on: session).design, table)
            #expect(back == designed, "\(lab) CREATE \(table.name)")
        }

        // Add, rename, move and retype columns; rename and add indexes; change the key, a check and the options.
        let before = try await read("orders", on: session).design
        var after = before
        after.columns.insert(column("currency", "char(3)", .value("EUR"), collation: text, comment: hostile), at: 4)
        after.renameColumn(at: after.columns.firstIndex { $0.name == "note" }!, to: "odd `name é")
        after.columns.insert(after.columns.remove(at: after.columns.firstIndex { $0.name == "created_at" }!), at: 1)
        after.columns[after.columns.firstIndex { $0.name == "total" }!].type.length = "14,2"
        after.indexes[after.indexes.firstIndex { $0.name == "by_customer" }!].name = "customer"
        after.indexes.append(IndexDesign(name: "customer_currency", kind: .unique,
                                         parts: [.init(column: "customer_id"), .init(column: "currency", prefixLength: 2, descending: true)]))
        after.foreignKeys[0].onDelete = "CASCADE"
        after.checks[0].clause = "`total` > -1"
        if !mariadb { after.checks.append(CheckDesign(name: "lax", clause: "`customer_id` > 0")) }
        after.options.comment = hostile
        after.options.autoIncrement = 1000
        let statements = try after.statements(database: Self.database, from: before, server: server)
        #expect(statements.count == 2, "the key is dropped on its own first: \(statements)")
        try await run(statements, on: session)
        let (altered, wanted) = compared(try await read("orders", on: session).design, after)
        #expect(altered == wanted, "\(lab) ALTER")

        // Then drop a column, swap two, turn a check off (MySQL) and rename the table.
        let second = try await read("orders", on: session).design
        var third = second
        third.removeColumn(at: third.columns.firstIndex { $0.name == "currency" }!)
        third.columns.swapAt(2, 3)
        if !mariadb { third.checks[third.checks.firstIndex { $0.name == "lax" }!].enforced = false }
        third.name = "orders2"
        third.options.autoIncrement = nil
        try await run(try third.statements(database: Self.database, from: second, server: server), on: session)
        let (renamed, asked) = compared(try await read("orders2", on: session).design, third)
        #expect(renamed == asked, "\(lab) second ALTER")
        try await run(["DROP DATABASE " + SQLQuote.identifier(Self.database)], on: session)
    }

    @Test(arguments: servers)
    func replacesObjectsThroughTheirCode(_ lab: Lab.Server) async throws {
        let session = try await connected(lab)
        defer { Task { await session.close() } }
        let database = Self.database + "_objects"
        try await run(["DROP DATABASE IF EXISTS " + SQLQuote.identifier(database), "CREATE DATABASE " + SQLQuote.identifier(database),
                       "CREATE TABLE " + SQLQuote.identifier(database, "t") + " (id INT PRIMARY KEY)"], on: session)
        let server = SchemaServer(version: lab.flavor == .mariadb ? lab.version + "-MariaDB" : lab.version)
        let me = try #require(try await EditorQueries.currentAccount(from: session))
        for kind in ObjectKind.allCases {
            // A new one from its template, made by root (as a restore would leave it), then edited and renamed.
            let name = "new " + kind.rawValue
            let template = ObjectCode.settingDefiner(ObjectCode.template(kind, name: name, table: "t"), to: "`root`@`localhost`")
            try await run(try ObjectCode.statements(template, kind: kind, database: database, original: nil, definition: nil,
                                                    server: server), on: session)
            let loaded = try await ObjectDefinition.load(kind, database: database, name: name, from: session)
            let header = try #require(CreateHeader(loaded.code))
            #expect(header.definerAccount == "root@localhost" && header.name == name, "\(lab) \(kind)")
            #expect((loaded.sqlMode != nil) == (kind != .view) && (loaded.timeZone != nil) == (kind == .event))

            // Edited, renamed, and made to run as the person: the old name goes, the new one has the new code.
            var code = ObjectCode.settingDefiner(loaded.code, to: nil)
            code = code.replacingOccurrences(of: SQLQuote.identifier(name), with: SQLQuote.identifier(name + " 2"))
            code += kind == .view ? " /* edited */" : ""
            let statements = try ObjectCode.statements(code, kind: kind, database: database, original: name, definition: loaded,
                                                       server: server)
            try await run(statements, on: session)
            let replaced = try await ObjectDefinition.load(kind, database: database, name: name + " 2", from: session)
            #expect(CreateHeader(replaced.code)?.definerAccount == ObjectCode.quotedAccount(me).replacingOccurrences(of: "`", with: ""),
                    "\(lab) \(kind): \(replaced.code)")
            await #expect(throws: (any Error).self, "\(lab) \(kind) old name") {
                try await ObjectDefinition.load(kind, database: database, name: name, from: session)
            }
        }
        try await run(["DROP DATABASE " + SQLQuote.identifier(database)], on: session)
    }

    @Test(arguments: servers)
    func drawsTheFixtureWithParentsBeforeChildren(_ lab: Lab.Server) async throws {
        let session = try await connected(lab)
        defer { Task { await session.close() } }
        let cache = SchemaCache(source: session, includes: { $0 == Lab.fixture })
        try await cache.load()
        let fixture = try #require(cache.snapshot.database(Lab.fixture))
        let diagram = ERDiagram(fixture)
        func column(_ name: String) -> Int? { diagram.columns.firstIndex { $0.contains { $0.name == name } } }
        let customers = try #require(column("customers")), orders = try #require(column("orders"))
        let items = try #require(column("order_items"))
        #expect(customers < orders && orders < items)
        #expect(diagram.columns.flatMap { $0 }.count == fixture.tables.filter { $0.kind == .table }.count)
        #expect(diagram.mermaid().contains("customers ||--o{ orders"))
    }

    /// A CREATE the server refuses is marked where the server points, in the code as it stands, ; in a body and all.
    @Test(arguments: servers)
    func aRefusedCreatePointsAtItsPlaceInTheCode(_ server: Lab.Server) async throws {
        let session = try await connected(server)
        _ = try await session.query("USE " + SQLQuote.identifier(Lab.fixture))  // Apply's first statement: else it's "No database selected"
        let code = "\n\nCREATE PROCEDURE lane_console2_p()\nBEGIN\n  SELECT 1;\n  SELEC 2;\nEND\n"
        do {
            _ = try await session.query(code.trimmingCharacters(in: .whitespacesAndNewlines))
            Issue.record("the server took it")
        } catch let error as AirSQLError {
            let said = error.details.isEmpty ? error.message : error.details
            let problem = ObjectCode.problem(said, shown: said, in: code, noBackslashEscapes: false)
            let place = (code as NSString).range(of: "2;").location  // both servers read SELEC as a word and stop at the 2
            #expect(problem?.range == place..<(place + 1), "\(said)")
        }
        await session.close()
    }
}
