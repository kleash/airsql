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
            #expect(titles(menu["menu"]) == ["Add Row", "Duplicate Row", "Copy", "Paste", "Move Up", "Move Down", "Delete Rows", "New Index from Columns",
                                             "New Unique Index from Columns", "Add to Index"])
            // Paste waits for rows copied.
            #expect((menu["menu"] as? [[String: Any]])?.filter { $0["enabled"] as? Bool != true }.map { $0["title"] as? String } == ["Paste"])
            _ = await call(harness, "menu", ["path": "context > Delete Rows"])
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
            view.show(ERDiagram(fixtures.database([fixtures.table(String(long)), fixtures.table("orders", pointsAt: [String(long)])])), layout: ERLayout(name: ""))
            let box = try #require(view.boxes.first { $0.table.name == long })
            let tip = view.view(view, stringForToolTip: 0, point: NSPoint(x: box.frame.midX, y: box.frame.midY), userData: nil)
            #expect(tip.hasPrefix(long + "\n"))
            let elements = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
            #expect(elements.map { $0.accessibilityLabel() ?? "" } == view.boxes.map {
                "Table \($0.table.name), \($0.table.columns.count) columns: " + $0.table.columns.map(\.name).joined(separator: ", ")
            })
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
            for (section, rows) in [(TableEditorController.Section.columns, 6), (.indexes, 4), (.foreignKeys, 2), (.checks, 2)] {
                editor.sections.selectedSegment = section.rawValue
                editor.sectionChosen(editor.sections)
                #expect(editor.list.numberOfRows == rows, "\(section)")
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

        /// ⌘C gives rows as CREATE TABLE lines, and ⌘V adds them, in this table or another, under names of their own.
        @Test func rowsCopyAsTheirDefinitionsAndPasteBetweenTables() async throws {
            let (_, _, editor) = try await tableEditor("customers")
            let (_, _, other) = try await tableEditor("orders")
            let paste = NSMenuItem(title: "Paste", action: Commands.paste.action, keyEquivalent: "")
            let before = other.design.columns.count
            other.section = .columns
            editor.section = .columns
            editor.list.selectRowIndexes([0], byExtendingSelection: false)
            let name = editor.design.columns[0].name
            editor.copy(nil)
            #expect(NSPasteboard.general.string(forType: .string)?.hasPrefix(SQLQuote.identifier(name) + " ") == true)
            #expect(other.validateMenuItem(paste))
            other.list.selectRowIndexes([0], byExtendingSelection: false)
            other.paste(nil)
            #expect(other.design.columns.count == before + 1)
            #expect(other.design.columns[1].original == nil && !other.design.columns[1].autoIncrement)
            #expect(other.list.selectedRow == 1)
            other.undo.undo()
            #expect(other.design.columns.count == before)
            // ⇧⌘↑ and ⇧⌘↓ move what's selected, and stop at the ends.
            let first = other.design.columns[0].name, second = other.design.columns[1].name
            other.list.selectRowIndexes([1], byExtendingSelection: false)
            other.moveRowsUp(nil)
            #expect(other.design.columns.prefix(2).map(\.name) == [second, first] && other.list.selectedRow == 0)
            other.moveRowsUp(nil)
            #expect(other.design.columns[0].name == second)
            other.moveRowsDown(nil)
            #expect(other.design.columns.prefix(2).map(\.name) == [first, second] && other.list.selectedRow == 1)
            // Text copied elsewhere since is not rows.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("x", forType: .string)
            #expect(!other.validateMenuItem(paste))
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
            #expect(main.selectedTab?.title == "airsql_fixture · diagram" && diagram.export.isEnabled)
            let box = try #require(boxes.first { $0.table.name == "orders" })
            let point = windowPoint(box.frame.insetBy(dx: 10, dy: 10), in: diagram.canvas)

            let reply = await call(harness, "click", ["x": point.0, "y": point.1])
            #expect(diagram.canvas.selected == "orders", "\(reply.error ?? "") at \(point); canvas \(diagram.canvas.convert(diagram.canvas.bounds, to: nil))")
            let menu = await call(harness, "click", ["x": point.0, "y": point.1, "button": "right"])
            #expect(titles(menu["menu"]) == ["Open Structure", "Open Data", "Copy Name", "Add Neighbours", "Remove from Diagram",
                                             "New Diagram from Selection…"])
            diagram.copy(nil)
            #expect(NSPasteboard.general.string(forType: .string) == "`orders`")
            diagram.find.stringValue = "CUSTOM"
            diagram.findTable(nil)
            #expect(diagram.canvas.selected == "customer_emails" || diagram.canvas.selected == "customers")
            diagram.fitAll(nil)
            let fitted = diagram.scroll.magnification
            #expect(fitted > 0 && fitted <= 3)
            diagram.zoomIn(nil)
            #expect(diagram.scroll.magnification > fitted)
            diagram.zoomReset(nil)
            #expect(diagram.scroll.magnification == 1)
            diagram.canvas.selected = "orders"
            _ = await call(harness, "click", ["x": point.0, "y": point.1, "count": 2])
            #expect(main.selectedTab?.title == "orders · structure")
            #expect(diagram.canvas.png().map { NSBitmapImageRep(data: $0)?.pixelsWide ?? 0 } == Int(diagram.canvas.bounds.width * 2))
        }

        @Test func aDiagramOfChosenTablesKeepsItsBoxesAndComesBack() async throws {
            let model = testModel([Fixtures.local])
            let (main, harness) = appWindow(model)
            let context = try await recordedEditorContext()
            main.openERDiagram(database: database, tables: ["orders"], neighbours: true, context: context)
            let diagram = try #require(main.selectedTab?.content as? ERDiagramController)
            await ready { diagram.diagram == nil }
            main.window?.layoutIfNeeded()
            let name = diagram.layout.name
            #expect(diagram.layouts.first?.tables == nil && diagram.layout.tables?.contains("orders") == true)
            #expect(diagram.layout.tables?.contains("customers") == true && !(diagram.layout.tables?.contains("tags") ?? true))
            #expect(diagram.canvas.boxes.count == diagram.layout.tables?.count)
            #expect(diagram.addTable.numberOfItems > 1, "the tables not drawn are offered")

            // Dragged with the mouse, the box stays where it was left; Undo takes it back.
            let box = try #require(diagram.canvas.boxes.first { $0.table.name == "orders" })
            let start = diagram.canvas.convert(NSPoint(x: box.frame.midX, y: box.frame.midY), to: nil)
            func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: main.window?.windowNumber ?? 0,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            diagram.canvas.mouseDown(with: event(.leftMouseDown, start))
            diagram.canvas.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: start.x + 30, y: start.y - 40)))
            diagram.canvas.mouseUp(with: event(.leftMouseUp, NSPoint(x: start.x + 30, y: start.y - 40)))
            let moved = try #require(diagram.layout.positions["orders"])
            #expect(moved.x == box.frame.minX + 30 && moved.y == box.frame.minY + 40)
            diagram.undo(nil)
            #expect(diagram.layout.positions.isEmpty)
            diagram.redo(nil)
            #expect(diagram.canvas.boxes.first { $0.table.name == "orders" }?.frame.minY == CGFloat(moved.y))

            // Taken off, added back by a drop, and what shows in a box.
            diagram.canvas.selected = "customers"
            diagram.removeFromDiagram(nil)
            #expect(!diagram.canvas.boxes.contains { $0.table.name == "customers" })
            diagram.add(["customers", "not_a_table"])
            #expect(diagram.canvas.boxes.contains { $0.table.name == "customers" } && diagram.layout.tables?.contains("not_a_table") == false)
            let item = Commands.detailNames.item()
            diagram.showDetail(item)
            #expect(diagram.canvas.boxes.allSatisfy { $0.shown.isEmpty && $0.more == 0 })
            diagram.arrangeBoxes(Commands.arrangeGrid.item())
            #expect(diagram.layout.positions.isEmpty && diagram.layout.arrangement == .grid)
            for format in DiagramExport.allCases { #expect(diagram.exported(format)?.isEmpty == false) }

            // Saved: a new tab on the database has it.
            TableViewSettingsStore.shared.flush()
            main.openERDiagram(database: database, context: context)
            let again = try #require(main.selectedTab?.content as? ERDiagramController)
            await ready { again.diagram == nil }
            #expect(again.diagrams.itemTitles == [ERLayout.wholeDatabase, name] && again.diagrams.indexOfSelectedItem == 0)
            again.diagrams.selectItem(at: 1)
            again.diagramChosen(again.diagrams)
            #expect(again.layout.arrangement == .grid && again.canvas.boxes.count == diagram.canvas.boxes.count)
            // Delete asks: Cancel keeps it.
            again.deleteDiagram(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            #expect(again.layouts.count == 2)
            again.deleteDiagram(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "press", ["title": "Delete"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            #expect(again.layouts.count == 1 && again.layout.tables == nil)
        }

        @Test func theTableEditorMakesIndexesFromColumnsAndShowsWhatPointsAtIt() async throws {
            let model = testModel([Fixtures.local])
            let (main, _) = appWindow(model)
            let context = try await recordedEditorContext()
            main.openTableEditor("customers", database: database, context: context)
            let editor = try #require(main.selectedTab?.content as? TableEditorController)
            await ready { editor.before == nil }
            #expect(editor.incoming.contains { $0.table == "orders" })
            editor.showSection(.references)
            #expect(editor.list.numberOfRows == editor.incoming.count && !editor.addButton.isEnabled)
            #expect(editor.sections.label(forSegment: TableEditorController.Section.references.rawValue)?.hasPrefix("Used by · ") == true)
            editor.list.selectRowIndexes([0], byExtendingSelection: false)
            editor.deleteRows(nil)
            #expect(!editor.isEdited, "this list isn't the table's own to change")

            editor.showSection(.columns)
            editor.list.selectRowIndexes([1, 0], byExtendingSelection: false)
            editor.uniqueFromColumns(nil)
            #expect(editor.section == .indexes)
            let made = try #require(editor.design.indexes.last)
            #expect(made.kind == .unique && made.parts.compactMap(\.column) == Array(editor.design.columns.prefix(2).map(\.name)))

            // A column added to it, then the SQL of how it is stored and that it is unused.
            editor.showSection(.columns)
            editor.list.selectRowIndexes([2], byExtendingSelection: false)
            let item = NSMenuItem(title: made.name, action: nil, keyEquivalent: "")
            item.tag = editor.design.indexes.count - 1
            editor.addColumnsToIndex(item)
            #expect(editor.design.indexes.last?.parts.count == 3)
            editor.update { $0.indexes[$0.indexes.count - 1].visible = false }
            #expect(editor.sqlText.string.contains("ADD UNIQUE INDEX") && editor.sqlText.string.contains("IGNORED"))

            // The clause shows as SQL as it is typed, and Revert takes it back.
            editor.showSection(.partitions)
            editor.partitionsView.code.setText("PARTITION BY HASH (id) PARTITIONS 2")
            editor.partitionsView.textDidChange(Notification(name: NSText.didChangeNotification))
            #expect(editor.sqlText.string.contains("PARTITION BY HASH (id) PARTITIONS 2"))
            editor.revertChanges(nil)
            #expect(editor.partitionsView.code.string.isEmpty && !editor.isEdited)
        }

        @Test func newRowCommandsLandOnTheirSections() async throws {
            for (command, section) in [(Commands.newColumn, TableEditorController.Section.columns), (Commands.newIndex, .indexes),
                                       (Commands.newForeignKey, .foreignKeys)] {
                #expect(TableEditorController.Section(rawValue: command.tag) == section, "\(command.title)")
                let (_, _, editor) = try await tableEditor("orders")
                let rows = editor.design.columns.count + editor.design.indexes.count + editor.design.foreignKeys.count
                editor.addOnceLoaded(section)
                #expect(editor.section == section && editor.sections.selectedSegment == section.rawValue && !editor.listColumn.isHidden)
                #expect(editor.design.columns.count + editor.design.indexes.count + editor.design.foreignKeys.count == rows + 1)
            }
            // Asked for before the table is read, it waits for it.
            let model = testModel([Fixtures.local])
            let (main, _) = appWindow(model)
            main.openTableEditor("orders", database: database, context: try await recordedEditorContext())
            let early = try #require(main.selectedTab?.content as? TableEditorController)
            early.addOnceLoaded(.indexes)
            await ready { early.section != .indexes }
            #expect(early.design.indexes.count == (early.before?.indexes.count ?? 0) + 1)
        }

        @Test func aChangeCanGoToAQueryTabInsteadOfRunning() async throws {
            let (main, harness, editor) = try await tableEditor("orders")
            editor.update { $0.options.comment = "x" }
            editor.applyChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "press", ["title": "Open in Query Tab"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            let console = try #require(main.selectedTab?.content as? ConsoleViewController)
            #expect(console.editor.string.hasPrefix("ALTER TABLE `airsql_fixture`.`orders`") && editor.isEdited)
        }

        @Test func aFormWritesToTheCodeAndFollowsIt() async throws {
            let model = testModel([Fixtures.local])
            let (main, _) = appWindow(model)
            main.openObjectEditor(.procedure, name: "add_customer", database: database, context: try await recordedEditorContext())
            let editor = try #require(main.selectedTab?.content as? ObjectEditorController)
            await ready { editor.isBusy }
            let form = editor.form
            #expect(form.name.stringValue == "add_customer" && form.parameters.numberOfRows == 1)
            form.add(nil)
            #expect(editor.code.string.contains("(IN `p_name` VARCHAR(100), IN `p_2` INT)") && editor.applyButton.isEnabled)
            form.moveParameterUp(nil)
            #expect(editor.code.string.contains("(IN `p_2` INT, IN `p_name` VARCHAR(100))"))
            form.deterministic.state = .on
            form.edited(form.deterministic)
            #expect(editor.code.string.contains(")\nDETERMINISTIC\nBEGIN\n"))
            editor.code.undoManager?.undo()
            #expect(!editor.code.string.contains("DETERMINISTIC"), "one undo takes a field's change back")

            // What is typed in the code shows in the fields; code they can't read turns them off and says so.
            editor.code.replace(NSRange(location: 0, length: editor.code.string.utf16.count), with: "CREATE PROCEDURE `other`()\nNO SQL\nBEGIN\nEND")
            #expect(form.name.stringValue == "other" && form.parameters.numberOfRows == 0 && form.access.titleOfSelectedItem == "NO SQL")
            editor.code.replace(NSRange(location: 0, length: editor.code.string.utf16.count), with: "CREATE PROCEDURE `other`(IN")
            #expect(!form.name.isEnabled && !form.hint.isHidden)

            // A new event starts readable, and Once at swaps the fields.
            main.openObjectEditor(.event, name: nil, database: database, context: try await recordedEditorContext())
            let event = try #require(main.selectedTab?.content as? ObjectEditorController)
            await ready { event.isBusy }
            #expect(event.form.every.stringValue == "1" && event.form.state.titleOfSelectedItem == "Disabled" && event.form.at.isHidden)
            event.form.schedule.selectItem(at: 1)
            event.form.at.stringValue = "2031-01-01 00:00:00"
            event.form.edited(event.form.schedule)
            #expect(event.code.string.contains("ON SCHEDULE AT '2031-01-01 00:00:00'") && !event.form.at.isHidden && event.form.every.isHidden)
        }

        @Test func aRoutineRunsOnlyAsTheServerHasIt() async throws {
            let model = testModel([Fixtures.local])
            let (main, _) = appWindow(model)
            main.openObjectEditor(.procedure, name: "add_customer", database: database, context: try await recordedEditorContext())
            let editor = try #require(main.selectedTab?.content as? ObjectEditorController)
            await ready { editor.isBusy }
            #expect(!editor.runButton.isHidden && editor.runButton.isEnabled)
            editor.code.setText(editor.code.string + " ")
            editor.updateControls()
            #expect(!editor.runButton.isEnabled && editor.runButton.toolTip?.hasPrefix("Apply your changes first") == true)
        }

        @Test func theGeneratorShowsLiveDDLAndWritesAFilePerObject() async throws {
            let model = testModel([Fixtures.local])
            let (main, _) = appWindow(model)
            var context = try await recordedEditorContext()
            context.reads = CannedSource([
                "SHOW CREATE TABLE": [["orders", "CREATE TABLE `orders` (\n  `id` int NOT NULL,\n  KEY `x` (`id`)\n) ENGINE=InnoDB"]],
                "SHOW CREATE TRIGGER": [["t", "", "CREATE TRIGGER `t` BEFORE INSERT ON `orders` FOR EACH ROW SET @a = 1"]],
            ])
            let generator = SQLGeneratorController(context: context, objects: [DatabaseObject(.table, database, "orders")], activity: model.activity)
            main.open(generator, title: generator.tabTitle, connection: context.connection.id)
            await ready { generator.text.string.isEmpty }
            #expect(generator.text.string.hasPrefix("CREATE TABLE `orders` (") && generator.text.string.contains("KEY `x`"))
            #expect(generator.text.string.contains("CREATE TRIGGER `t`"), "the table's triggers come with it")
            for option in [\DDLScript.Options.indexes, \.triggers] {
                let box = try #require(generator.boxes.first { $0.1 == option }?.0)
                box.state = .off
                generator.optionChanged(box)
            }
            #expect(generator.text.string == "CREATE TABLE `orders` (\n  `id` int NOT NULL\n) ENGINE=InnoDB;\n")
            generator.openInConsole(nil)
            let console = try #require(main.selectedTab?.content as? ConsoleViewController)
            #expect(console.editor.string.hasPrefix("CREATE TABLE `orders`"))
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
                    for kind in [ObjectKind.function, .trigger, .event, .view] {
                        main.openObjectEditor(kind, name: nil, database: database, context: context)
                        let new = try #require(main.selectedTab?.content as? ObjectEditorController)
                        await ready { new.isBusy || !new.overlay.isHidden }
                        check("\(kind) editor")
                        #expect(window.frame.size.width <= max(size.width, MainWindowController.minimumSize.width) + 1, "\(kind) widens the window")
                    }
                    let generator = SQLGeneratorController(context: context, objects: [], activity: model.activity)
                    main.open(generator, title: generator.tabTitle, connection: context.connection.id)
                    await ready { !generator.copyButton.isEnabled }
                    check("SQL Generator")
                    #expect(window.frame.size.width <= max(size.width, MainWindowController.minimumSize.width) + 1, "the generator widens the window")
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
