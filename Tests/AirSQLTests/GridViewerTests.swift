import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// A tab hosting a `GridViewer`, as the table tab and console results do.
@MainActor
final class ViewerContent: NSViewController, TabContent {
    let viewer: GridViewer

    init(_ source: GridSource, key: GridViewer.ViewKey? = nil) {
        viewer = GridViewer(source: nil)
        viewer.viewKey = key
        super.init(nibName: nil, bundle: nil)
        viewer.show(source)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() { view = viewer }
    var statusAccessory: NSView? { viewer.status }
}

/// Lane L2's reading tools on a grid: the status bar's figures, Go to Row, the column list and columns kept per table.
extension AppTests {
    func viewerWindow(_ source: GridSource, key: GridViewer.ViewKey? = nil)
        -> (main: MainWindowController, harness: AgentServer, content: ViewerContent) {
        let (main, harness) = appWindow(testModel(Fixtures.shop), size: NSSize(width: 1200, height: 760))
        let content = ViewerContent(source, key: key)
        main.open(content, title: "customers", connection: Fixtures.production.id)
        main.window?.layoutIfNeeded()
        main.window?.makeFirstResponder(content.viewer.grid)
        return (main, harness, content)
    }

    @Test func statusShowsThePositionAndAFigureForTheSelection() async throws {
        let source = FakeGridSource(rows: 100, columns: 10)
        let (main, harness, content) = viewerWindow(source)
        let grid = content.viewer.grid, status = content.viewer.status
        #expect(main.statusBar.accessory.arrangedSubviews.first === status)
        #expect(status.figure.isHidden)
        // amount_2: rows 0 to 3.
        grid.selection.select(GridPosition(row: 0, column: 2))
        grid.selection.select(GridPosition(row: 3, column: 2), extend: true)
        let values = (0..<4).compactMap { source.value($0, 2) }
        let sum = GridAggregate(values).text(.sum)!
        #expect(status.figure.title == "Sum \(sum)")
        #expect(status.copyText == GridAggregate(values).copyText(.sum))
        #expect(await call(harness, "menu", ["path": "Edit > Copy Selection Summary"]).error == nil)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        #expect(copied.hasPrefix("Count\t4\nSum\t") && copied.contains("\nMedian\t"))
        // Words: the count instead of a sum.
        grid.selection.selectColumn(1)
        #expect(status.figure.title == "Count 100")
        #expect(status.position.stringValue == "r4 : c2 · 1 column")
    }

    @Test func goToRowTakesANumberOrAColumnAndARow() async throws {
        let (main, harness, content) = viewerWindow(FakeGridSource(rows: 5_000, columns: 12))
        let grid = content.viewer.grid
        #expect(await call(harness, "menu", ["path": "Data > Go to Row…"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        _ = await call(harness, "type", ["text": "amount_2:4000"])
        #expect(await call(harness, "press", ["title": "Go"]).error == nil)
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(grid.selection.cursor == GridPosition(row: 3_999, column: 2))
        #expect(grid.visibleRect.intersects(grid.cellRect(GridPosition(row: 3_999, column: 2))))
        #expect(main.window?.firstResponder === grid)
        // A row past the end beeps and leaves the cursor.
        #expect(await call(harness, "menu", ["path": "Data > Go to Row…"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        _ = await call(harness, "type", ["text": "5001"])
        _ = await call(harness, "press", ["title": "Go"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(grid.selection.cursor == GridPosition(row: 3_999, column: 2))
    }

    @Test func columnListFindsJumpsShowsAndHides() async throws {
        let (_, harness, content) = viewerWindow(FakeGridSource.wide())
        let viewer = content.viewer, grid = viewer.grid
        // Hide Column on the focused cell's column (created_3).
        grid.selection.select(GridPosition(row: 0, column: 3))
        #expect(await call(harness, "menu", ["path": "Data > Hide Column"]).error == nil)
        #expect(grid.columnCount == 299 && !grid.columnOrder.contains(3))
        let list = GridColumnList(viewer: viewer)
        _ = list.view
        #expect(list.rows.count == 300 && list.rows.last == 3)
        let search = try #require(findSearch(in: list.view))
        func find(_ text: String) {
            search.stringValue = text
            list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }
        // The search narrows the list, shown columns first; Space shows the hidden one again, in its place.
        find("CREATED_3")
        #expect(list.rows == [30, 39, 3])
        list.table.selectRowIndexes([2], byExtendingSelection: false)
        list.toggleSelected()
        #expect(grid.columnOrder.firstIndex(of: 3) == 3 && grid.columnCount == 300)
        // Return jumps to a column far to the right and selects it.
        find("quantity_297")
        #expect(list.rows == [297])
        list.jump(nil)
        let index = try #require(grid.columnOrder.firstIndex(of: 297))
        #expect(grid.selection.containsColumn(index))
        #expect(grid.visibleRect.intersects(grid.columnRect(index)))
    }

    private func findSearch(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews { if let field = findSearch(in: subview) { return field } }
        return nil
    }

    @Test func columnsAreKeptPerTable() async throws {
        let key = GridViewer.ViewKey(connection: UUID(), database: "shop", table: "orders \(UUID())")
        let source = FakeGridSource(rows: 50, columns: 8)
        let (_, _, content) = viewerWindow(source, key: key)
        let grid = content.viewer.grid
        grid.columnWidths[2] = 171
        grid.columnOrder = [0, 5, 1, 2, 3, 4, 6, 7]
        content.viewer.dataGridColumnsDidChange(grid)
        content.viewer.setHidden(true, columns: [6])
        // The same table again (a new source): the same widths, order and hidden column.
        let again = ViewerContent(FakeGridSource(rows: 10, columns: 8), key: key)
        #expect(again.viewer.grid.columnWidths[2] == 171)
        #expect(again.viewer.grid.columnOrder == [0, 5, 1, 2, 3, 4, 7])
        // Shown again where it was.
        again.viewer.setHidden(false, columns: [6])
        #expect(again.viewer.grid.columnOrder == [0, 5, 1, 2, 3, 4, 6, 7])
        // Another table keeps its own.
        let other = ViewerContent(source, key: GridViewer.ViewKey(connection: key.connection, database: "shop", table: "other"))
        #expect(other.viewer.grid.columnOrder == Array(0..<8))
    }
}

extension AppTests {
    @Test func valuePanelFollowsTheCursorWithTextJSONAndHex() async throws {
        let source = FakeGridSource(rows: 40, columns: 9)
        let (_, harness, content) = viewerWindow(source)
        let viewer = content.viewer, grid = viewer.grid
        grid.selection.select(GridPosition(row: 0, column: 7))
        #expect(await call(harness, "key", ["combo": "shift+return"]).error == nil)
        let panel = try #require(viewer.valuePanel)
        #expect(panel.mode == .json && panel.outline.numberOfRows > 1)
        #expect(panel.footer.stringValue.hasPrefix("Valid JSON · "))
        // Text: the whole value; NULL says so.
        grid.selection.select(GridPosition(row: 1, column: 6))
        #expect(panel.mode == .text && panel.text.string == source.value(1, 6))
        grid.selection.select(GridPosition(row: 3, column: 4))
        #expect(source.cell(3, 4) == .null && panel.footer.stringValue == "NULL")
        // Hex on request, kept while it fits.
        grid.selection.select(GridPosition(row: 2, column: 1))
        panel.modes.selectedSegment = GridValuePanel.Mode.hex.rawValue
        _ = panel.modes.sendAction(panel.modes.action, to: panel.modes.target)
        #expect(panel.mode == .hex && panel.text.string.hasPrefix("00000000  43 75 73"))
        grid.selection.select(GridPosition(row: 5, column: 1))
        #expect(panel.mode == .hex)
        // ⇧↩ again closes it.
        #expect(await call(harness, "key", ["combo": "shift+return"]).error == nil)
        #expect(viewer.valuePanel == nil)
    }

    @Test func jsonTreeKeepsKeyOrder() {
        let tree = try? #require(JSONNode.parse(#"{"z": 1, "a": [true, null, "x\"y"], "m": {"k": -1.5e3}}"#))
        #expect(tree?.children.map(\.key) == ["z", "a", "m"])
        #expect(tree?.value == "{3 keys}" && tree?.children[1].value == "[3 items]")
        #expect(tree?.children[1].children.map(\.value) == ["true", "null", #""x\"y""#])
        #expect(tree?.pretty == "{\n  \"z\": 1,\n  \"a\": [\n    true,\n    null,\n    \"x\\\"y\"\n  ],\n  \"m\": {\n    \"k\": -1.5e3\n  }\n}")
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "01", "tru", "[1] x", String(repeating: "[", count: 600) + String(repeating: "]", count: 600)] {
            #expect(JSONNode.parse(bad) == nil, "\(bad.prefix(20))")
        }
        #expect(GridValuePanel.hexDump(Array("AirSQL".utf8)) == "00000000  41 69 72 53 51 4C" + String(repeating: " ", count: 30) + "  AirSQL")
    }
}
