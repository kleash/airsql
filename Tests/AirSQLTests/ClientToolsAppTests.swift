import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The client tools' screens with demo data (no server, no tools run): the shop's databases and tables, a mysqldump
/// and a mariadb-dump, a MariaDB 11.8 server.
@MainActor
enum ToolFixtures {
    static let server = ServerInfo(flavor: .mariadb, version: "11.8.3-MariaDB", versionNumber: 110803, threadID: 7, tls: nil,
                                   certificate: nil)
    static let dumps = [ClientTool(path: "/opt/homebrew/opt/mariadb/bin/mariadb-dump", version: ToolVersion(family: .mariadb, numbers: [11, 8, 3])),
                        ClientTool(path: "/opt/homebrew/opt/mysql-client/bin/mysqldump", version: ToolVersion(family: .mysql, numbers: [9, 6, 0]))]
    static let clients = [ClientTool(path: "/opt/homebrew/opt/mariadb/bin/mariadb", version: ToolVersion(family: .mariadb, numbers: [11, 8, 3]))]
    static let options = ConnectOptions(name: "Local MariaDB 11.8", host: "localhost", endpoint: .socket("/tmp/mysql.sock"),
                                        user: "root", password: "demo")

    static func databases() -> [PickerNode] {
        let rows: [[String?]] = [
            ["shop", "audit_log", "BASE TABLE", "51000000", "6100000000"],
            ["shop", "customers", "BASE TABLE", "412000", "98000000"],
            ["shop", "order_items", "BASE TABLE", "9800000", "1400000000"],
            ["shop", "orders", "BASE TABLE", "2400000", "1600000000"],
            ["shop", "paid_orders", "VIEW", nil, nil],
            ["shop", "this_table_name_is_sixty_four_characters_long_the_most_mysql_has", "BASE TABLE", "12", "16384"],
            ["crm", "contacts", "BASE TABLE", "8800", "1500000"],
        ]
        return PickerNode.databases(["crm", "shop", "empty_one"], tables: rows)
    }

    static let customerColumns: [(name: String, type: String)] = [("id", "int(11)"), ("name", "varchar(100)"), ("email", "varchar(255)"),
                                                                  ("this_column_name_is_long_enough_to_need_an_ellipsis_in_the_sheet", "text")]

    static var local: SavedConnection {
        var connection = Fixtures.local
        connection.database = "shop"
        return connection
    }
}

extension AppTests {
    @MainActor @Suite struct ClientToolsAppTests {
        /// A window with the local connection selected (the tools' commands are in its chain from the start).
        static func window(_ given: [SavedConnection]? = nil) -> (MainWindowController, AgentServer) {
            let connections = given ?? [ToolFixtures.local]
            let (main, harness) = appWindow(testModel(connections + [Fixtures.staging]))
            main.sidebar.select([connections[0].id])
            main.refresh()
            return (main, harness)
        }

        static func exportSheet(on main: MainWindowController) -> ExportSheet {
            let sheet = ExportSheet(model: main.model, connection: ToolFixtures.local, options: ToolFixtures.options)
            sheet.show(on: main.window!, loads: false)
            sheet.show(server: ToolFixtures.server, tools: ToolFixtures.dumps, databases: ToolFixtures.databases())
            return sheet
        }

        static func text(_ server: AgentServer, _ id: String) async -> String {
            let reply = await call(server, "snapshot", ["include": ["elements"], "in": "sheet"])
            let node = (reply["elements"] as? [[String: Any]])?.first { $0["id"] as? String == id }
            return node?["value"] as? String ?? node?["title"] as? String ?? ""
        }

        @Test func theToolsCommandsWorkOnADirectOrConnectedConnectionAndSayWhyNotElsewhere() async throws {
            let (main, _) = Self.window()
            let tools = try #require(main.nextResponder as? ToolsResponder)
            for action in [Commands.export.action, Commands.restore.action, Commands.runSQLFile.action, Commands.openInTerminal.action] {
                #expect(tools.availability(action).0, "\(action)")
            }
            main.sidebar.select([Fixtures.staging.id])
            main.refresh()
            #expect(tools.availability(Commands.export.action).1?.contains("SSH") == true)
            // Connected, an SSH route works too: the tools go through its socket.
            _ = await openReplayed(main.model, Fixtures.staging.id)
            #expect(tools.availability(Commands.export.action).0)
            var readOnly = ToolFixtures.local
            readOnly.readOnly = true
            let (other, _) = Self.window([readOnly])
            let otherTools = try #require(other.nextResponder as? ToolsResponder)
            #expect(otherTools.availability(Commands.export.action).0)
            #expect(otherTools.availability(Commands.restore.action).1?.contains("read-only") == true)
            // The menu bar has the lane's items, each saying what it does.
            let bar = try #require(NSApp.mainMenu)
            let file = try #require(bar.item(withTitle: "File")?.submenu), toolsMenu = try #require(bar.item(withTitle: "Tools")?.submenu)
            #expect(file.item(withTitle: "Run SQL File…") != nil && file.item(withTitle: "Import CSV…") != nil)
            #expect(toolsMenu.items.map(\.title).starts(with: ["Open in Terminal", "Export…", "Restore…", "Copy to Another Server…"]))
        }

        @Test func theExportSheetShowsTheCommandItRunsAndWhyItCantRunYet() async throws {
            let (main, harness) = Self.window()
            let sheet = Self.exportSheet(on: main)
            defer { sheet.close() }
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            // The connection's database is ticked whole; its best tool (MariaDB's, for MariaDB) is chosen.
            #expect(sheet.runButton.isEnabled, "\(sheet.runButton.toolTip ?? "")")
            var command = await Self.text(harness, "export.command")
            #expect(command.hasPrefix("/opt/homebrew/opt/mariadb/bin/mariadb-dump --defaults-file=‹private temporary file› "
                                      + "--protocol=SOCKET --socket=/tmp/mysql.sock"), "\(command)")
            #expect(command.hasSuffix(" shop > " + ToolCommand.shellWord(NSHomeDirectory()) + "/Downloads/" + command.split(separator: "/").last!))
            #expect(!command.contains("demo"))
            // Leaving out a table lists the others; gzip changes the file's name.
            _ = await call(harness, "press", ["id": "tools.include.audit_log"])
            _ = await call(harness, "press", ["id": "export.gzip"])
            command = await Self.text(harness, "export.command")
            #expect(command.contains(" shop customers order_items orders paid_orders this_table_name"), "\(command)")
            #expect(command.contains("| /usr/bin/gzip -c > ") && command.hasSuffix(".sql.gz"))
            // A password in the extra options is refused, with the reason on Export.
            _ = await call(harness, "set", ["id": "export.extra", "value": "--password=secret"])
            sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            #expect(!sheet.runButton.isEnabled && sheet.runButton.toolTip?.contains("password") == true)
            _ = await call(harness, "set", ["id": "export.extra", "value": ""])
            sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            // AirSQL's own export: no command line, binary is always hex, no extra options.
            _ = await call(harness, "set", ["id": "export.tool", "value": "AirSQL (built in)"])
            let builtIn = await Self.text(harness, "export.command")
            #expect(sheet.runButton.isEnabled && builtIn.hasPrefix("AirSQL writes the SQL itself"), "\(builtIn)")
            #expect(sheet.window?.contentView.flatMap { find(NSButton.self, id: "export.hexBlob", in: $0) }?.isEnabled == false)
            _ = await call(harness, "set", ["id": "export.tool", "value": "mariadb-dump 11.8.3"])
            // A partly ticked database ticks whole, then not at all: Export then says what to do.
            _ = await call(harness, "press", ["id": "tools.include.shop"])
            let whole = await Self.text(harness, "export.command")
            #expect(sheet.runButton.isEnabled && whole.contains(" --skip-add-drop-table shop | /usr/bin/gzip -c > "), "\(whole)")
            _ = await call(harness, "press", ["id": "tools.include.shop"])
            #expect(!sheet.runButton.isEnabled && sheet.runButton.toolTip == "Tick the databases or tables to export")
        }

        @Test func theRestoreSheetWaitsForAFileAndShowsHowItRunsIt() async throws {
            let (main, harness) = Self.window()
            let sheet = RestoreSheet(model: main.model, connection: ToolFixtures.local, options: ToolFixtures.options, builtIn: false)
            sheet.show(on: main.window!, loads: false)
            defer { sheet.close() }
            sheet.show(server: ToolFixtures.server, tools: ToolFixtures.clients, databases: ["crm", "shop"])
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(!sheet.runButton.isEnabled && sheet.runButton.toolTip == "Choose the file to run first")
            sheet.use(URL(fileURLWithPath: "/Volumes/Backups/shop-2026-11-03.sql.gz"))
            #expect(sheet.runButton.isEnabled)
            let command = await Self.text(harness, "restore.command")
            #expect(command == "/usr/bin/gzip -dc /Volumes/Backups/shop-2026-11-03.sql.gz | /opt/homebrew/opt/mariadb/bin/mariadb "
                + "--defaults-file=‹private temporary file› --protocol=SOCKET --socket=/tmp/mysql.sock "
                + "--default-character-set=utf8mb4 --batch shop", "\(command)")
        }

        @Test func theCopySheetSaysWhereItCopiesAndRefusesToCopyOntoItself() async throws {
            var replica = Fixtures.local
            replica.id = UUID()
            replica.name = "Local replica"
            var locked = Fixtures.local
            locked.id = UUID()
            locked.name = "Locked"
            locked.readOnly = true
            let (main, harness) = Self.window([ToolFixtures.local, replica, locked])
            let sheet = CopySheet(model: main.model, connection: ToolFixtures.local, options: ToolFixtures.options)
            sheet.show(on: main.window!, loads: false)
            defer { sheet.close() }
            sheet.show(databases: ToolFixtures.databases())
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            // The same server and the same name: refused; another name is fine.
            _ = await call(harness, "set", ["id": "copy.target", "value": "Local replica"])
            #expect(!sheet.runButton.isEnabled && sheet.runButton.toolTip?.contains("this server") == true, "\(sheet.runButton.toolTip ?? "")")
            _ = await call(harness, "set", ["id": "copy.database", "value": "shop_copy"])
            sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            #expect(sheet.runButton.isEnabled, "\(sheet.runButton.toolTip ?? "")")
            let summary = await Self.text(harness, "copy.summary")
            #expect(summary.hasPrefix("CREATE DATABASE IF NOT EXISTS `shop_copy` …;\nUSE `shop_copy`;\nCREATE TABLE … (5 tables);"), "\(summary)")
            // Replacing tables is marked, and said in the summary.
            _ = await call(harness, "press", ["id": "copy.replace"])
            #expect((await Self.text(harness, "copy.summary")).contains("DROP TABLE IF EXISTS … (5 tables);"))
            // A read-only connection can't be copied to.
            _ = await call(harness, "set", ["id": "copy.target", "value": "Locked"])
            #expect(!sheet.runButton.isEnabled && sheet.runButton.toolTip?.contains("read-only") == true)
        }

        @Test func theCSVSheetMapsFieldsByNameAndShowsASample() async throws {
            let (main, harness) = Self.window()
            let sheet = CSVImportSheet(model: main.model, connection: ToolFixtures.local, options: ToolFixtures.options)
            sheet.show(on: main.window!, loads: false)
            defer { sheet.close() }
            sheet.show(databases: ToolFixtures.databases())
            sheet.show(columns: ToolFixtures.customerColumns)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(!sheet.runButton.isEnabled && sheet.runButton.toolTip == "Choose the CSV file first")
            let file = URL(fileURLWithPath: try scratch() + "/people.csv")
            try "Email;NAME;phone\nada@example.com;Ada Lovelace;\n".write(to: file, atomically: true, encoding: .utf8)
            sheet.use(file)
            _ = await eventually(timeout: 5) { sheet.runButton.isEnabled }
            // By name, whatever the case; the separator guessed; a column without a field keeps its default.
            #expect(sheet.runButton.isEnabled, "\(sheet.runButton.toolTip ?? "")")
            #expect(await Self.text(harness, "csv.map.name") == "NAME (field 2)")
            #expect(await Self.text(harness, "csv.map.email") == "Email (field 1)")
            #expect(await Self.text(harness, "csv.map.id") == "Leave out (its default)")
            #expect(await Self.text(harness, "csv.separator") == "Semicolon")
            #expect(await Self.text(harness, "csv.sample.name") == "Ada Lovelace")
            _ = await call(harness, "set", ["id": "csv.map.name", "value": "Leave out (its default)"])
            _ = await call(harness, "set", ["id": "csv.map.email", "value": "Leave out (its default)"])
            #expect(!sheet.runButton.isEnabled && sheet.runButton.toolTip == "Choose the field at least one column takes")
        }

        @Test func thePickerTicksWithAClickADoubleClickSpaceAndItsMenu() async throws {
            let (main, harness) = Self.window()
            let sheet = Self.exportSheet(on: main)
            defer { sheet.close() }
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let picker = try #require(sheet.window?.contentView.flatMap { find(PickerOutline.self, in: $0) })
            let shop = try #require((0..<picker.numberOfRows).first { (picker.item(atRow: $0) as? PickerNode)?.name == "customers" })
            // Space ticks or unticks the selected rows.
            picker.selectRowIndexes(IndexSet(integer: shop), byExtendingSelection: false)
            let customers = try #require(picker.item(atRow: shop) as? PickerNode)
            #expect(customers.included)
            picker.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
                                                  keyCode: 49)!)
            #expect(!customers.included && customers.parent?.state == .mixed)
            // The right-click menu: include, leave out, only these, all, none.
            let menu = try #require(picker.menu)
            menu.delegate?.menuNeedsUpdate?(menu)
            #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                == ["Include", "Leave Out", "Include Only These", "Include All", "Include None"])
            #expect(menu.items.allSatisfy { $0.isSeparatorItem || $0.toolTip?.isEmpty == false })
        }
    }
}
