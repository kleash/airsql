import Foundation
import Testing
@testable import AirSQLCore

/// Answers the introspection queries from a recording (SchemaFixtures.swift), and keeps the SQL it was sent.
final class ReplaySource: SchemaQuerying {
    var results: [String: [[String?]]]
    private(set) var sent: [String] = []

    init(_ recording: String) {
        results = Self.parse(recording)
    }

    /// The kind of statement during which the operation is cancelled, as Cancel in the activity list would.
    var cancelAt: String?

    func rows(_ sql: String) async throws -> [[String?]] {
        sent.append(sql)
        if let cancelAt, Self.kind(of: sql) == cancelAt {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return results[Self.kind(of: sql)] ?? []
    }

    /// Which recorded result a statement reads.
    static func kind(of sql: String) -> String {
        let kinds = [("VERSION()", "server"), ("SET SESSION", "setup"), ("TABLE_ROWS", "statistics"),
                     ("information_schema.SCHEMATA", "databases"), ("information_schema.CHECK_CONSTRAINTS", "checks"),
                     ("information_schema.TABLE_CONSTRAINTS", "checkTables"),
                     ("information_schema.KEY_COLUMN_USAGE", "foreignKeys"),
                     ("information_schema.REFERENTIAL_CONSTRAINTS", "foreignKeyRules"),
                     ("information_schema.COLUMNS", "columns"), ("information_schema.STATISTICS", "indexes"),
                     ("information_schema.ROUTINES", "routines"), ("information_schema.TRIGGERS", "triggers"),
                     ("information_schema.EVENTS", "events"), ("information_schema.TABLES", "tables")]
        return kinds.first { sql.contains($0.0) }?.1 ?? "unknown"
    }

    /// "== kind" lines, each followed by its rows (SchemaFixtures.swift says how they are written).
    static func parse(_ recording: String) -> [String: [[String?]]] {
        var results: [String: [[String?]]] = [:]
        var kind = ""
        for line in recording.split(separator: "\n") {
            if line.hasPrefix("== ") {
                kind = String(line.dropFirst(3))
                results[kind] = []
            } else {
                results[kind, default: []].append(row(line))
            }
        }
        return results
    }

    private static func row(_ line: Substring) -> [String?] {
        var values: [String?] = [], value = "", escaped = false, null = false
        for character in line {
            if escaped {
                switch character {
                case "N": null = true
                case "t": value.append("\t")
                case "n": value.append("\n")
                case "r": value.append("\r")
                default: value.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                values.append(null ? nil : value)
                value = ""
                null = false
            } else {
                value.append(character)
            }
        }
        values.append(null ? nil : value)
        return values
    }
}

/// A recorded server, for parameterized tests.
struct Recording: Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    var testDescription: String { name }

    static let all = [Recording(name: "MariaDB 11.8", text: SchemaFixtures.mariadb118),
                      Recording(name: "MariaDB 10.5", text: SchemaFixtures.mariadb105),
                      Recording(name: "MySQL 9.7", text: SchemaFixtures.mysql97),
                      Recording(name: "MySQL 8.4", text: SchemaFixtures.mysql84),
                      Recording(name: "MySQL 5.7", text: SchemaFixtures.mysql57)]
}

struct SchemaTests {
    static let fixtureDatabases = ["airsql_fixture", "airsql other"]

    /// A cache loaded from a recording, with the databases the recording was made with.
    static func loaded(_ text: String, threshold: Int = SchemaCache.defaultTableThreshold,
                       includes: @escaping (String) -> Bool = { fixtureDatabases.contains($0) })
        async throws -> (SchemaCache, ReplaySource) {
        let source = ReplaySource(text)
        let cache = SchemaCache(source: source, tableThreshold: threshold, includes: includes)
        try await cache.load()
        return (cache, source)
    }

    // MARK: What each server shows

    @Test(arguments: Recording.all)
    func loadsNamesAndDetailsTheSameWayOnEveryServer(_ recording: Recording) async throws {
        let (cache, _) = try await Self.loaded(recording.text)
        let snapshot = cache.snapshot
        let server = try #require(snapshot.server)
        let mariadb = server.flavour == .mariadb, mysql8 = server.flavour == .mysql && server.atLeast(8)
        #expect(snapshot.databases.map(\.name) == ["airsql other", "airsql_fixture"])
        #expect(snapshot.detailsUpfront && snapshot.databases.allSatisfy(\.detailsLoaded))
        #expect(snapshot.database("airsql other")?.charset == "latin1")
        let database = try #require(snapshot.database("airsql_fixture"))
        #expect(database.collation == "utf8mb4_unicode_ci")

        var names = ["customer_emails", "customers", "log", "order_lines", "orders", "we`ird 'name' ✓"]
        if mariadb { names += ["audit", "order_seq"] }
        #expect(database.tables.map(\.name) == names.sorted())
        #expect(database.table("customers")?.comment == "People who buy")
        #expect(database.table("log")?.engine == "MyISAM")
        let view = try #require(database.table("customer_emails"))
        #expect(view.kind == .view && view.engine == nil && view.comment == "" && view.columns.map(\.name) == ["id", "email"])
        if mariadb {
            #expect(database.table("order_seq")?.kind == .sequence)
            #expect(database.table("audit")?.systemVersioned == true)
            #expect(database.table("audit")?.column("address")?.dataType == "inet6")
        }

        #expect(database.routines.map(\.name) == ["add_customer", "order_count"])
        #expect(database.routines.first == SchemaRoutine(name: "add_customer", kind: .procedure, returns: nil, comment: "Adds one"))
        #expect(database.routines.last?.kind == .function && database.routines.last?.returns?.hasPrefix("int") == true)
        #expect(database.triggers == [
            SchemaTrigger(name: "orders_au", table: "orders", timing: "AFTER", event: "UPDATE", order: 1),
            SchemaTrigger(name: "orders_bi", table: "orders", timing: "BEFORE", event: "INSERT", order: 1)])
        #expect(database.events == [SchemaEvent(name: "purge_log", status: "DISABLED", comment: "Clears the log")])

        let customers = try #require(database.table("customers"))
        var columns = ["id", "email", "name", "note", "status", "flags", "balance", "bits", "created", "updated", "prefs",
                       "path", "token", "word", "secret", "email_domain", "name_upper"]
        if !mariadb && !mysql8 { columns.removeAll { $0 == "token" || $0 == "secret" } }
        #expect(customers.columns.map(\.name) == columns)
        let column = { (name: String) in customers.column(name) }
        #expect(column("id")?.defaultValue == SchemaDefault.none && column("id")?.autoIncrement == true)
        #expect(column("id")?.columnType.hasPrefix("int") == true && column("id")?.nullable == false)
        #expect(column("email")?.defaultValue == SchemaDefault.none)
        #expect(column("name")?.defaultValue == .value("it's"))
        #expect(column("note")?.defaultValue == .null && column("flags")?.defaultValue == .null)
        #expect(column("status")?.defaultValue == .value("new"))
        #expect(column("balance")?.defaultValue == .value("0.00"))
        #expect(column("bits")?.defaultValue == .expression("b'101'"))
        #expect(column("path")?.defaultValue == .value(#"C:\tmp"#))
        #expect(column("word")?.defaultValue == .value("NULL"))
        #expect(database.table("we`ird 'name' ✓")?.columns.map(\.name) == ["col `1", #"naïve "x""#])
        #expect(database.table("we`ird 'name' ✓")?.column(#"naïve "x""#)?.defaultValue == .value("a'b"))
        guard case .expression(let created) = column("created")?.defaultValue else {
            Issue.record("created: \(String(describing: column("created")?.defaultValue))")
            return
        }
        #expect(created.lowercased().hasPrefix("current_timestamp"))
        #expect(column("updated")?.onUpdate?.lowercased() == "current_timestamp(3)")
        #expect(column("prefs")?.isJSON == true && customers.columns.filter(\.isJSON).count == 1)
        #expect(column("email")?.collation == "utf8mb4_unicode_ci" && column("note")?.comment == "")
        if mariadb || mysql8 {
            #expect(column("token")?.defaultValue == .expression("uuid()"))
            #expect(column("secret")?.invisible == true && customers.columns.filter(\.invisible).count == 1)
        }
        let domain = try #require(column("email_domain")?.generated)
        #expect(!domain.stored && domain.expression.hasPrefix("substring_index(`email`,") && !domain.expression.contains("\\"))
        if mysql8 { #expect(domain.expression == "substring_index(`email`,_utf8mb4'@',-(1))") }
        #expect(column("name_upper")?.generated?.stored == true && column("email_domain")?.defaultValue == SchemaDefault.none)

        #expect(customers.indexes.map(\.name).contains("PRIMARY") && customers.primaryKey?.parts.map(\.column) == ["id"])
        #expect(customers.primaryKey?.unique == true)
        let index = { (name: String) in customers.indexes.first { $0.name == name } }
        #expect(index("email")?.unique == true && index("name_prefix")?.unique == false)
        #expect(index("name_prefix")?.parts.first?.prefixLength == 10)
        #expect(index("note_text")?.type == "FULLTEXT")
        let newer = mysql8 || mariadb && server.atLeast(10, 8)
        #expect(index("created_desc")?.parts.first?.descending == newer)
        #expect(index("created_desc")?.visible == !newer)
        if mysql8 {
            #expect(index("email_lower")?.parts == [SchemaIndex.Part(column: nil, expression: "lower(`email`)",
                                                                       prefixLength: nil, descending: false)])
        }
        #expect(database.table("order_lines")?.primaryKey?.parts.map(\.column) == ["region", "number", "line"])

        let orders = try #require(database.table("orders"))
        let rule = mariadb || !mysql8 ? "RESTRICT" : "NO ACTION"
        #expect(orders.foreignKeys == [
            SchemaForeignKey(name: "orders_customer", columns: ["customer_id"], referencedDatabase: "airsql_fixture",
                             referencedTable: "customers", referencedColumns: ["id"], onUpdate: "CASCADE", onDelete: "SET NULL"),
            SchemaForeignKey(name: "orders_parent", columns: ["parent_id"], referencedDatabase: "airsql_fixture",
                             referencedTable: "orders", referencedColumns: ["id"], onUpdate: rule, onDelete: "CASCADE")])
        #expect(database.table("order_lines")?.foreignKeys.first?.columns == ["region", "number"])
        #expect(database.table("order_lines")?.foreignKeys.first?.referencedColumns == ["region", "number"])
        #expect(snapshot.table("airsql other", "refs")?.foreignKeys == [
            SchemaForeignKey(name: "refs_ibfk_1", columns: ["customer_id"], referencedDatabase: "airsql_fixture",
                             referencedTable: "customers", referencedColumns: ["id"], onUpdate: rule, onDelete: rule)])

        if mariadb {
            #expect(orders.checks == [SchemaCheck(name: "total", clause: "`total` >= 0", enforced: true),
                                      SchemaCheck(name: "total_small", clause: "`total` < 1000000", enforced: true)])
            #expect(customers.checks == [SchemaCheck(name: "prefs", clause: "json_valid(`prefs`)", enforced: true)])
        } else if mysql8 {
            #expect(orders.checks == [SchemaCheck(name: "orders_chk_1", clause: "(`total` >= 0)", enforced: true),
                                      SchemaCheck(name: "total_small", clause: "(`total` < 1000000)", enforced: false)])
        } else {
            #expect(database.tables.allSatisfy { $0.checks.isEmpty }) // MySQL 5.7 ignores CHECK
        }
    }

    @Test(arguments: Recording.all)
    func loadsStatisticsForOneDatabase(_ recording: Recording) async throws {
        let (cache, source) = try await Self.loaded(recording.text)
        #expect(cache.snapshot.database("airsql_fixture")?.statistics == nil)
        let before = cache.snapshot.hash
        try await cache.loadStatistics("airsql_fixture")
        let statistics = try #require(cache.snapshot.database("airsql_fixture")?.statistics)
        #expect(statistics["customers"]?.dataLength == 16384 && statistics["customers"]?.collation == "utf8mb4_unicode_ci")
        #expect(statistics["customers"]?.createTime?.isEmpty == false && statistics["customer_emails"]?.rows == nil)
        #expect(cache.snapshot.database("airsql other")?.statistics == nil)
        #expect(cache.snapshot.hash == before) // statistics aren't structure
        let server = try #require(cache.snapshot.server)
        let setup = source.sent.contains("SET SESSION information_schema_stats_expiry = 0")
        #expect(setup == (server.flavour == .mysql && server.atLeast(8)))
        #expect(source.sent.last?.hasSuffix("WHERE TABLE_SCHEMA = 'airsql_fixture'") == true)
    }

    // MARK: Load on production (R11)

    @Test(arguments: Recording.all)
    func readsNamesFirstWithOneQueryPerKindAndNoTableStatistics(_ recording: Recording) async throws {
        let (_, source) = try await Self.loaded(recording.text)
        let kinds = source.sent.map(ReplaySource.kind(of:))
        let server = try #require(SchemaIntrospection.server(ReplaySource(recording.text).results["server"] ?? []))
        let checks = server.flavour == .mariadb ? ["checks"] : server.atLeast(8) ? ["checks", "checkTables"] : []
        #expect(kinds == ["server", "databases", "tables", "routines", "triggers", "events", "columns", "indexes",
                          "foreignKeys", "foreignKeyRules"] + checks)
        // Each of these makes MariaDB and MySQL 5.7 open every table (EXPLAIN: Open_full_table).
        for sql in source.sent {
            for column in ["TABLE_ROWS", "DATA_LENGTH", "AUTO_INCREMENT", "UPDATE_TIME", "CREATE_OPTIONS", "CARDINALITY"] {
                #expect(!sql.contains(column), "\(column) in \(sql)")
            }
        }
        // The filter goes to the server, so other databases aren't read.
        #expect(source.sent[2].contains("WHERE TABLE_SCHEMA IN (") && source.sent[2].contains("'airsql other'"))
    }

    @Test func readsEveryDatabaseWithoutAFilterClause() async throws {
        let (cache, source) = try await Self.loaded(SchemaFixtures.mariadb118, includes: { _ in true })
        #expect(cache.snapshot.databases.count == 6)
        #expect(!source.sent.contains { $0.contains("_SCHEMA IN") || $0.contains("_SCHEMA =") || $0.contains("_NAME IN") })
        let nothing = try await Self.loaded(SchemaFixtures.mariadb118, includes: { _ in false })
        #expect(nothing.0.snapshot.databases.isEmpty && nothing.1.sent.count == 2)
    }

    @Test func loadsDetailsPerDatabaseAboveTheThreshold() async throws {
        let (cache, source) = try await Self.loaded(SchemaFixtures.mariadb118, threshold: 8)
        var snapshot = cache.snapshot
        #expect(snapshot.tableCount == 9 && !snapshot.detailsUpfront)
        #expect(snapshot.databases.allSatisfy { !$0.detailsLoaded && $0.tables.allSatisfy(\.columns.isEmpty) })
        #expect(source.sent.map(ReplaySource.kind(of:)) == ["server", "databases", "tables", "routines", "triggers", "events"])

        try await cache.loadDetails(["airsql_fixture", "nowhere"])
        snapshot = cache.snapshot
        #expect(snapshot.database("airsql_fixture")?.detailsLoaded == true)
        #expect(snapshot.database("airsql other")?.detailsLoaded == false)
        #expect(snapshot.table("airsql other", "refs")?.columns.isEmpty == true)
        #expect(snapshot.table("airsql_fixture", "customers")?.columns.count == 17)
        let details = source.sent.dropFirst(6)
        #expect(details.count == 5 && details.allSatisfy { $0.contains("_SCHEMA = 'airsql_fixture'") })

        try await cache.loadDetails(["airsql_fixture"]) // already loaded: nothing to read
        #expect(source.sent.count == 11)

        // A reload reads again the details that were loaded, and only those.
        try await cache.load()
        snapshot = cache.snapshot
        #expect(snapshot.database("airsql_fixture")?.detailsLoaded == true)
        #expect(snapshot.database("airsql other")?.detailsLoaded == false)
        #expect(source.sent.dropFirst(11).filter { $0.contains("information_schema.COLUMNS") }
            == ["SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, DATA_TYPE, COLUMN_TYPE, IS_NULLABLE, "
                + "COLUMN_DEFAULT, EXTRA, GENERATION_EXPRESSION, CHARACTER_SET_NAME, COLLATION_NAME, COLUMN_COMMENT "
                + "FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = 'airsql_fixture'"])
    }

    @Test func publishesTheNamesBeforeTheDetailsOnTheFirstLoadOnly() async throws {
        let source = ReplaySource(SchemaFixtures.mysql84)
        let cache = SchemaCache(source: source, includes: { Self.fixtureDatabases.contains($0) })
        final class Published { var snapshots: [SchemaSnapshot] = [] }
        let published = Published()
        await MainActor.run { cache.onChange = { published.snapshots.append($0) } }
        try await cache.load()
        try await cache.load()
        try await cache.loadStatistics("airsql_fixture")
        let snapshots = await MainActor.run { published.snapshots } // after what the cache queued on the main queue
        #expect(snapshots.map { $0.databases.allSatisfy(\.detailsLoaded) } == [false, true, true, true])
        #expect(snapshots[0].databases.map(\.name) == ["airsql other", "airsql_fixture"])
        #expect(snapshots[1].hash == snapshots[2].hash && snapshots[0].hash != snapshots[1].hash)
    }

    // MARK: Schema hash

    @Test func hashesTheSameSchemaTheSameWayInAnyRowOrder() async throws {
        let mysql84 = try await Self.loaded(SchemaFixtures.mysql84).0.snapshot
        let mysql97 = try await Self.loaded(SchemaFixtures.mysql97).0.snapshot
        #expect(mysql84.hash.count == 16 && mysql84.hash == mysql97.hash)
        #expect(mysql84.databases.map(\.hash) == mysql97.databases.map(\.hash))
        let mariadb = try await Self.loaded(SchemaFixtures.mariadb118).0.snapshot
        #expect(mariadb.hash != mysql84.hash)
    }

    @Test func hashChangesWithTheStructureOfOneDatabaseOnly() async throws {
        let (cache, source) = try await Self.loaded(SchemaFixtures.mariadb118)
        let before = cache.snapshot
        // A comment on a column, the smallest change information_schema shows.
        let index = try #require(source.results["columns"]?.firstIndex { $0[1] == "orders" && $0[2] == "total" })
        source.results["columns"]?[index][12] = "Before tax"
        try await cache.load()
        let after = cache.snapshot
        #expect(after.hash != before.hash)
        #expect(after.database("airsql_fixture")?.hash != before.database("airsql_fixture")?.hash)
        #expect(after.database("airsql other")?.hash == before.database("airsql other")?.hash)
        #expect(after.table("airsql_fixture", "orders")?.column("total")?.comment == "Before tax")
    }

    // MARK: Refresh after DDL

    @Test func refreshesOnlyTheNamedTableAndTablesThatReferToIt() async throws {
        let (cache, source) = try await Self.loaded(SchemaFixtures.mariadb118)
        let before = cache.snapshot
        // ALTER TABLE customers ADD COLUMN vip BOOL NOT NULL DEFAULT 0
        source.results["columns"]?.append(["airsql_fixture", "customers", "vip", "18", "tinyint", "tinyint(1)", "NO", "0",
                                           "", nil, nil, nil, ""])
        let sent = source.sent.count
        try await cache.refresh([.table(database: "airsql_fixture", name: "customers")])
        let after = cache.snapshot
        #expect(after.table("airsql_fixture", "customers")?.columns.last?.name == "vip")
        #expect(after.table("airsql_fixture", "customers")?.columns.last?.defaultValue == .value("0"))
        #expect(after.database("airsql_fixture")?.hash != before.database("airsql_fixture")?.hash)
        #expect(after.table("airsql_fixture", "orders") == before.table("airsql_fixture", "orders"))
        #expect(after.database("airsql other") == before.database("airsql other"))

        let refresh = Array(source.sent.dropFirst(sent))
        #expect(refresh[0].hasSuffix("WHERE TABLE_SCHEMA = 'airsql_fixture' AND TABLE_NAME = 'customers'"))
        #expect(refresh[1].hasSuffix("WHERE TRIGGER_SCHEMA = 'airsql_fixture' AND EVENT_OBJECT_TABLE = 'customers'"))
        // orders refers to customers in this database, refs in the other one: their foreign keys are read again.
        #expect(refresh[2].hasSuffix("WHERE TABLE_SCHEMA = 'airsql_fixture' AND TABLE_NAME IN ('customers', 'orders')"))
        #expect(refresh.contains { $0.hasSuffix("WHERE TABLE_SCHEMA = 'airsql other' AND TABLE_NAME = 'refs'") })
        #expect(refresh.count == 2 + 5 + 5)
    }

    @Test func refreshDropsWhatIsGoneAndAddsWhatIsNew() async throws {
        let (cache, source) = try await Self.loaded(SchemaFixtures.mysql84)
        // DROP VIEW customer_emails; DROP FUNCTION order_count; CREATE EVENT tidy …
        source.results["tables"]?.removeAll { $0[1] == "customer_emails" }
        source.results["routines"]?.removeAll { $0[1] == "order_count" }
        source.results["events"]?.append(["airsql_fixture", "tidy", "ENABLED", ""])
        try await cache.refresh([.table(database: "airsql_fixture", name: "customer_emails"),
                                 .routine(database: "airsql_fixture", name: "order_count"),
                                 .event(database: "airsql_fixture", name: "tidy")])
        let database = try #require(cache.snapshot.database("airsql_fixture"))
        #expect(database.table("customer_emails") == nil && database.tables.count == 5)
        #expect(database.routines.map(\.name) == ["add_customer"])
        #expect(database.events.map(\.name) == ["purge_log", "tidy"])

        // DROP TRIGGER orders_au
        source.results["triggers"]?.removeAll { $0[1] == "orders_au" }
        try await cache.refresh([.trigger(database: "airsql_fixture", name: "orders_au")])
        #expect(cache.snapshot.database("airsql_fixture")?.triggers.map(\.name) == ["orders_bi"])
    }

    @Test func refreshReadsAWholeDatabaseWhenItIsNewOrGone() async throws {
        let (cache, source) = try await Self.loaded(SchemaFixtures.mariadb118, includes: { $0.hasPrefix("airsql") })
        // CREATE DATABASE `airsql new`; CREATE TABLE `airsql new`.t (id INT PRIMARY KEY)
        source.results["databases"]?.append(["airsql new", "utf8mb4", "utf8mb4_general_ci"])
        source.results["tables"]?.append(["airsql new", "t", "BASE TABLE", "InnoDB", ""])
        source.results["columns"]?.append(["airsql new", "t", "id", "1", "int", "int(11)", "NO", nil, "", nil, nil, nil, ""])
        try await cache.refresh([.table(database: "airsql new", name: "t")])
        #expect(cache.snapshot.databases.map(\.name) == ["airsql new", "airsql other", "airsql_fixture"])
        #expect(cache.snapshot.table("airsql new", "t")?.columns.map(\.name) == ["id"]) // details upfront

        // DROP DATABASE `airsql other`; and a database the filter leaves out
        source.results["databases"]?.removeAll { $0[0] == "airsql other" }
        try await cache.refresh([.database("airsql other"), .database("mysql")])
        #expect(cache.snapshot.databases.map(\.name) == ["airsql new", "airsql_fixture"])
    }

    @Test func refreshMatchesNamesWithoutCaseWhenTheServerDoes() async throws {
        let source = ReplaySource(SchemaFixtures.mariadb118)
        source.results["server"]?[0][1] = "1" // lower_case_table_names
        let cache = SchemaCache(source: source, includes: { Self.fixtureDatabases.contains($0) })
        try await cache.load()
        #expect(cache.snapshot.table("AIRSQL_FIXTURE", "Orders")?.name == "orders")
        source.results["tables"]?.removeAll { $0[1] == "log" }
        try await cache.refresh([.table(database: "airsql_fixture", name: "LOG")]) // DROP TABLE LOG
        #expect(cache.snapshot.database("airsql_fixture")?.table("log") == nil)
    }

    @Test func cancellingALoadStopsItsQueriesAndPublishesNothing() async throws {
        let source = ReplaySource(SchemaFixtures.mariadb118)
        source.cancelAt = "routines" // Cancel pressed while the routines query runs
        let cache = SchemaCache(source: source, includes: { Self.fixtureDatabases.contains($0) })
        await #expect(throws: CancellationError.self) { try await cache.load() }
        #expect(source.sent.map(ReplaySource.kind(of:)) == ["server", "databases", "tables", "routines"])
        #expect(cache.snapshot == SchemaSnapshot())
        source.cancelAt = nil
        try await cache.load() // the next operation runs as usual
        #expect(cache.snapshot.tableCount == 9)
    }

    @Test func clearForgetsEverythingAndALoadStartsAgain() async throws {
        let (cache, _) = try await Self.loaded(SchemaFixtures.mysql57)
        try await cache.loadStatistics("airsql_fixture")
        cache.clear()
        #expect(cache.snapshot == SchemaSnapshot())
        try await cache.refresh([.database("airsql_fixture")]) // nothing loaded: nothing to refresh
        try await cache.loadDetails(["airsql_fixture"])
        #expect(cache.snapshot == SchemaSnapshot())
        try await cache.load()
        #expect(cache.snapshot.tableCount == 7 && cache.snapshot.database("airsql_fixture")?.statistics == nil)
    }

    // MARK: Parsing

    @Test func parsesServerVersions() {
        let mariadb = SchemaServer(version: "11.8.9-MariaDB-ubu2404")
        #expect(mariadb.flavour == .mariadb && mariadb.version == [11, 8, 9] && mariadb.atLeast(10, 6) && !mariadb.atLeast(12))
        #expect(SchemaServer(version: "5.5.5-10.5.29-MariaDB").version == [10, 5, 29])
        let percona = SchemaServer(version: "8.0.36-28", lowerCaseTableNames: 2, sqlMode: "ANSI_QUOTES,NO_BACKSLASH_ESCAPES")
        #expect(percona.flavour == .mysql && percona.version == [8, 0, 36] && percona.atLeast(8, 0, 16))
        #expect(!percona.atLeast(8, 0, 37) && percona.noBackslashEscapes && percona.caselessNames)
        #expect(SchemaServer(version: "5.7.44").atLeast(5, 7) && !SchemaServer(version: "5.7.44").atLeast(8))
        #expect(SchemaServer(version: "8.0").atLeast(8) && !SchemaServer(version: "8.0").noBackslashEscapes)
    }

    @Test func readsMariaDBDefaults() {
        let introspection = SchemaIntrospection(server: SchemaServer(version: "10.11.9-MariaDB"))
        let parse = { (raw: String?) in introspection.columnDefault(raw, dataType: "varchar", nullable: true, extra: "") }
        #expect(parse(nil) == SchemaDefault.none)
        #expect(parse("NULL") == .null)
        #expect(parse("'NULL'") == .value("NULL"))
        #expect(parse("'it''s'") == .value("it's"))
        #expect(parse(#"'C:\\tmp'"#) == .value(#"C:\tmp"#))
        #expect(parse("'a\\nb\tc'") == .value("a\nb\tc"))
        #expect(parse("''") == .value(""))
        #expect(parse("'2020-01-02'") == .value("2020-01-02"))
        #expect(parse("0.00") == .value("0.00") && parse("-5") == .value("-5") && parse("1.5e3") == .value("1.5e3"))
        #expect(parse("current_timestamp()") == .expression("current_timestamp()"))
        #expect(parse("b'101'") == .expression("b'101'") && parse("x'6162'") == .expression("x'6162'"))
        #expect(parse("concat('a','b')") == .expression("concat('a','b')"))
        #expect(parse("'a' + 'b'") == .expression("'a' + 'b'"))
        #expect(parse("nextval(`seq`)") == .expression("nextval(`seq`)"))
    }

    @Test func readsMySQLDefaults() {
        let mysql8 = SchemaIntrospection(server: SchemaServer(version: "8.0.40"))
        let mysql57 = SchemaIntrospection(server: SchemaServer(version: "5.7.44"))
        #expect(mysql8.columnDefault(nil, dataType: "int", nullable: true, extra: "") == .null)
        #expect(mysql8.columnDefault(nil, dataType: "int", nullable: false, extra: "") == SchemaDefault.none)
        #expect(mysql8.columnDefault("NULL", dataType: "varchar", nullable: false, extra: "") == .value("NULL"))
        #expect(mysql8.columnDefault(#"concat(_utf8mb4\'a\',_utf8mb4\'b\')"#, dataType: "varchar", nullable: false,
                                     extra: "DEFAULT_GENERATED") == .expression("concat(_utf8mb4'a',_utf8mb4'b')"))
        #expect(mysql8.columnDefault("0x6162", dataType: "varbinary", nullable: true, extra: "") == .expression("0x6162"))
        #expect(mysql8.columnDefault("0x6162", dataType: "varchar", nullable: true, extra: "") == .value("0x6162"))
        #expect(mysql8.columnDefault("b'101'", dataType: "bit", nullable: false, extra: "") == .expression("b'101'"))
        #expect(mysql57.columnDefault("CURRENT_TIMESTAMP", dataType: "timestamp", nullable: false, extra: "")
            == .expression("CURRENT_TIMESTAMP"))
        #expect(mysql57.columnDefault("ab", dataType: "varbinary", nullable: true, extra: "") == .value("ab"))
        #expect(mysql57.columnDefault("0x41", dataType: "varbinary", nullable: true, extra: "") == .value("0x41"))
        #expect(mysql57.columnDefault(#"C:\tmp"#, dataType: "varchar", nullable: true, extra: "") == .value(#"C:\tmp"#))
    }

    @Test func undoesMySQL8EscapingOfExpressions() {
        let escaped = #"concat(`dq`,_utf8mb4\'it\\\'s\')"#
        #expect(SchemaIntrospection(server: SchemaServer(version: "8.4.13")).unescapedExpression(escaped)
            == #"concat(`dq`,_utf8mb4'it\'s')"#)
        #expect(SchemaIntrospection(server: SchemaServer(version: "9.7.4")).unescapedExpression(#"a\nb"#) == "a\nb")
        #expect(SchemaIntrospection(server: SchemaServer(version: "5.7.44")).unescapedExpression(escaped) == escaped)
        let mariadb = #"concat(`dq`,'it\'s')"#
        #expect(SchemaIntrospection(server: SchemaServer(version: "11.4.2-MariaDB")).unescapedExpression(mariadb) == mariadb)
    }

    @Test func quotesNamesInTheSQLItSends() {
        let plain = SchemaIntrospection(server: SchemaServer(version: "8.4.0"))
        #expect(plain.literal("it's") == #"'it\'s'"#)
        #expect(plain.literal(#"a\'b"#) == #"'a\\\'b'"#)
        let ansi = SchemaIntrospection(server: SchemaServer(version: "8.4.0", sqlMode: "NO_BACKSLASH_ESCAPES"))
        #expect(ansi.literal(#"a\'b"#) == #"'a\''b'"#)
        #expect(plain.tablesSQL(.objects(database: "we`ird 'db'", names: ["a", "b"])).hasSuffix(
            #"WHERE TABLE_SCHEMA = 'we`ird \'db\'' AND TABLE_NAME IN ('a', 'b')"#))
        #expect(plain.tablesSQL(.databases([])).hasSuffix("WHERE TABLE_SCHEMA IN (NULL)"))
    }

    @Test func choosesQueriesByServerVersion() {
        let sql = { (version: String) in SchemaIntrospection(server: SchemaServer(version: version)) }
        #expect(sql("5.7.44").checksSQL(.databases(nil)).isEmpty && sql("8.0.15").checksSQL(.databases(nil)).isEmpty)
        #expect(sql("8.0.16").checksSQL(.objects(database: "d", names: ["t"])) == [
            "SELECT CONSTRAINT_SCHEMA, CONSTRAINT_NAME, CHECK_CLAUSE FROM information_schema.CHECK_CONSTRAINTS "
                + "WHERE CONSTRAINT_SCHEMA = 'd'",
            "SELECT TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, ENFORCED FROM information_schema.TABLE_CONSTRAINTS "
                + "WHERE CONSTRAINT_TYPE = 'CHECK' AND TABLE_SCHEMA = 'd' AND TABLE_NAME = 't'"])
        #expect(sql("10.5.29-MariaDB").checksSQL(.databases(nil)).count == 1)
        #expect(sql("10.5.29-MariaDB").indexesSQL(.databases(nil)).contains("'YES', NULL FROM"))
        #expect(sql("10.6.1-MariaDB").indexesSQL(.databases(nil)).contains("IGNORED"))
        #expect(sql("8.0.12").indexesSQL(.databases(nil)).contains("IS_VISIBLE, NULL FROM"))
        #expect(sql("8.0.13").indexesSQL(.databases(nil)).contains("IS_VISIBLE, EXPRESSION FROM"))
        #expect(sql("5.7.44").statisticsSetupSQL == nil && sql("11.8.9-MariaDB").statisticsSetupSQL == nil)
        #expect(sql("8.0.3").statisticsSetupSQL != nil)
    }
}
