import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The recorded MariaDB 11.8 fixture (SchemaFixtures) as the editors' connection: its schema from the recording, the
/// editors' own reads answered from canned rows, and sessions that are never opened.
@MainActor
func recordedEditorContext(_ connection: SavedConnection = Fixtures.local) async throws -> EditorContext {
    let schema = SchemaCache(source: ReplaySource(SchemaFixtures.mariadb118), includes: { SchemaTests.fixtureDatabases.contains($0) })
    try await schema.load()
    let reads = CannedSource([
        "SELECT ENGINE, TABLE_COLLATION": [["InnoDB", "utf8mb4_unicode_ci", "", "41", "Dynamic"]],
        "SELECT CONSTRAINT_NAME": [["total"]],
        "SELECT FULL_COLLATION_NAME": [["utf8mb4_unicode_ci", "utf8mb4", "No"], ["utf8mb4_bin", "utf8mb4", "No"],
                                       ["utf8mb4_uca1400_ai_ci", "utf8mb4", "Yes"], ["latin1_swedish_ci", "latin1", "Yes"]],
        "SELECT ENGINE, SUPPORT": [["InnoDB", "DEFAULT"], ["Aria", "YES"], ["MyISAM", "YES"], ["MEMORY", "YES"]],
        "SELECT CURRENT_USER()": [["app@%"]],
        "SHOW CREATE PROCEDURE": [["add_customer", "STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION",
                                   "CREATE DEFINER=`root`@`localhost` PROCEDURE `add_customer`(IN p_name VARCHAR(100))\nBEGIN\n"
                                   + "  INSERT INTO customers (name) VALUES (p_name);\nEND", "utf8mb4", "utf8mb4_unicode_ci",
                                   "utf8mb4_unicode_ci"]],
    ])
    return EditorContext(connection: connection, sessions: Connection(options: ConnectOptions(name: "Recorded", host: "127.0.0.1", user: "app")),
                         schema: schema, reads: reads)
}

/// The text of the view with this accessibility id in `window` (a label's or a text view's).
@MainActor
func shownText(_ id: String, in window: NSWindow?) -> String? {
    guard let view = window?.contentView.flatMap({ find(NSView.self, id: id, in: $0) }) else { return nil }
    return (view as? NSTextView)?.string ?? (view as? NSTextField)?.stringValue
}

/// Waits until an editor has read what it shows.
@MainActor
func ready(_ busy: @escaping () -> Bool) async {
    _ = await eventually(timeout: 10) {
        try? await Task.sleep(nanoseconds: 20_000_000)
        return !busy()
    }
}

extension AppTests {
    @MainActor @Suite struct EditorsUITests {
        let database = "airsql_fixture"

        func tableEditor(_ table: String?, size: NSSize = MainWindowController.defaultSize)
            async throws -> (MainWindowController, AgentServer, TableEditorController) {
            let model = testModel([Fixtures.local])
            let (main, harness) = appWindow(model, size: size)
            main.openTableEditor(table, database: database, context: try await recordedEditorContext())
            let editor = try #require(main.selectedTab?.content as? TableEditorController)
            await ready { editor.isBusy || !editor.overlay.isHidden }
            main.window?.layoutIfNeeded()
            return (main, harness, editor)
        }

        @Test func tableEditorReadsTheTableAndWritesTheSQLAsItIsEdited() async throws {
            let (main, harness, editor) = try await tableEditor("orders")
            #expect(main.selectedTab?.title == "orders · structure")
            #expect(editor.list.numberOfRows == 6 && editor.sections.label(forSegment: 0) == "Columns · 6")
            #expect(editor.sqlText.string.hasPrefix("-- No changes yet") && !editor.applyButton.isEnabled)
            #expect(editor.design.columns.first { $0.name == "total" }?.check == "`total` >= 0", "MariaDB's column check stays with it")

            // + adds a column at the end and starts editing its name; typing names it.
            _ = await call(harness, "press", ["id": "tableEditor.add"])
            #expect(editor.list.numberOfRows == 7 && main.window?.firstResponder is NSTextView)
            _ = await call(harness, "type", ["text": "currency"])
            main.window?.makeFirstResponder(editor.list)
            #expect(editor.design.columns.last?.name == "currency")
            #expect(editor.sqlText.string.contains("ADD COLUMN `currency` varchar(255) NULL DEFAULT NULL AFTER `parent_id`"))
            #expect(editor.isEdited && editor.applyButton.isEnabled)

            // Apply shows the SQL in the preview sheet first; Cancel leaves everything as it was.
            _ = await call(harness, "press", ["id": "tableEditor.apply"])
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(shownText("preview.heading", in: main.window?.attachedSheet) == "Change the table airsql_fixture.orders?")
            #expect(shownText("preview.sql", in: main.window?.attachedSheet)?.contains("ADD COLUMN `currency`") == true)
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            #expect(editor.design.columns.count == 7)

            // Edit ▸ Undo takes the name, then the column, back out.
            main.window?.makeFirstResponder(editor.list)
            let undone = await call(harness, "menu", ["path": "Edit > Undo Change"])
            #expect(undone.error == nil, "\(undone.error ?? "")")
            let second = await call(harness, "menu", ["path": "Edit > Undo Change"])
            #expect(second.error == nil, "\(second.error ?? "") rows \(editor.list.numberOfRows) canUndo \(editor.undo.canUndo)")
            #expect(editor.list.numberOfRows == 6 && editor.sqlText.string.hasPrefix("-- No changes yet"))
        }

        @Test func theListAnswersClicksDoubleClicksAndRightClicks() async throws {
            let (main, harness, editor) = try await tableEditor("orders")
            let list = editor.list
            func middle(_ row: Int, _ column: Int) -> (Double, Double) {
                windowPoint(list.frameOfCell(atColumn: column, row: row), in: list)
            }
            let point = middle(2, 0)
            let reply = await call(harness, "click", ["x": point.0, "y": point.1])
            #expect(list.selectedRow == 2, "\(reply.error ?? "") at \(point); list \(list.convert(list.bounds, to: nil)) in \(main.window!.frame)")
            _ = await call(harness, "click", ["x": point.0, "y": point.1, "count": 2])
            #expect(main.window?.firstResponder is NSTextView, "a double-click edits the row's name")
            main.window?.makeFirstResponder(list)
            let other = middle(4, 1)
            let menu = await call(harness, "click", ["x": other.0, "y": other.1, "button": "right"])
            #expect(list.selectedRow == 4, "a right-click selects the row it is on: \(menu.error ?? "")")
            #expect(titles(menu["menu"]) == ["Add Row", "Duplicate Row", "Delete Rows…"])
            #expect((menu["menu"] as? [[String: Any]])?.allSatisfy { $0["enabled"] as? Bool == true } == true)
            _ = await call(harness, "menu", ["path": "context > Delete Rows…"])
            #expect(list.numberOfRows == 5 && editor.sqlText.string.contains("DROP COLUMN `total`"))
        }

        @Test func everyListSectionFitsTheEditorAtTheDefaultSize() async throws {
            let (main, _, editor) = try await tableEditor("orders")
            for section in TableEditorController.Section.allCases where section != .options {
                editor.sections.selectedSegment = section.rawValue
                editor.sectionChosen(editor.sections)
                main.window?.layoutIfNeeded()
                let visible = editor.listScroll.contentView.bounds.width
                #expect(editor.list.frame.width <= visible + 1, "\(section): the list is \(editor.list.frame.width) wide in \(visible)")
                for column in editor.list.tableColumns {
                    #expect(column.width >= column.minWidth - 0.5, "\(section) \(column.title): \(column.width) < \(column.minWidth)")
                }
            }
        }

        @Test func theTableEditorKeepsTheWindowAtItsMinimumSize() async throws {
            let (main, _, _) = try await tableEditor("orders", size: MainWindowController.minimumSize)
            #expect(main.window?.frame.width == MainWindowController.minimumSize.width)
        }

        @Test func theDiagramsBoxesHaveTheirWholeNamesInTooltipsAndForVoiceOver() throws {
            let fixtures = ERDiagramTests()
            let long = String(repeating: "customer_loyalty_points_", count: 3).prefix(64)
            let view = ERDiagramView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.show(ERDiagram(fixtures.database([fixtures.table(String(long)), fixtures.table("orders", pointsAt: [String(long)])])))
            let box = try #require(view.boxes.first { $0.table.name == long })
            let tip = view.view(view, stringForToolTip: 0, point: NSPoint(x: box.frame.midX, y: box.frame.midY), userData: nil)
            #expect(tip.hasPrefix(long + "\n"))
            let elements = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
            #expect(elements.map { $0.accessibilityLabel() ?? "" } == view.boxes.map { "Table \($0.table.name), \($0.table.columns.count) columns" })
            view.selected = "orders"
            #expect(elements.map { $0.isAccessibilitySelected() } == view.boxes.map { $0.table.name == "orders" })
        }

        @Test func columnsMoveAndOptionsChangeTheSQL() async throws {
            let (_, _, editor) = try await tableEditor("orders")
            editor.moveColumns(IndexSet(integer: 4), to: 0)
            #expect(editor.design.columns.first?.name == "total")
            #expect(editor.sqlText.string.contains("MODIFY COLUMN `total` decimal(12,2) NOT NULL CHECK (`total` >= 0) FIRST"))
            editor.sections.selectedSegment = TableEditorController.Section.options.rawValue
            editor.sectionChosen(editor.sections)
            #expect(!editor.options.isHidden && editor.options.name.stringValue == "orders")
            editor.options.comment.stringValue = "Paid or not"
            editor.options.comment.sendAction(editor.options.comment.action, to: editor.options.comment.target)
            #expect(editor.sqlText.string.contains("COMMENT='Paid or not'"))
            editor.revertChanges(nil)
            #expect(!editor.isEdited)
            for section in TableEditorController.Section.allCases.dropLast() {
                editor.sections.selectedSegment = section.rawValue
                editor.sectionChosen(editor.sections)
                #expect(editor.list.numberOfRows == [6, 4, 2, 2][section.rawValue], "\(section)")
            }
        }

        @Test func aNewTableStartsWithAKey() async throws {
            let (main, _, editor) = try await tableEditor(nil)
            #expect(main.selectedTab?.title == "New table" && editor.isEdited)
            #expect(editor.sqlText.string.contains("CREATE TABLE `airsql_fixture`.`new_table` (\n  `id` int unsigned NOT NULL AUTO_INCREMENT,"))
            #expect(editor.applyButton.isEnabled)
            // Return edits the selected row's name.
            editor.list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            main.window?.makeFirstResponder(editor.list)
            editor.list.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                                    windowNumber: main.window?.windowNumber ?? 0, context: nil,
                                                                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                                                                    keyCode: 36)))
            #expect(main.window?.firstResponder is NSTextView)
        }

        @Test func aReadOnlyConnectionCantApply() async throws {
            var connection = Fixtures.local
            connection.readOnly = true
            let (main, _) = appWindow(testModel([connection]))
            main.openTableEditor(nil, database: database, context: try await recordedEditorContext(connection))
            let editor = try #require(main.selectedTab?.content as? TableEditorController)
            await ready { editor.isBusy || !editor.overlay.isHidden }
            #expect(!editor.applyButton.isEnabled && editor.applyButton.toolTip?.contains("is read-only") == true)
        }

        @Test func theObjectEditorShowsTheCodeAndWhoItRunsAs() async throws {
            let model = testModel([Fixtures.local])
            let (main, harness) = appWindow(model)
            main.openObjectEditor(.procedure, name: "add_customer", database: database, context: try await recordedEditorContext())
            let editor = try #require(main.selectedTab?.content as? ObjectEditorController)
            await ready { editor.isBusy || !editor.overlay.isHidden }
            #expect(main.selectedTab?.title == "add_customer · procedure")
            #expect(editor.code.string.hasPrefix("CREATE DEFINER=`root`@`localhost` PROCEDURE"))
            #expect(editor.definer.itemTitles == ["Its definer, root@localhost", "Me, app@%"] && editor.definer.indexOfSelectedItem == 0)
            #expect(!editor.applyButton.isEnabled && editor.note.stringValue.contains("sql_mode: STRICT_TRANS_TABLES"))
            editor.definer.selectItem(at: 1)
            editor.definerChosen(editor.definer)
            #expect(editor.code.string.hasPrefix("CREATE PROCEDURE `add_customer`") && editor.applyButton.isEnabled)
            _ = await call(harness, "press", ["id": "objectEditor.apply"])
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let text = shownText("preview.sql", in: main.window?.attachedSheet) ?? ""
            #expect(text == "USE `airsql_fixture`;\nSET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION';\n"
                    + "CREATE OR REPLACE PROCEDURE `add_customer`(IN p_name VARCHAR(100))\nBEGIN\n"
                    + "  INSERT INTO customers (name) VALUES (p_name);\nEND;", "\(text)")
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            editor.revertChanges(nil)
            #expect(editor.code.string.hasPrefix("CREATE DEFINER=`root`@`localhost`"))
        }

        @Test func theDiagramLayersTablesAndOpensThem() async throws {
            let model = testModel([Fixtures.local])
            let (main, harness) = appWindow(model)
            main.openERDiagram(database: database, context: try await recordedEditorContext())
            let diagram = try #require(main.selectedTab?.content as? ERDiagramController)
            await ready { diagram.diagram == nil }
            main.window?.layoutIfNeeded()
            let boxes = diagram.canvas.boxes
            let x = { (name: String) in boxes.first { $0.table.name == name }?.frame.minX ?? -1 }
            #expect(x("customers") >= 0 && x("customers") < x("orders") && x("orders") < x("order_lines"))
            #expect(main.selectedTab?.title == "airsql_fixture · diagram" && diagram.exportMermaid.isEnabled)
            let box = try #require(boxes.first { $0.table.name == "orders" })
            let point = windowPoint(box.frame.insetBy(dx: 10, dy: 10), in: diagram.canvas)

            let reply = await call(harness, "click", ["x": point.0, "y": point.1])
            #expect(diagram.canvas.selected == "orders", "\(reply.error ?? "") at \(point); canvas \(diagram.canvas.convert(diagram.canvas.bounds, to: nil))")
            let menu = await call(harness, "click", ["x": point.0, "y": point.1, "button": "right"])
            #expect(titles(menu["menu"]) == ["Open Structure", "Copy Name"])
            _ = await call(harness, "click", ["x": point.0, "y": point.1, "count": 2])
            #expect(main.selectedTab?.title == "orders · structure")
            #expect(diagram.canvas.png().map { NSBitmapImageRep(data: $0)?.pixelsWide ?? 0 } == Int(diagram.canvas.bounds.width * 2))
        }

        @Test func everyEditorIsTidyAndSaysWhatItsControlsDo() async throws {
            var problems: [String] = [], missing: [String] = []
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for size in [MainWindowController.minimumSize, MainWindowController.defaultSize] {
                    let place = "\(appearance == .aqua ? "light" : "dark") \(Int(size.width))×\(Int(size.height))"
                    let model = testModel([Fixtures.local])
                    let (main, _) = appWindow(model, size: size)
                    let window = try #require(main.window)
                    window.appearance = NSAppearance(named: appearance)
                    let context = try await recordedEditorContext()
                    func check(_ what: String) {
                        window.layoutIfNeeded()
                        window.contentView?.layoutSubtreeIfNeeded()
                        if let content = window.contentView { problems += layoutProblems(content, where: "\(place) \(what)") }
                        missing += unexplained([window], where: "\(place) \(what)")
                    }
                    main.openTableEditor("orders", database: database, context: context)
                    let editor = try #require(main.selectedTab?.content as? TableEditorController)
                    await ready { editor.isBusy || !editor.overlay.isHidden }
                    for section in TableEditorController.Section.allCases {
                        editor.sections.selectedSegment = section.rawValue
                        editor.sectionChosen(editor.sections)
                        check("table editor \(section)")
                    }
                    main.openTableEditor(nil, database: database, context: context)
                    let fresh = try #require(main.selectedTab?.content as? TableEditorController)
                    await ready { fresh.isBusy || !fresh.overlay.isHidden }
                    check("new table")
                    main.openObjectEditor(.procedure, name: "add_customer", database: database, context: context)
                    let object = try #require(main.selectedTab?.content as? ObjectEditorController)
                    await ready { object.isBusy || !object.overlay.isHidden }
                    check("procedure editor")
                    main.openERDiagram(database: database, context: context)
                    let diagram = try #require(main.selectedTab?.content as? ERDiagramController)
                    await ready { diagram.diagram == nil }
                    check("ER diagram")
                }
            }
            #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
            #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
        }
    }
}
extension AppTests {
    @MainActor @Suite struct EditorsMenuTests {
        @Test func theDatabaseMenuOpensTheEditorsOfTheActiveConnection() async throws {
            _ = NSApplication.shared
            let bar = MainMenu.build()
            let database = try #require(bar.item(withTitle: "Database")?.submenu)
            #expect(database.items.filter { $0.action == Commands.createTable.action }.count == 1)
            #expect(database.item(withTitle: "New Object")?.submenu?.items.map(\.title) == ["View…", "Procedure…", "Function…", "Trigger…",
                                                                                            "Event…"])
            let model = testModel([Fixtures.local])
            let (main, harness) = appWindow(model)
            let connected = Editors.open
            defer { Editors.open = connected }
            // No connection chosen, then one that isn't connected: off, saying why.
            main.sidebar.select([])
            #expect(await call(harness, "menu", ["path": "Database > Create Table…"]).error?.contains("Choose a connection first") == true)
            main.sidebar.select([Fixtures.local.id])
            #expect(await call(harness, "menu", ["path": "Database > ER Diagram"]).error?.contains("Connect to Local MariaDB 11.8 first")
                    == true)
            // Connected: each opens its tab (they then read the server through it).
            let context = try await recordedEditorContext()
            Editors.open = { $1 == Fixtures.local.id ? (context.sessions, context.schema) : nil }
            _ = await call(harness, "menu", ["path": "Database > Create Table…"])
            #expect(main.selectedTab?.title == "New table")
            _ = await call(harness, "menu", ["path": "Database > New Object > Trigger…"])
            #expect(main.selectedTab?.title == "New trigger")
            _ = await call(harness, "menu", ["path": "Database > ER Diagram"])
            #expect((main.selectedTab?.content as? ERDiagramController) != nil)
        }
    }
}
