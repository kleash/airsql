import Foundation
import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// What the grid and its tools say, checked against the servers (AIRSQL_LAB=1): the 1.0.1 accuracy fixes.
@Suite(.serialized, .enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
struct AccuracyLabTests {
    static let database = "lane_data2_accuracy"
    static let quoted = SQLQuote.identifier(database)

    /// A data session with a fresh database, dropped again after `body`.
    func withDatabase(_ server: Lab.Server, _ statements: [String],
                      _ body: (DBConnection, SchemaSnapshot) async throws -> Void) async throws {
        let session = DBConnection(options: DBLab.options(server), role: .data, log: DBLab.log)
        try await session.connect()
        func finish() async {
            _ = try? await session.query("DROP DATABASE IF EXISTS \(Self.quoted)")
            await session.close()
        }
        do {
            for sql in ["DROP DATABASE IF EXISTS \(Self.quoted)", "CREATE DATABASE \(Self.quoted)"] + statements {
                _ = try await session.query(sql)
            }
            let cache = SchemaCache(source: session, includes: { $0 == Self.database })
            try await cache.load()
            try await body(session, cache.snapshot)
        } catch {
            await finish()
            throw error
        }
        await finish()
    }

    func source(_ snapshot: SchemaSnapshot, _ table: String) throws -> TableDataSource {
        TableDataSource(database: Self.database, table: try #require(snapshot.table(Self.database, table)))
    }

    /// The rows `condition` keeps, by the first column.
    func ids(_ session: DBConnection, _ source: TableDataSource, _ condition: GridCondition) async throws -> [String?] {
        source.filter = condition.sql()
        let rows = try await session.rows(source.pageSQL(offset: 0, limit: nil))
        return rows.map { $0[0] }
    }

    @Test(arguments: [Lab.mysql57, Lab.mysql84, Lab.mariadb105, Lab.mariadb114])
    func aFloatOrJSONCellFiltersToItself(_ server: Lab.Server) async throws {
        try await withDatabase(server, [
            "CREATE TABLE \(Self.quoted).m (id INT PRIMARY KEY, f FLOAT NULL, w FLOAT(10,2) NULL, j JSON NULL)",
            "INSERT INTO \(Self.quoted).m VALUES (1, 3.14159, 1234.5, '{\"b\": 1, \"a\": \"Ñx\"}'), (2, 1e20, 0.1, '[1, 2]'), "
                + "(3, -1.5e-10, 5, '{\"a\": \"ñx\"}'), (4, NULL, NULL, NULL)",
        ]) { session, snapshot in
            let source = try source(snapshot, "m")
            let page = try #require(try await session.query(source.pageSQL(offset: 0, limit: nil)).first?.rows)
            source.append(page, requested: nil)
            for column in 1...3 {
                for row in 0..<3 {
                    let cell = try #require(source.value(row, column)), id = source.value(row, 0)
                    #expect(try await ids(session, source, GridCondition(source.columns[column], .equals, [cell])) == [id],
                            "\(server) \(source.columns[column].name) = \(cell)")
                    #expect(try await ids(session, source, GridCondition(source.columns[column], .notEquals, [cell])).count == 2)
                }
                let cells = [source.value(0, column), source.value(1, column)]
                #expect(try await ids(session, source, GridCondition(source.columns[column], .isIn, cells + [nil])) == ["1", "2", "4"])
                #expect(try await ids(session, source, GridCondition(source.columns[column], .notIn, cells)) == ["3"])
            }
        }
    }

    /// `all_types` in the fixture: MySQL 8 calls the last column's type geomcollection.
    @Test(arguments: [Lab.mysql80, Lab.mysql84, Lab.mysql97, Lab.mariadb114])
    func aGeometryCollectionIsBinary(_ server: Lab.Server) async throws {
        let session = DBConnection(options: DBLab.options(server), role: .data, log: DBLab.log)
        try await session.connect()
        defer { Task { await session.close() } }
        let cache = SchemaCache(source: session, includes: { $0 == "fixture" })
        try await cache.load()
        try await cache.loadDetails(["fixture"])
        let table = try #require(cache.snapshot.table("fixture", "all_types"))
        let source = TableDataSource(database: "fixture", table: table)
        let index = try #require(source.columns.firstIndex { $0.name == "c_geometrycollection" })
        #expect(source.columns[index].kind == .binary)
        source.filter = try #require(GridFilter.search("anything", in: source.columns))
        _ = try await session.rows(source.pageSQL(offset: 0, limit: nil))  // no "Incorrect arguments to like"
        source.filter = ""
        let page = try #require(try await session.query(source.pageSQL(offset: 0, limit: nil)).first?.rows)
        source.append(page, requested: nil)
        let row = try #require((0..<source.rowCount).first { source.value($0, index) != nil })
        let cell = source.value(row, index)
        #expect(source.columns[index].literal(cell).hasPrefix("X'"))
        source.filter = GridCondition(source.columns[index], .equals, [cell]).sql()
        #expect(try await session.rows(source.pageSQL(offset: 0, limit: nil)).count >= 1)
    }

    @Test(arguments: [Lab.mysql84, Lab.mariadb114])
    func loadMoreSaysWhenRowsMovedBetweenPages(_ server: Lab.Server) async throws {
        try await withDatabase(server, [
            "CREATE TABLE \(Self.quoted).p (id INT PRIMARY KEY)",
            "INSERT INTO \(Self.quoted).p VALUES (1), (2), (3), (4), (5), (6), (7)",
        ]) { session, snapshot in
            let source = try source(snapshot, "p")
            func load(_ sql: String, _ limit: Int) async throws {
                source.append(try #require(try await session.query(sql).first?.rows), requested: limit)
            }
            try await load(source.pageSQL(offset: 0, limit: 2), 2)
            try await load(source.nextPageSQL(limit: 2), 3)
            #expect((0..<source.rowCount).map { source.value($0, 0) } == ["1", "2", "3", "4"] && !source.shifted && source.hasMore)
            // Someone deletes a row already read: the next page would miss 5.
            _ = try await session.query("DELETE FROM \(Self.quoted).p WHERE id = 1")
            try await load(source.nextPageSQL(limit: 2), 3)
            #expect(source.shifted, "\(server)")
            #expect((0..<source.rowCount).map { source.value($0, 0) } == ["1", "2", "3", "4", "5", "6", "7"])
            source.reset()
            #expect(!source.shifted)
        }
    }

    /// The server repeats the "table" key on these two.
    @Test(arguments: [Lab.mariadb105, Lab.mariadb106, Lab.mariadb114])
    func thePlanTreeKeepsEveryTable(_ server: Lab.Server) async throws {
        let session = DBConnection(options: DBLab.options(server), role: .data, log: DBLab.log)
        try await session.connect()
        defer { Task { await session.close() } }
        let sql = "SELECT * FROM fixture.customers c JOIN fixture.orders o ON o.customer_id = c.id "
            + "JOIN fixture.order_items i ON i.order_id = o.id"
        let answer = try #require(try await session.query(ExplainPlan.treeSQL(sql, server: session.server).sql).first?.rows?.string(0, 0))
        let tree = ExplainPlan.tree(fromJSON: answer)
        for table in ["Table c", "Table o", "Table i"] { #expect(tree.contains(table), "\(server): \(tree)") }
    }
}

extension AppTests {
    @MainActor @Suite(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh")) struct AccuracyAppLabTests {
        static let database = "lane_data2_accuracy_app"

        /// A table tab on `items` (three rows, two per page), with a schema session and the harness.
        func tab(_ lab: Lab.Server, rowsPerPage: Int = 2) async throws
            -> (tab: TableDataController, session: DBConnection, connection: Connection, harness: AgentServer) {
            let connection = Connection(options: DBLab.options(lab), log: DBLab.log)
            let session = try await connection.session(.schema)
            let quoted = SQLQuote.identifier(Self.database)
            for sql in ["DROP DATABASE IF EXISTS \(quoted)", "CREATE DATABASE \(quoted)",
                        "CREATE TABLE \(quoted).items (id INT PRIMARY KEY, name VARCHAR(20))",
                        "INSERT INTO \(quoted).items VALUES (1, 'Ann'), (2, 'Bob'), (3, 'Cy')"] {
                _ = try await session.query(sql)
            }
            let name = Self.database
            let schema = SchemaCache(source: session, includes: { $0 == name })
            try await schema.load()
            let saved = SavedConnection(name: "Lab \(lab)", host: "127.0.0.1", user: "airsql")
            let model = testModel([saved])
            model.data.settings.rowsPerPage = rowsPerPage
            let (main, harness) = appWindow(model)
            let context = EditorContext(connection: saved, sessions: connection, schema: schema)
            let tab = TableDataController(model: model, context: context, database: Self.database, table: "items")
            main.select(main.open(tab, title: "items", connection: saved.id))
            await ready { tab.loading != nil || tab.source == nil }
            return (tab, session, connection, harness)
        }

        func finish(_ session: DBConnection, _ connection: Connection) async {
            _ = try? await session.query("DROP DATABASE IF EXISTS \(SQLQuote.identifier(Self.database))")
            await connection.disconnect()
        }

        @Test(arguments: GridDataLabTests.servers)
        func refreshReadsTheTablesColumnsAgain(_ lab: Lab.Server) async throws {
            let (tab, session, connection, _) = try await tab(lab, rowsPerPage: 100)
            #expect(tab.source?.columns.count == 2)
            let items = SQLQuote.identifier(Self.database, "items")
            _ = try await session.query("ALTER TABLE \(items) ADD COLUMN extra INT NOT NULL DEFAULT 7, CHANGE name title VARCHAR(20)")
            tab.refresh(nil)
            await ready { tab.source?.columns.count != 3 || tab.loading != nil }
            #expect(tab.source?.columns.map(\.name) == ["id", "title", "extra"], "\(lab)")
            #expect(tab.viewer.source === tab.source && tab.source?.value(0, 2) == "7" && tab.problem == nil, "\(lab)")
            await finish(session, connection)
        }

        @Test(arguments: GridDataLabTests.servers)
        func aWrongEstimateIsNotBelieved(_ lab: Lab.Server) async throws {
            let (tab, session, connection, harness) = try await tab(lab)
            let filter = tab.source?.filter ?? ""
            tab.total = (0, false, filter)  // as InnoDB says of a table it hasn't sampled
            tab.updateBars()
            #expect(tab.viewer.status.rows.stringValue.hasPrefix("2 rows loaded"), "\(lab)")
            #expect(tab.knownTotal == nil)
            tab.loadAll(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "press", ["title": "Load All"])
            _ = await eventually(timeout: 30) { tab.source?.hasMore == false && tab.loading == nil }
            #expect(tab.viewer.status.rows.stringValue.hasPrefix("3 rows"), "\(lab)")
            #expect(tab.knownTotal?.rows == 3 && tab.source?.shifted == false)
            await finish(session, connection)
        }
    }
}
