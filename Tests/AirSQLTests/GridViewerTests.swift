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

    @Test func freezeKeepsTheFirstColumnsInViewAndIsKeptPerTable() async throws {
        let key = GridViewer.ViewKey(connection: UUID(), database: "shop", table: "wide \(UUID())")
        let (main, _, content) = viewerWindow(FakeGridSource.wide(), key: key)
        let viewer = content.viewer, grid = viewer.grid
        grid.selection.select(GridPosition(row: 3, column: 0))
        viewer.freezeColumns(nil)
        #expect(grid.frozenColumns == 1)
        // Across: the key column stays at the left of what is shown, over the cells scrolled under it.
        grid.reveal(grid.cellRect(GridPosition(row: 3, column: 40)))
        main.window?.displayIfNeeded()
        let shown = grid.visibleRect, width = grid.frozenWidth
        #expect(shown.minX > width && grid.frozenShift == shown.minX)
        #expect(grid.position(at: NSPoint(x: shown.minX + 5, y: grid.rowHeight * 3.5)) == GridPosition(row: 3, column: 0))
        #expect(grid.shownRect(GridPosition(row: 3, column: 0)).minX == shown.minX)
        #expect(grid.header.column(at: NSPoint(x: 5, y: 5)) == 0)
        // A column that went under it scrolls back out from under it.
        let under = try #require(grid.position(at: NSPoint(x: shown.minX + width + 1, y: 1))).column
        grid.reveal(grid.cellRect(GridPosition(row: 3, column: under - 1)))
        #expect(grid.cellRect(GridPosition(row: 3, column: under - 1)).minX >= grid.visibleRect.minX + width)
        // The same table again keeps it; Freeze on the last frozen column unfreezes.
        let again = ViewerContent(FakeGridSource.wide(), key: key)
        #expect(again.viewer.grid.frozenColumns == 1)
        viewer.freezeColumns(nil)
        #expect(grid.frozenColumns == 0)
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
        let tree = JSONNode.parse(#"{"z": 1, "a": [true, null, "x\"y"], "m": {"k": -1.5e3}}"#)
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

extension AppTests {
    @Test func transposeTurnsRowsIntoColumnsAndBack() async throws {
        let source = FakeGridSource(rows: 30, columns: 6)
        let (_, harness, content) = viewerWindow(source)
        let viewer = content.viewer, grid = viewer.grid
        grid.columnOrder = [0, 2, 1, 3, 4, 5]
        grid.selection.select(GridPosition(row: 4, column: 1))
        #expect(await call(harness, "menu", ["path": "View > Transpose"]).error == nil)
        let shown = try #require(grid.source as? TransposedSource)
        #expect(grid.rowCount == 6 && grid.columnCount == 31)
        #expect(shown.cell(1, 0) == .text("amount_2") && shown.cell(1, 5) == source.cell(4, 2))
        #expect(shown.base(1, 5)! == (4, 2) && shown.base(1, 0) == nil)
        // The focused cell follows: row 4 of amount_2 is now line 1, column 5.
        #expect(grid.selection.cursor == GridPosition(row: 1, column: 5))
        #expect(await call(harness, "key", ["combo": "cmd+alt+t"]).error == nil)
        #expect(grid.source === source && grid.columnOrder == [0, 2, 1, 3, 4, 5])
        #expect(grid.selection.cursor == GridPosition(row: 4, column: 1))
    }

    @Test func recordViewShowsOneRowAndStepsThroughThem() async throws {
        let source = FakeGridSource(rows: 3, columns: 5)
        let (_, harness, content) = viewerWindow(source)
        let viewer = content.viewer, grid = viewer.grid
        grid.selection.select(GridPosition(row: 1, column: 2))
        #expect(await call(harness, "menu", ["path": "View > Record View"]).error == nil)
        #expect(viewer.record == 1 && grid.columnCount == 2 && grid.rowCount == 5)
        #expect(grid.source?.columns.map(\.name) == ["Column", "Value"] && grid.source?.cell(2, 1) == source.cell(1, 2))
        #expect(viewer.recordLabel.stringValue == "Row 2 of 3" && grid.selection.cursor == GridPosition(row: 2, column: 1))
        #expect(await call(harness, "menu", ["path": "View > Next Record"]).error == nil)
        #expect(viewer.record == 2 && grid.source?.cell(2, 1) == source.cell(2, 2))
        let last = await call(harness, "menu", ["path": "View > Next Record"])
        #expect(last.error?.contains("There is no row after this one") == true)
        #expect(await call(harness, "press", ["id": "record.previous"]).error == nil)
        #expect(viewer.record == 1)
        #expect(await call(harness, "press", ["id": "record.close"]).error == nil)
        #expect(viewer.record == nil && grid.source === source && grid.selection.cursor == GridPosition(row: 1, column: 2))
    }
}

extension AppTests {
    @Test func displayAsShowsUnixTimesAsDatesAndIsKeptPerTable() async throws {
        let key = GridViewer.ViewKey(connection: UUID(), database: "shop", table: "events \(UUID())")
        let source = FakeGridSource(rows: 20, columns: 10)
        let (_, harness, content) = viewerWindow(source, key: key)
        let grid = content.viewer.grid
        grid.selection.select(GridPosition(row: 2, column: 9))
        // Words can't be shown as dates: the item says why.
        grid.selection.select(GridPosition(row: 2, column: 1))
        let refused = await call(harness, "menu", ["path": "Data > Display As > Date from Unix Time (seconds)"])
        #expect(refused.error?.contains("Not for this column's type") == true, "\(refused.error ?? "")")
        grid.selection.select(GridPosition(row: 2, column: 9))
        #expect(await call(harness, "menu", ["path": "Data > Display As > Date from Unix Time (seconds)"]).error == nil)
        let seconds = try #require(source.value(2, 9).flatMap(Double.init))
        let expected = GridDisplay.unixTime.format(String(Int(seconds)), bytes: nil)!
        #expect(grid.source?.cell(2, 9) == .text(expected) && grid.source?.value(2, 9) == source.value(2, 9))
        #expect(grid.source?.columns[9].type == "int as date" && grid.selection.cursor == GridPosition(row: 2, column: 9))
        // Kept for the table.
        let again = ViewerContent(FakeGridSource(rows: 5, columns: 10), key: key)
        #expect(again.viewer.displays[9] == .unixTime && again.viewer.grid.source?.columns[9].kind == .date)
        // As Stored takes it away.
        #expect(await call(harness, "menu", ["path": "Data > Display As > As Stored"]).error == nil)
        #expect(grid.source?.cell(2, 9) == source.cell(2, 9) && content.viewer.displays.isEmpty)
    }

    @Test func displayTypesFormatValues() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(GridDisplay.unixTime.format("1762164000", bytes: nil, timeZone: utc) == "2025-11-03 10:00:00")
        #expect(GridDisplay.unixMillis.format("1762164000123", bytes: nil, timeZone: utc) == "2025-11-03 10:00:00")
        #expect(GridDisplay.unixTime.format("soon", bytes: nil) == nil && GridDisplay.unixTime.format(nil, bytes: nil) == nil)
        let bytes: [UInt8] = [0x12, 0x3e, 0x45, 0x67, 0xe8, 0x9b, 0x12, 0xd3, 0xa4, 0x56, 0x42, 0x66, 0x14, 0x17, 0x40, 0x00]
        #expect(GridDisplay.uuid.format(nil, bytes: bytes) == "123e4567-e89b-12d3-a456-426614174000")
        #expect(GridDisplay.uuid.format(nil, bytes: [1, 2]) == nil)
        #expect(GridDisplay.hex.format(nil, bytes: [0, 255]) == "0x00FF" && GridDisplay.text.format(nil, bytes: Array("héllo".utf8)) == "héllo")
        #expect(GridDisplay.grouped.format("1234567.50", bytes: nil)?.filter(\.isNumber) == "123456750")
        #expect(GridDisplay.choices(for: GridColumn(name: "n", kind: .number)).contains(.unixTime))
        #expect(GridDisplay.choices(for: GridColumn(name: "t")) == [.standard])
    }
}

extension AppTests {
    @Test func heatmapColoursNumbersAndEqualValuesAreTinted() async throws {
        let source = FakeGridSource(rows: 50, columns: 10)
        let (_, harness, content) = viewerWindow(source)
        let viewer = content.viewer, grid = viewer.grid
        // A word column can't have a heatmap.
        grid.selection.selectColumn(1)
        let refused = await call(harness, "menu", ["path": "View > Heatmap"])
        #expect(refused.error?.contains("Select a number column first") == true)
        grid.selection.selectColumn(9)
        #expect(await call(harness, "menu", ["path": "View > Heatmap"]).error == nil)
        let tint = try #require(grid.cellTint)
        let values = (0..<50).map { Double(source.value($0, 9)!)! }
        let low = values.firstIndex(of: values.min()!)!, high = values.firstIndex(of: values.max()!)!
        #expect(tint(low, 9)!.alphaComponent < tint(high, 9)!.alphaComponent)
        #expect(tint(low, 2) == nil)
        // Again: off.
        #expect(await call(harness, "menu", ["path": "View > Heatmap"]).error == nil)
        #expect(grid.cellTint == nil)
        // Equal values: the focused cell's value, wherever it is.
        grid.selection.select(GridPosition(row: 0, column: 5))
        #expect(await call(harness, "menu", ["path": "View > Highlight Equal Values"]).error == nil)
        let same = (1..<50).first { source.value($0, 5) == source.value(0, 5) }
        let other = (1..<50).first { source.value($0, 5) != source.value(0, 5) }
        if let same { #expect(grid.cellTint?(same, 5) != nil) }
        if let other { #expect(grid.cellTint?(other, 5) == nil) }
    }
}

extension AppTests {
    @Test func viewAsTextTreeAndChartShowTheRowsAnotherWay() async throws {
        let source = FakeGridSource(rows: 25, columns: 10)
        let (_, harness, content) = viewerWindow(source)
        let viewer = content.viewer
        // Text: the rows in the copy format, with the column names (TSV here, then Markdown).
        let format = GridCopy.format
        defer { GridCopy.format = format }
        GridCopy.format = .tsv
        #expect(await call(harness, "menu", ["path": "View > View As > Text"]).error == nil)
        var text = try #require((viewer.presented as? NSScrollView)?.documentView as? NSTextView)
        #expect(viewer.presentation == .text && viewer.grid.containerView.isHidden)
        #expect(text.string.hasPrefix("id\tname_1\tamount_2\t") && text.string.contains("\n25\t"))
        GridCopy.format = .markdown
        #expect(await call(harness, "menu", ["path": "View > View As > Text"]).error == nil)
        text = try #require((viewer.presented as? NSScrollView)?.documentView as? NSTextView)
        #expect(text.string.hasPrefix("| id | name_1 |"))
        #expect(await call(harness, "menu", ["path": "View > View As > Tree"]).error == nil)
        let tree = try #require(viewer.presented as? JSONTreeView)
        #expect(tree.tree?.children.count == 25 && tree.tree?.children[0].children[0].kind == .number)
        // Chart: a bar of the first number column that isn't the key, by the first text column.
        #expect(await call(harness, "menu", ["path": "View > Chart"]).error == nil)
        let chart = try #require(viewer.presented as? GridChartView)
        #expect(chart.spec.kind == .bar && chart.spec.y == "amount_2" && chart.spec.x == "name_1" && !chart.spec.points.isEmpty)
        chart.kind.selectItem(at: GridChart.Kind.histogram.rawValue)
        chart.update()
        #expect(chart.spec.kind == .histogram && chart.spec.points.map(\.y).reduce(0, +) == 25)
        chart.kind.selectItem(at: GridChart.Kind.scatter.rawValue)
        chart.update()
        #expect(chart.spec.points.count == 25)
        let png = try #require(chart.pngData())
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]) && NSImage(data: png) != nil)
        // Chart again: back to the grid.
        #expect(await call(harness, "menu", ["path": "View > Chart"]).error == nil)
        #expect(viewer.presentation == .table && viewer.presented == nil && !viewer.grid.containerView.isHidden)
    }

    @Test func chartPointsAndRowsAsATree() {
        let totals = GridChart.totals(labels: ["a", "b", "a", nil, "c"], values: [1, 2, 3, 4, nil], limit: 2)
        #expect(totals.map(\.label) == ["a", "b", "Other"] && totals.map(\.y) == [4, 2, 4])
        let series = GridChart.series(xs: [1, nil, 3], ys: [10, 20, nil])
        #expect(series.map(\.x) == [1] && GridChart.series(xs: nil, ys: [5, 6]).map(\.x) == [1, 2])
        let bins = GridChart.histogram([0, 1, 2, 3, 10, nil], bins: 5)
        #expect(bins.count == 5 && bins.map(\.y) == [2, 2, 0, 0, 1])
        #expect(GridChart.histogram([7, 7], bins: 5).map(\.y) == [2] && GridChart.histogram([nil], bins: 5).isEmpty)
        let rows = JSONNode.rows([GridColumn(name: "n", kind: .number), GridColumn(name: "j", kind: .json), GridColumn(name: "s")],
                                 [["1.5", "{\"a\": 1}", "x\"y"], [nil, "not json", nil]])
        #expect(rows.children[0].children.map(\.value) == ["1.5", "{1 key}", #""x\"y""#])
        #expect(rows.children[1].children.map(\.kind) == [.null, .string, .null])
    }
}

/// Lane L2's screens for `LayoutTests`: a result in the viewer with long values, its value panel (JSON and text), Record
/// View, a transposed grid with its note, Text, Tree and Chart, and the column list's and Column Summary's popovers.
@MainActor
func gridViewerLayoutProblems(_ main: MainWindowController, appearance: NSAppearance.Name, place: String) -> [String] {
    var problems: [String] = []
    let window = main.window!
    func check(_ what: String) {
        window.appearance = NSAppearance(named: appearance)
        window.contentView?.layoutSubtreeIfNeeded()
        if let content = window.contentView { problems += layoutProblems(content, where: "\(place) \(what)") }
    }
    func check(_ view: NSView, _ what: String) {
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        problems += layoutProblems(view, where: "\(place) \(what)")
    }
    let source = FakeGridSource(rows: 2_000, columns: 12)
    let content = ViewerContent(source)
    main.open(content, title: "orders_with_a_long_name_for_the_tab", connection: Fixtures.production.id)
    let viewer = content.viewer, grid = viewer.grid
    content.viewer.status.rows.stringValue = "1,000 of ≈2,348,245,917 rows"
    grid.selection.select(GridPosition(row: 3, column: 2))
    grid.selection.select(GridPosition(row: 1_999, column: 2), extend: true)
    check("grid with figures")
    grid.selection.select(GridPosition(row: 0, column: 7))
    viewer.toggleValuePanel(nil)
    check("value panel (JSON)")
    grid.selection.select(GridPosition(row: 1, column: 6))
    check("value panel (text)")
    viewer.toggleValuePanel(nil)
    viewer.showRecordView(nil)
    check("Record View")
    viewer.transposeGrid(nil)
    viewer.transposeGrid(nil)
    check("transposed with its note")
    viewer.transposeGrid(nil)
    for presentation in [GridViewer.Presentation.text, .tree, .chart] {
        viewer.present(presentation)
        check("View As \(presentation)")
    }
    viewer.present(.table)
    let list = GridColumnList(viewer: viewer)
    check(list.view, "Column List")
    let summary = GridSummaryView(column: "a_column_name_that_runs_to_sixty_characters_to_test_layout_x", origin: "From the server, within the filter",
                                  nullText: "NULL")
    summary.show(.success(ColumnSummary(values: (0..<2_000).map { source.value($0, 5) })))
    check(summary.view, "Column Summary")
    main.close(main.tabs.last!)
    return problems
}

/// Lane L2's states for `HelpTests`: the viewer with its value panel, Record View's bar, Chart's controls, the column
/// list, and Go to Row's sheet; every control there has a tooltip.
@MainActor
func gridViewerUnexplained(_ main: MainWindowController, _ harness: AgentServer) async -> [String] {
    var missing: [String] = []
    let window = main.window!
    let content = ViewerContent(FakeGridSource(rows: 40, columns: 10))
    main.open(content, title: "orders", connection: Fixtures.production.id)
    let viewer = content.viewer
    viewer.grid.selection.select(GridPosition(row: 2, column: 2))
    viewer.toggleValuePanel(nil)
    window.layoutIfNeeded()
    missing += unexplained([window], where: "grid with the value panel")
    viewer.showRecordView(nil)
    window.layoutIfNeeded()
    missing += unexplained([window], where: "Record View")
    viewer.present(.chart)
    window.layoutIfNeeded()
    missing += unexplained([window], where: "Chart")
    viewer.present(.table)
    viewer.showColumnList(nil)
    if await call(harness, "wait", ["until": "popover", "timeout": 5]).error == nil {
        missing += unexplained(window.childWindows ?? [], where: "Column List")
    }
    window.childWindows?.forEach { $0.orderOut(nil) }
    _ = await call(harness, "menu", ["path": "Data > Go to Row…"])
    _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
    missing += unexplained(harness.openSheets(), where: "Go to Row")
    _ = await call(harness, "press", ["title": "Cancel"])
    _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
    main.close(main.tabs.last!)
    return missing
}
