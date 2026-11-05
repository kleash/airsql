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

    /// A CSV AirSQL wrote reads back as it was: NULL against the text NULL, bytes in a BLOB; a Windows-1252 file keeps
    /// its accents and says so; a value the server changed (non-strict) comes back as a warning.
    @Test(arguments: [Lab.mysql84, Lab.mariadb114])
    func csvRoundTrips(_ server: Lab.Server) async throws {
        try await withDatabase(server, [
            "CREATE TABLE \(Self.quoted).c (id INT PRIMARY KEY, t VARCHAR(20) NULL, b BLOB NULL)",
        ]) { session, snapshot in
            let columns = [GridColumn(name: "id", kind: .number), GridColumn(name: "t"), GridColumn(name: "b", kind: .binary)]
            let text = CopyWriter.text(.csv, columns: columns, rows: [["1", nil, "0x00FF"], ["2", "NULL", nil]], table: "c",
                                       options: CopyOptions(headers: true))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("c.csv")
            func run(_ data: Data, binary: Set<String> = ["b"]) async throws -> CSVImport.Progress {
                try data.write(to: file)
                var options = CSVImport.Options()
                options.binaryColumns = binary
                return try await CSVImport.run(.file(file), options: options, into: session, database: Self.database, table: "c",
                                               columns: ["id", "t", "b"], mapping: [0, 1, 2], cancellation: Cancellation()) { _ in }
            }
            #expect(try await run(Data(text.utf8)).note.isEmpty)
            let rows = try await session.rows("SELECT id, t, HEX(b) FROM \(Self.quoted).c ORDER BY id")
            #expect(rows == [["1", nil, "00FF"], ["2", "NULL", nil]], "\(server)")

            let latin = try await run(Data("id,t,b\n3,Caf".utf8) + Data([0xE9]) + Data(",\n".utf8))
            #expect(latin.notUTF8 && latin.note.contains("Windows-1252"))
            #expect(try await session.rows("SELECT t FROM \(Self.quoted).c WHERE id = 3") == [["Café"]])

            _ = try await session.query("SET SESSION sql_mode = ''")
            let cut = try await run(Data("id,t,b\n4,\(String(repeating: "x", count: 30)),\n".utf8))
            #expect(cut.warnings == 1 && cut.note.contains("warning"), "\(server)")
        }
    }

    /// Replaying an export: the server refuses a value for a generated column.
    @Test(arguments: [Lab.mysql84, Lab.mariadb114])
    func exportedInsertsSkipGeneratedColumnsAndRun(_ server: Lab.Server) async throws {
        try await withDatabase(server, [
            "CREATE TABLE \(Self.quoted).g (id INT PRIMARY KEY, a INT, twice INT AS (a * 2) STORED)",
            "INSERT INTO \(Self.quoted).g (id, a) VALUES (1, 4)",
        ]) { session, snapshot in
            let source = try source(snapshot, "g")
            source.append(try #require(try await session.query(source.pageSQL(offset: 0, limit: nil)).first?.rows), requested: nil)
            let row = source.columns.indices.map { source.value(0, $0) }
            let insert = CopyWriter.text(.insert, columns: source.columns, rows: [row], database: Self.database, table: "g",
                                         options: CopyOptions())
            #expect(!insert.contains("twice"), "\(insert)")
            _ = try await session.query("DELETE FROM \(Self.quoted).g")
            _ = try await session.query(insert.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ";", with: ""))
            #expect(try await session.rows("SELECT twice FROM \(Self.quoted).g") == [["8"]])
        }
    }

    /// BIT, ENUM and geometry in Column Summary, and what LIKE reads, all on the server.
    @Test(arguments: [Lab.mysql84, Lab.mariadb114])
    func summariesAndLikeReadWhatCellsShow(_ server: Lab.Server) async throws {
        try await withDatabase(server, [
            "CREATE TABLE \(Self.quoted).s (id INT PRIMARY KEY, b BIT(10) NULL, e ENUM('small','medium','it''s') NULL, "
                + "g POINT NULL, j JSON NULL, t LONGTEXT NULL, n SET('a','b') NULL)",
            "INSERT INTO \(Self.quoted).s VALUES (1, b'1010101010', 'medium', ST_GeomFromText('POINT(1 2)'), '{\"k\": \"AirSQL\"}', 'x', 'a'), "
                + "(2, b'0000000011', 'small', NULL, NULL, NULL, NULL), (3, NULL, 'it''s', NULL, NULL, NULL, NULL)",
        ]) { session, snapshot in
            let source = try source(snapshot, "s")
            func summary(_ name: String) async throws -> [String?] {
                let column = try #require(source.columns.firstIndex { $0.name == name })
                let row = try #require(try await session.rows(source.summarySQL(column)).first)
                return [row[2], row[3]]
            }
            #expect(try await summary("b") == ["0000000011", "1010101010"], "\(server)")
            #expect(try await summary("e") == ["small", "it's"], "\(server)")
            #expect(try await summary("g") == [nil, nil], "\(server)")
            func column(_ name: String) throws -> GridColumn { try #require(source.columns.first { $0.name == name }) }
            #expect(try await ids(session, source, GridCondition(try column("b"), .contains, ["0101"])) == ["1"], "\(server)")
            #expect(try await ids(session, source, GridCondition(try column("j"), .contains, ["airsql"])) == ["1"], "\(server)")
            let search = try #require(GridFilter.search("1010", in: source.columns))
            source.filter = search
            #expect(try await session.rows(source.pageSQL(offset: 0, limit: nil)).map { $0[0] } == ["1"], "\(server)")
            source.filter = ""
            let result = try #require(try await session.query("SELECT e, n, t FROM \(Self.quoted).s").first?.rows)
            #expect(result.columns.map(\.typeName) == ["enum", "set", "longtext"], "\(server)")
        }
    }

    /// An UPDATE that changes nothing says so: the server counts it as matched.
    @Test(arguments: [Lab.mysql84, Lab.mariadb114])
    func changedRowsAreNotMatchedRows(_ server: Lab.Server) async throws {
        try await withDatabase(server, [
            "CREATE TABLE \(Self.quoted).u (id INT PRIMARY KEY, a INT)", "INSERT INTO \(Self.quoted).u VALUES (1, 1), (2, 2)",
        ]) { session, _ in
            let same = try #require(try await session.query("UPDATE \(Self.quoted).u SET a = a").last)
            #expect(same.affectedRows == 2 && same.changedRows == 0, "\(server)")
            let insert = try #require(try await session.query("INSERT INTO \(Self.quoted).u VALUES (3, 3)").last)
            #expect(insert.changedRows == 1)
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

/// The accuracy fixes that need no server.
struct AccuracyTests {
    @Test func bigDecimalsKeepTheirDigits() {
        let long = "1234567.123456789012345678901234567890"
        let grouped = GridDisplay.grouped.format(long, bytes: nil)
        #expect(grouped?.filter(\.isNumber) == long.filter(\.isNumber))
        #expect(GridDisplay.decimals2.format("1234.565", bytes: nil)?.filter(\.isNumber) == "123457")
        let posix = Locale(identifier: "en_US_POSIX"), english = Locale(identifier: "en_US")
        #expect(GridAggregate.laidOut("-1234567.5", fraction: 2, grouping: true, english) == "-1,234,567.50")
        #expect(GridAggregate.laidOut("123", fraction: 0, grouping: true, english) == "123")
        #expect(GridAggregate.laidOut("1234.5", fraction: 0, grouping: false, posix) == "1234.5")
    }

    @Test func columnSummaryComparesLongNumbersExactly() {
        let summary = ColumnSummary(values: ["9007199254740993", "9007199254740992"])
        #expect(summary.minimum == "9007199254740992" && summary.maximum == "9007199254740993")
    }

    @Test func labelsTellNullFromItsText() {
        #expect(ColumnSummary.label(nil, nullText: "NULL") == "NULL" && ColumnSummary.label("NULL", nullText: "NULL") == "'NULL'")
        #expect(ColumnSummary.label("", nullText: "NULL") == "''" && ColumnSummary.label("Ann", nullText: "NULL") == "Ann")
    }

    @Test func localSortReadsLikeACollation() {
        #expect(GridSorting.compare("a10", "a9", number: false) == .orderedAscending)
        #expect(GridSorting.compare("Émile", "Zoe", number: false) == .orderedAscending)
        #expect(GridSorting.compare("1.10", "1.9", number: false) == .orderedAscending)
    }

    @Test func structureSeesOrderRowFormatAndPartitioning() {
        func column(_ name: String) -> SchemaColumn {
            SchemaColumn(name: name, dataType: "int", columnType: "int", nullable: true, defaultValue: .null, autoIncrement: false,
                         onUpdate: nil, generated: nil, invisible: false, isJSON: false, charset: nil, collation: nil, comment: "")
        }
        func database(_ names: [String], format: String, options: String) -> SchemaDatabase {
            var table = SchemaTable(name: "t", kind: .table, engine: "InnoDB")
            table.columns = names.map(column)
            var database = SchemaDatabase(name: "a", charset: "utf8mb4", collation: "utf8mb4_bin")
            database.tables = [table]
            var statistics = TableStatistics()
            statistics.rowFormat = format
            statistics.createOptions = options
            database.statistics = ["t": statistics]
            return database
        }
        let left = database(["a", "c", "b", "d"], format: "Dynamic", options: "partitioned")
        let right = database(["a", "b", "c", "d"], format: "Compact", options: "")
        let structure = ReconStructure(source: left, target: right, sourceServer: SchemaServer(version: "8.4.13"),
                                       targetServer: SchemaServer(version: "8.4.13"), options: ReconOptions())
        let parts = structure.compare(left.tables[0], right.tables[0])
        #expect(parts.filter(\.moved).map(\.name) == ["c"] && parts.first?.after == "a" && parts.first?.detail == "moved")
        #expect(parts.contains { $0.name == "row_format" && $0.definition == "ROW_FORMAT=DYNAMIC" })
        #expect(parts.contains { $0.name == "partitioning" && $0.definition.isEmpty })
        let same = ReconStructure(source: left, target: left, sourceServer: SchemaServer(version: "8.4.13"),
                                  targetServer: SchemaServer(version: "8.4.13"), options: ReconOptions())
        #expect(same.compare(left.tables[0], left.tables[0]).isEmpty)
    }

    @Test func csvWritesAndReadsNullApart() throws {
        let columns = [GridColumn(name: "a"), GridColumn(name: "b")]
        #expect(CopyWriter.text(.csv, columns: columns, rows: [[nil, "NULL"]], table: "t", options: CopyOptions()) == "NULL,\"NULL\"\n")
        var reader = CSVReader()
        reader.bareNullIsEmpty = true
        #expect(try reader.read(Data("NULL,\"NULL\",nullish\n".utf8)) + reader.finish() == [["", "NULL", "nullish"]])
        var plain = CSVReader()
        #expect(plain.read(Data("NULL\n".utf8)) == [["NULL"]])
        var latin = CSVReader()
        #expect(latin.read(Data([0x43, 0xE9, 0x0A])) == [["Cé"]] && latin.readWindows1252)
        var utf8 = CSVReader()
        #expect(utf8.read(Data("é\u{FFFD}\n".utf8)) == [["é\u{FFFD}"]] && !utf8.readWindows1252)
    }

    @Test func generatedColumnsStayOutOfSQLExports() {
        var twice = GridColumn(name: "twice")
        twice.marks = [.generated]
        let columns = [GridColumn(name: "id", kind: .number, isKey: true), GridColumn(name: "a", kind: .number), twice]
        let row: [[String?]] = [["1", "2", "4"]]
        #expect(CopyWriter.text(.insert, columns: columns, rows: row, table: "t", options: CopyOptions())
                == "INSERT INTO `t` (`id`, `a`) VALUES (1, 2);\n")
        #expect(CopyWriter.text(.update, columns: columns, rows: row, table: "t", options: CopyOptions())
                == "UPDATE `t` SET `a` = 2 WHERE `id` = 1;\n")
    }

    @MainActor @Test func invisibleCharactersShowInCells() {
        #expect(GridStyles.display("abc ") == "abc␣" && GridStyles.display("  ") == "␣␣" && GridStyles.display("a b") == "a b")
        #expect(GridStyles.display("a\u{200B}b") == "a␣b" && GridStyles.display("a\u{00A0}b") == "a⍽b")
        #expect(GridStyles.display("👩‍💻") == "👩‍💻" && GridStyles.display("x\ny\t") == "x↵y⇥" && GridStyles.display("Café") == "Café")
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
