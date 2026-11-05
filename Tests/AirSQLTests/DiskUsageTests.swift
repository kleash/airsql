import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The figures behind Disk Usage and the host page, and their statements.
struct DiskUsageTests {
    private func snapshot() -> SchemaSnapshot {
        var shop = SchemaDatabase(name: "shop", charset: "utf8mb4", collation: "utf8mb4_bin")
        shop.tables = [SchemaTable(name: "orders", kind: .table, engine: "InnoDB", comment: ""),
                       SchemaTable(name: "recent", kind: .view, engine: nil, comment: ""),
                       SchemaTable(name: "ids", kind: .sequence, engine: "InnoDB", comment: "")]
        shop.statistics = ["orders": TableStatistics(rows: 10, dataLength: 3_000, indexLength: 1_000, dataFree: 500),
                           "ids": TableStatistics(rows: 1, dataLength: 1_000, indexLength: 0, dataFree: 0)]
        var snapshot = SchemaSnapshot()
        snapshot.databases = [shop, SchemaDatabase(name: "unread", charset: "", collation: "")]
        return snapshot
    }

    @Test func aDatabaseAddsUpItsTablesAndViewsTakeNoSpace() throws {
        let rows = DiskUsage.databases(snapshot())
        let shop = try #require(rows.first)
        #expect(shop.total == 5_000 && shop.free == 500 && shop.rows == 11 && shop.detail == "2 tables")
        #expect(DiskUsage.tables(of: snapshot().databases[0]).map(\.name) == ["orders", "ids"])
        #expect(rows[1].total == nil && rows[1].rows == nil, "a database not read has no sizes, not zero")
    }

    @Test func aHugeFigureDoesNotStopTheApp() {
        let rows = [DiskUsageRow(name: "a", detail: "", data: .max), DiskUsageRow(name: "b", detail: "", data: 1)]
        #expect(DiskUsage.sum(rows, name: "").data == .max)
    }

    @Test func severalRowsSayWhatTheyComeTo() {
        let text = DiskUsage.summary([DiskUsageRow(name: "a", detail: "", data: 4_000, index: 0, free: 0, rows: 1_000),
                                      DiskUsageRow(name: "b", detail: "", data: 1_000, index: 0, free: 0, rows: 5)])
        #expect(text.hasPrefix("2 selected: 5 KB"))
        #expect(text.contains("about 1,005 rows") && text.hasSuffix("the largest is 4.0× the smallest"))
        #expect(DiskUsage.share(1, of: 8) == "12.5%" && DiskUsage.share(nil, of: 8) == "" && DiskUsage.share(0, of: 0) == "")
        #expect(DiskUsage.size(nil) == "" && DiskUsage.size(0) == "0 KB")
    }

    @Test func aTablesPartsAreQuotedAndParsed() {
        let table = DatabaseObject(.table, "it's", "o'dd")
        let sizes = DiskUsage.indexSizesSQL(table, noBackslashEscapes: true)
        #expect(sizes.contains("database_name = 'it''s'") && sizes.contains("= 'o''dd'"))
        #expect(DiskUsage.partitionsSQL(table, noBackslashEscapes: false).contains("TABLE_NAME = 'o\\'dd'"))
        let parts = DiskUsage.partitions([["p0", nil, "RANGE", "5", "16384", "0", "0"], ["p1", "s1", "RANGE", nil, nil, nil, nil],
                                          [nil, nil, nil, nil, nil, nil, nil]])
        #expect(parts.map(\.name) == ["p0", "p1 / s1"] && parts[0].data == 16_384 && parts[0].detail == "Partition (RANGE)")
        let indexes = DiskUsage.indexes(["PRIMARY", "by_name"], sizes: [["PRIMARY", "16384"], ["by_name", "32768.0000"],
                                                                        ["GEN_CLUST_INDEX", "1"]])
        #expect(indexes.map(\.name) == ["PRIMARY", "by_name"])
        #expect(indexes[0].data == 16_384 && indexes[0].index == nil && indexes[1].index == 32_768)
        #expect(DiskUsage.indexes(["a"], sizes: [])[0].total == nil, "a name stays when its size can't be read")
    }

    @Test func variablesStandSideBySide() throws {
        let found = HostFigures.variables(session: [["sql_mode", "A"], ["same", "1"], ["only_session", "x"]],
                                          global: [["sql_mode", "B"], ["same", "1"], ["only_global", "y"]])
        #expect(found.map(\.name) == ["only_global", "only_session", "same", "sql_mode"])
        #expect(found[0].session == nil && found[1].global == nil)
        #expect(found[3].differs && !found[2].differs && !found[0].differs)
    }

    @Test func countersAreRatedByTheServersUptime() throws {
        let counters = HostFigures.counters([["Uptime", "7200"], ["Questions", "14400"], ["Ssl_cipher", "AES"], ["Com_select", "30"],
                                             ["Com_insert", "10"], ["Com_drop_table", "0"], [nil, "1"]])
        let questions = try #require(counters.first { $0.name == "Questions" })
        #expect(questions.perHour == 7_200 && questions.perSecond == 2)
        #expect(counters.first { $0.name == "Ssl_cipher" }?.perHour == nil)
        let commands = HostFigures.commands(counters)
        #expect(commands.map(\.name) == ["select", "insert"], "the largest first, what never ran left out")
        #expect(commands[0].share == 0.75)
        #expect(HostFigures.counters([["Com_select", "3"]])[0].perHour == nil, "no uptime, no rate")
    }

    @Test func settingAVariableQuotesWhatIsNotANumber() {
        func set(_ value: String, global: Bool = true, noBackslashEscapes: Bool = false) -> String {
            HostFigures.setVariable("max`x", to: value, global: global, noBackslashEscapes: noBackslashEscapes)
        }
        #expect(set(" 100 ") == "SET GLOBAL `max``x` = 100")
        #expect(set("-1.5", global: false) == "SET SESSION `max``x` = -1.5")
        #expect(set("default") == "SET GLOBAL `max``x` = default")
        #expect(set("ON") == "SET GLOBAL `max``x` = 'ON'")
        #expect(set("1; DROP TABLE t") == "SET GLOBAL `max``x` = '1; DROP TABLE t'")
        #expect(set("a'b\\") == "SET GLOBAL `max``x` = 'a\\'b\\\\'")
        #expect(set("a\\", noBackslashEscapes: true) == "SET GLOBAL `max``x` = 'a\\'")
    }

    /// The read-only rule, and through it the agents' gate, must keep refusing what Edit Variable writes.
    @Test func settingAVariableIsNeverReadOnly() {
        for global in [true, false] {
            let sql = HostFigures.setVariable("sql_mode", to: "ANSI", global: global, noBackslashEscapes: false)
            #expect(!AgentGate.isReadOnly(sql, noBackslashEscapes: false), "\(sql)")
        }
    }

    @Test func selectTopAndEditDatabaseQuoteTheirNames() {
        #expect(NavigatorSQL.selectTop(DatabaseObject(.table, "s`b", "t")) == "SELECT *\nFROM `s``b`.`t`\nLIMIT 1000;")
        let sql = NavigatorSQL.alterCollation("s`b", "x'y", noBackslashEscapes: true)
        #expect(sql == "ALTER DATABASE `s``b` COLLATE 'x''y'" && !AgentGate.isReadOnly(sql, noBackslashEscapes: true))
    }

    @Test func listsExportAsCSV() {
        #expect(HostFigures.csv([["a", "b,c"], ["d\"e", ""]]) == "a,\"b,c\"\r\n\"d\"\"e\",\"\"\r\n")
    }
}

extension AppTests {
    @MainActor @Suite struct DiskUsageAppTests {
        private func opened() async -> (MainWindowController, OpenConnection) {
            let id = Fixtures.production.id
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            open.loadStatistics("airsql_fixture")
            _ = await eventually(timeout: 10) { open.snapshot.database("airsql_fixture")?.statistics != nil && open.loading.isEmpty }
            return (main, open)
        }

        @Test func itGoesFromTheServerIntoADatabaseAndBack() async throws {
            let (main, open) = await opened()
            let disk = DiskUsageContent(open)
            main.open(disk, title: "Disk Usage", connection: open.id)
            // The replay has no session to read through: the rest stays unread and says why.
            _ = await eventually(timeout: 10) { open.sizesProgress == nil }
            #expect(open.sizesError != nil && disk.list.caption.stringValue.contains("couldn't read every size"))
            let fixture = try #require(disk.list.rows.first, "the largest first, what's unread after it")
            #expect(fixture.key == "airsql_fixture" && fixture.bars["bar"]?.data ?? 0 > 0)
            #expect(disk.back.isHidden && disk.optimizeButton.isHidden)

            disk.list.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            disk.showDiskUsage(nil)
            #expect(disk.level == .database("airsql_fixture"))
            #expect(!disk.back.isHidden && !disk.list.rows.isEmpty)
            // At least the first table is as large as the next: sorted bars.
            let sizes = disk.list.rows.compactMap { $0.numbers["total"] }
            #expect(sizes == sizes.sorted(by: >))

            disk.list.table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
            #expect(disk.summary.stringValue.hasPrefix("2 selected:"))
            let kept = Set(disk.list.selected.map(\.key))
            disk.compareSelected(nil)
            #expect(Set(disk.list.rows.map(\.key)) == kept && disk.compareButton.title == "Show All")
            disk.compareSelected(nil)
            #expect(disk.list.rows.count > kept.count)

            disk.list.filter.stringValue = "^\(try #require(kept.first))$"
            disk.list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            #expect(disk.list.rows.count == 1 && disk.list.caption.stringValue.hasPrefix("1 of "))
            disk.list.copyList(nil)
            #expect(NSPasteboard.general.string(forType: .string)?.hasPrefix("Name,Size,Share,Data,Indexes,Free,Rows,Kind\r\n") == true)

            disk.goUp(nil)
            #expect(disk.level == .server && disk.list.filter.stringValue.isEmpty)
        }

        @Test func freeSpaceLeadsToOptimizeExceptWhenReadOnly() async throws {
            let (main, open) = await opened()
            let disk = DiskUsageContent(open, level: .database("airsql_fixture"))
            main.open(disk, title: "Disk Usage", connection: open.id)
            #expect(!disk.optimizeButton.isEnabled, "nothing selected")
            disk.list.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            #expect(disk.optimizeButton.isEnabled)
            var saved = try #require(open.model?.connection(open.id))
            saved.readOnly = true
            open.model?.save(saved)
            disk.reload()
            #expect(!disk.optimizeButton.isEnabled && disk.optimizeButton.toolTip?.contains("read-only") == true)
        }

        @Test func theDatabaseViewListsEveryKindOfObject() async throws {
            let (main, open) = await opened()
            let view = DatabaseViewController(open, "airsql_fixture")
            main.open(view, title: "airsql_fixture", connection: open.id)
            let kinds = Set(view.rows.map(\.kind))
            #expect(kinds.isSuperset(of: [.table, .view, .procedure, .trigger]))
            let routine = try #require(view.rows.firstIndex { $0.kind == .procedure })
            view.table.selectRowIndexes(IndexSet(integer: routine), byExtendingSelection: false)
            #expect(view.contextMenu()?.items.map(\.title).contains("Open") == true)
            #expect(view.contextMenu()?.items.map(\.title).contains("Truncate…") == false)
            let row = view.table.view(atColumn: view.table.column(withIdentifier: .init("type")), row: routine, makeIfNecessary: true)
            #expect((row as? NSTextField)?.stringValue == "procedure")
        }

        @Test func theDatabaseViewShowsBarsAndItsHeaderHidesColumns() async throws {
            let (main, open) = await opened()
            let view = DatabaseViewController(open, "airsql_fixture")
            main.open(view, title: "airsql_fixture", connection: open.id)
            view.view.layoutSubtreeIfNeeded()
            let column = view.table.column(withIdentifier: NSUserInterfaceItemIdentifier("bar"))
            #expect(view.table.view(atColumn: column, row: 0, makeIfNecessary: true) is SizeBar)
            let free = try #require(view.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("free")))
            #expect(free.isHidden)
            let item = try #require(view.table.headerView?.menu?.item(withTitle: "Free"))
            #expect(item.state == .off)
            _ = item.target?.perform(item.action, with: item)
            #expect(!free.isHidden && item.state == .on)
        }
    }

    @MainActor @Suite struct HostPageTests {
        private func opened(_ change: (inout SavedConnection) -> Void = { _ in }) async throws -> (MainWindowController, OpenConnection, HostContent) {
            var saved = Fixtures.staging
            change(&saved)
            let model = testModel([saved])
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, saved.id)
            let host = HostContent(open)
            main.open(host, title: "Host", connection: saved.id)
            host.show([HostFigures.Variable(name: "sql_mode", session: "A", global: "B"),
                       HostFigures.Variable(name: "max_connections", session: nil, global: "151")],
                      HostFigures.counters([["Uptime", "3600"], ["Com_select", "30"], ["Com_insert", "10"]]), server: nil)
            return (main, open, host)
        }

        @Test func aClickOnAConnectedConnectionShowsItsHostPageAndReusesIt() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, Fixtures.production.id)
            main.sidebar.select([open.id])
            _ = await eventually(timeout: 5) { main.selectedTab?.shown is HostContent }
            let host = try #require(main.selectedTab?.shown as? HostContent)
            #expect(main.selectedTab?.content is PreviewContent && host.pane == .databases)
            #expect(host.databases.rows.map(\.key).contains("airsql_fixture"))
            #expect(host.databases.rows.first { $0.key == "airsql_fixture" }?.numbers["tables"] ?? 0 > 0)
            main.showHost(open, pane: .commands)
            #expect(main.tabs.count == 1 && host.pane == .commands && host.tabs.selectedSegment == HostContent.Pane.commands.rawValue)
        }

        @Test func thePanesShowWhatTheServerSaid() async throws {
            let (_, _, host) = try await opened()
            host.show(.variables)
            #expect(host.variables.rows.map(\.key) == ["max_connections", "sql_mode"])
            #expect(host.variables.rows[1].cells["differs"] == "≠" && host.variables.rows[0].cells["session"] == "")
            host.show(.status)
            #expect(host.status.rows.first { $0.key == "Com_select" }?.cells["hour"] == "30")
            host.show(.commands)
            #expect(host.commands.rows.map(\.key) == ["select", "insert"] && host.commands.rows[0].cells["percent"] == "75.0%")
            host.commands.copyList(nil)
            #expect(NSPasteboard.general.string(forType: .string)?.hasPrefix("Statement,Count,Per Hour,Per Second,%\r\n") == true)
            host.show(.processes)
            #expect(host.processes.isViewLoaded && host.processes.view.superview != nil)
            host.processes.show([ServerProcess(id: 7, user: "u", host: "h", database: nil, command: "Query", time: 1, state: nil,
                                               info: "SELECT long", queryID: nil)])
            host.processes.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            #expect(host.processes.statement.string == "SELECT long")
        }

        @Test func editingAVariableIsRefusedInReadOnlyAndProduction() async throws {
            let (_, _, free) = try await opened()
            free.show(.variables)
            free.variables.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            #expect(free.edit.isEnabled)
            for change in [{ $0.readOnly = true }, { $0.colour = .production }] as [(inout SavedConnection) -> Void] {
                let (_, _, host) = try await opened(change)
                host.show(.variables)
                host.variables.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                #expect(!host.edit.isEnabled && host.edit.toolTip?.contains("can't be changed") == true)
                #expect(host.variables.caption.stringValue.contains("can't be changed"), "marked on the list too")
                let item = Commands.editVariable.item()
                #expect(!host.validateMenuItem(item) && item.toolTip?.contains("can't be changed") == true)
            }
        }
    }

    @MainActor @Suite(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh")) struct DiskUsageAppLabTests {
        static let database = "lane_host_disk"

        private func connected() async throws -> (AppModel, MainWindowController, OpenConnection) {
            let server = Lab.mariadb114
            let setup = DBConnection(options: DBLab.options(server), role: .tools, log: DBLab.log)
            try await setup.connect()
            let db = SQLQuote.identifier(Self.database)
            _ = try await setup.query("DROP DATABASE IF EXISTS \(db)")
            _ = try await setup.query("CREATE DATABASE \(db)")
            _ = try await setup.query("CREATE TABLE \(db).parts (id INT PRIMARY KEY, name VARCHAR(40), KEY by_name (name)) "
                                      + "PARTITION BY HASH (id) PARTITIONS 2")
            _ = try await setup.query("INSERT INTO \(db).parts VALUES (1, 'a'), (2, 'b'), (3, 'c')")
            _ = try await setup.query("ANALYZE TABLE \(db).parts")
            await setup.close()
            let saved = SavedConnection(name: "Lab", host: "127.0.0.1", port: server.port, user: Lab.airsql.user)
            let model = testModel([saved])
            let (main, _) = appWindow(model)
            let connection = Connection(options: DBLab.options(server), log: DBLab.log)
            try await connection.connect()
            let open = model.attach(connection, to: saved.id) { ![ "performance_schema", "sys"].contains($0) }
            _ = await eventually(timeout: 60) { open.snapshot.server != nil && open.loading.isEmpty }
            return (model, main, open)
        }

        @Test func itReadsDatabaseByDatabaseAndGoesIntoATablesParts() async throws {
            let (model, main, open) = try await connected()
            defer { model.detach(open.id) }
            let disk = DiskUsageContent(open)
            main.open(disk, title: "Disk Usage", connection: open.id)
            #expect(open.sizesProgress?.of == open.snapshot.databases.count, "every database, one at a time")
            #expect(model.activity.running.contains { $0.title.hasPrefix("Reading the sizes") && $0.canCancel })
            #expect(await eventually(timeout: 60) { open.sizesProgress == nil })
            #expect(open.sizesError == nil && open.snapshot.databases.allSatisfy { $0.statistics != nil })
            #expect(disk.list.rows.first { $0.key == Self.database }?.numbers["total"] ?? 0 > 0)

            disk.go(.table(Self.database, "parts"))
            #expect(await eventually(timeout: 20) { disk.tableRows.contains { $0.name == "p1" } })
            let rows = disk.tableRows
            #expect(rows.first { $0.name == "PRIMARY" }?.data ?? 0 > 0, "the index sizes add up the partitions'")
            #expect(rows.first { $0.name == "by_name" }?.index ?? 0 > 0)
            #expect(rows.first { $0.name == "p0" }?.detail == "Partition (HASH)")
            _ = try await open.connection.session(.schema).query("DROP DATABASE " + SQLQuote.identifier(Self.database))
        }

        @Test func theHostPageReadsTheServer() async throws {
            let (model, main, open) = try await connected()
            defer { model.detach(open.id) }
            let host = HostContent(open)
            main.open(host, title: "Host", connection: open.id)
            #expect(await eventually(timeout: 20) { host.properties.stringValue.contains("MariaDB 11.4") })
            host.show(.variables)
            #expect(host.variables.rows.contains { $0.key == "max_connections" && $0.cells["global"]?.isEmpty == false })
            host.show(.status)
            #expect(host.status.rows.first { $0.key == "Uptime" }?.numbers["value"] ?? 0 > 0)
            host.show(.commands)
            #expect(!host.commands.rows.isEmpty)
            #expect(await eventually(timeout: 60) { open.sizesProgress == nil && !open.snapshot.databases.contains { $0.statistics == nil } },
                    "a small server's sizes come by themselves")
            host.release()
            // What Edit writes is what the server takes: a number and a word, the shared lab left as it was.
            let session = try await open.connection.toolsSession()
            let connectTimeout = try #require(try await session.rows("SELECT @@GLOBAL.connect_timeout").first?.first ?? nil)
            _ = try await session.query(HostFigures.setVariable("connect_timeout", to: connectTimeout, global: true, noBackslashEscapes: false))
            _ = try await session.query(HostFigures.setVariable("sql_mode", to: "ANSI_QUOTES", global: false, noBackslashEscapes: false))
            #expect(try await session.rows("SELECT @@SESSION.sql_mode").first?.first == "ANSI_QUOTES")
            await session.close()
        }

        @Test func cancelStopsTheReadAndKeepsWhatItHas() async throws {
            let (model, _, open) = try await connected()
            defer { model.detach(open.id) }
            let names = open.snapshot.databases.map(\.name)
            open.readSizes(names + names + names)
            open.stopReadingSizes()
            #expect(await eventually(timeout: 20) { open.sizesProgress == nil })
            #expect(open.sizesError == nil, "stopping isn't a failure")
            #expect(!model.activity.running.contains { $0.title.hasPrefix("Reading the sizes") })
            open.readSizes(names)
            #expect(await eventually(timeout: 60) { open.sizesProgress == nil })
            #expect(open.snapshot.databases.allSatisfy { $0.statistics != nil }, "it can read again after a stop")
        }
    }
}
