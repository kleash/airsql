import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// A tab showing a grid over a source, as a table tab or a result tab will host one (the embedding API).
@MainActor
final class GridFixtureContent: NSViewController, TabContent, DataGridViewDelegate {
    let grid: DataGridView
    var editable = false
    var edits: [(row: Int, column: Int, text: String)] = []
    var events: [String] = []

    init(_ source: GridSource) {
        grid = DataGridView(source: source)
        super.init(nibName: nil, bundle: nil)
        grid.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() { view = grid.scrollView }

    func dataGrid(_ grid: DataGridView, canEditRow row: Int, column: Int) -> Bool { editable }
    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, text: String) { edits.append((row, column, text)) }
    func dataGrid(_ grid: DataGridView, sortBy column: Int, adding: Bool) { events.append("sort \(column) \(adding)") }
    func dataGridColumnsDidChange(_ grid: DataGridView) { events.append("columns") }
    func dataGrid(_ grid: DataGridView, openRecord row: Int) { events.append("record \(row)") }
    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu? {
        events.append("menu \(target)")
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        return menu
    }
}

extension AppTests {
    /// A main window showing `source` in a grid tab.
    func gridWindow(_ source: GridSource, size: NSSize = NSSize(width: 1200, height: 760))
        -> (main: MainWindowController, harness: AgentServer, content: GridFixtureContent) {
        let model = testModel(Fixtures.shop)
        let (main, harness) = appWindow(model, size: size)
        let content = GridFixtureContent(source)
        main.open(content, title: "customers", connection: Fixtures.production.id)
        main.window?.layoutIfNeeded()
        return (main, harness, content)
    }

    @Test func gridIsAsBigAsItsCells() {
        let (_, _, content) = gridWindow(FakeGridSource.large())
        let grid = content.grid
        #expect(grid.frame.height == 1_000_000 * grid.rowHeight)
        #expect(grid.columnCount == 50 && grid.offsets.count == 51)
        #expect(grid.frame.width == grid.offsets[50])
        // Each display column is found by its left edge, the last pixel included.
        for column in [0, 1, 25, 49] {
            #expect(grid.column(atX: grid.offsets[column]) == column)
            #expect(grid.column(atX: grid.offsets[column + 1] - 0.5) == column)
        }
        #expect(grid.column(atX: grid.offsets[50]) == nil)
        // The key column fits its widest value (the last id); other columns stop at 230 points.
        let key = (FakeGridSource.large().cell(999_999, 0).text as NSString).size(withAttributes: [.font: grid.styles.key]).width
        #expect(grid.columnWidths[0] >= key + 2 * GridStyles.padding)
        #expect(grid.columnWidths.dropFirst().allSatisfy { $0 >= 60 && $0 <= 230 })
    }

    /// Where a view's point is for the harness: points from the main window's top left.
    func spot(_ view: NSView, _ point: NSPoint) -> [String: Any] {
        let inWindow = view.convert(point, to: nil)
        return ["x": inWindow.x, "y": view.window!.frame.height - inWindow.y]
    }

    func spot(_ grid: DataGridView, _ position: GridPosition) -> [String: Any] {
        let rect = grid.cellRect(position)
        return spot(grid, NSPoint(x: rect.midX, y: rect.midY))
    }

    /// A header's point: the middle of a display column's label, or its sort control.
    func headerSpot(_ grid: DataGridView, _ column: Int, sort: Bool = false) -> [String: Any] {
        let (left, right) = grid.header.edges(column)
        return spot(grid.header, NSPoint(x: sort ? right - GridHeaderView.sortWidth / 2 - 2 : (left + right) / 2 - 10, y: 12))
    }

    func rowSpot(_ grid: DataGridView, _ row: Int) -> [String: Any] {
        let y = grid.rowNumbers.convert(NSPoint(x: 0, y: (CGFloat(row) + 0.5) * grid.rowHeight), from: grid).y
        return spot(grid.rowNumbers, NSPoint(x: grid.rowNumbers.bounds.midX, y: y))
    }

    @Test func gridClicksFollowTheInteractionContract() async {
        let (_, harness, content) = gridWindow(FakeGridSource.large())
        let grid = content.grid
        func click(_ spot: [String: Any], _ extra: [String: Any] = [:]) async -> Reply {
            await call(harness, "click", spot.merging(extra) { $1 })
        }
        _ = await click(spot(grid, GridPosition(row: 2, column: 1)))
        #expect(grid.selection.areas == [.cells(rows: 2...2, columns: 1...1)])
        _ = await click(spot(grid, GridPosition(row: 4, column: 3)), ["modifiers": "shift"])
        #expect(grid.selection.areas == [.cells(rows: 2...4, columns: 1...3)])
        _ = await click(spot(grid, GridPosition(row: 8, column: 0)), ["modifiers": "cmd"])
        #expect(grid.selection.areas.count == 2 && grid.selection.cursor == GridPosition(row: 8, column: 0))

        _ = await click(rowSpot(grid, 5))
        #expect(grid.selection.areas == [.rows(5...5)])
        _ = await click(rowSpot(grid, 7), ["modifiers": "shift"])
        #expect(grid.selection.areas == [.rows(5...7)])
        _ = await click(rowSpot(grid, 6), ["count": 2])
        #expect(content.events.last == "record 6")

        _ = await click(headerSpot(grid, 2))
        #expect(grid.selection.areas == [.columns(2...2)])
        _ = await click(headerSpot(grid, 2, sort: true))
        #expect(content.events.last == "sort 2 false")
        _ = await click(headerSpot(grid, 3, sort: true), ["modifiers": "alt"])
        #expect(content.events.last == "sort 3 true")

        // Right clicks select what they are on first, then ask the delegate for its menu.
        let menu = await click(spot(grid, GridPosition(row: 12, column: 4)), ["button": "right"])
        #expect(titles(menu["menu"]).contains("Copy"))
        #expect(content.events.last == "menu cells" && grid.selection.contains(GridPosition(row: 12, column: 4)))
        _ = await click(headerSpot(grid, 5), ["button": "right"])
        #expect(content.events.last == "menu column(5)" && grid.selection.containsColumn(5))
        _ = await click(rowSpot(grid, 9), ["button": "right"])
        #expect(content.events.last == "menu row(9)" && grid.selection.containsRow(9))
    }

    @Test func gridKeysMoveTheCursor() async {
        let (main, harness, content) = gridWindow(FakeGridSource.large())
        let grid = content.grid
        main.window?.makeFirstResponder(grid)
        func key(_ combo: String) async { _ = await call(harness, "key", ["combo": combo]) }
        grid.selection.select(GridPosition(row: 0, column: 0))
        await key("down"); await key("right"); await key("right")
        #expect(grid.selection.cursor == GridPosition(row: 1, column: 2))
        await key("shift+down"); await key("shift+right")
        #expect(grid.selection.areas == [.cells(rows: 1...2, columns: 2...3)])
        await key("pagedown")
        #expect(grid.selection.cursor?.row == 2 + grid.rowsPerPage)
        await key("cmd+down")
        #expect(grid.selection.cursor == GridPosition(row: 999_999, column: 3))
        #expect(grid.shownRect.maxY >= grid.cellRect(grid.selection.cursor!).maxY)  // scrolled to it
        await key("cmd+right")
        #expect(grid.selection.cursor?.column == 49)
        await key("tab")  // the last cell: stays
        #expect(grid.selection.cursor == GridPosition(row: 999_999, column: 49))
        await key("home")
        #expect(grid.selection.cursor == GridPosition(row: 0, column: 49))
        await key("cmd+left")
        #expect(grid.selection.cursor == GridPosition(row: 0, column: 0))
        // ⇧Tab as the keyboard sends it (the harness's "shift+tab" sends a Tab with ⇧, which key bindings read as Tab).
        let backtab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                                       windowNumber: main.window!.windowNumber, context: nil, characters: "\u{19}",
                                       charactersIgnoringModifiers: "\u{19}", isARepeat: false, keyCode: 48)!
        grid.selection.select(GridPosition(row: 1, column: 0))
        grid.keyDown(with: backtab)  // wraps to the end of the row above
        #expect(grid.selection.cursor == GridPosition(row: 0, column: 49))
        await key("cmd+a")
        #expect(grid.selection.areas == [.all])
    }

    @Test func gridEditsInPlace() async {
        let (main, harness, content) = gridWindow(FakeGridSource.large())
        let grid = content.grid
        main.window?.makeFirstResponder(grid)
        func key(_ combo: String) async { _ = await call(harness, "key", ["combo": combo]) }
        grid.selection.select(GridPosition(row: 3, column: 1))
        await key("return")  // read-only: no editor
        #expect(grid.editor == nil)

        content.editable = true
        await key("return")
        #expect(grid.editor?.stringValue == "Customer 3 Dennis")
        _ = await call(harness, "type", ["text": "Ada"])
        await key("return")
        #expect(grid.editor == nil && content.edits.count == 1)
        #expect(content.edits.last.map { [String($0.row), String($0.column), $0.text] } == ["3", "1", "Ada"])

        await key("return"); await key("escape")  // Esc cancels
        #expect(grid.editor == nil && content.edits.count == 1)

        _ = await call(harness, "type", ["text": "Zoe"])  // typing starts editing with what was typed
        #expect(grid.editor?.stringValue == "Zoe")
        await key("tab")  // commits and moves on
        #expect(content.edits.last?.text == "Zoe" && grid.selection.cursor == GridPosition(row: 3, column: 2))
        _ = await call(harness, "click", spot(grid, GridPosition(row: 6, column: 4)).merging(["count": 2]) { $1 })
        #expect(grid.editor?.position == GridPosition(row: 6, column: 4))
        grid.endEditing(commit: false)
    }

    @Test func gridHeaderResizesFitsAndMovesColumns() {
        let (_, _, content) = gridWindow(FakeGridSource.large())
        let grid = content.grid, header = grid.header!
        func event(_ type: NSEvent.EventType, _ x: CGFloat, clicks: Int = 1) -> NSEvent {
            let point = header.convert(NSPoint(x: x, y: 12), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: grid.window!.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        let width = grid.columnWidths[1], border = header.edges(1).right
        header.mouseDown(with: event(.leftMouseDown, border))
        header.mouseDragged(with: event(.leftMouseDragged, border + 30))
        header.mouseUp(with: event(.leftMouseUp, border + 30))
        #expect(grid.columnWidths[1] == width + 30 && content.events.last == "columns")

        header.mouseDown(with: event(.leftMouseDown, header.edges(1).right, clicks: 2))  // auto-fit
        #expect(grid.columnWidths[1] < width + 30)

        let start = (header.edges(1).left + header.edges(1).right) / 2, target = header.edges(3).right - 5
        header.mouseDown(with: event(.leftMouseDown, start))
        header.mouseDragged(with: event(.leftMouseDragged, target))
        #expect(header.dropIndex == 4)
        header.mouseUp(with: event(.leftMouseUp, target))
        #expect(grid.columnOrder.prefix(5) == [0, 2, 3, 1, 4])
        #expect(grid.selection.areas == [.columns(3...3)])
    }

    @Test func gridIsAnAccessibilityTable() {
        let (main, _, content) = gridWindow(FakeGridSource.large())
        let grid = content.grid
        #expect(grid.accessibilityRole() == .table)
        #expect(grid.accessibilityRowCount() == 1_000_000 && grid.accessibilityColumnCount() == 50)
        // Elements only for what is on screen.
        let rows = grid.accessibilityVisibleRows() ?? []
        #expect(rows.count == grid.rows(in: grid.shownRect).count && rows.count < 40)
        #expect((rows.first as? GridRowElement)?.accessibilityIndex() == 0)
        #expect(((rows.first as? GridRowElement)?.accessibilityChildren() ?? []).count == grid.columns(in: grid.shownRect).count)
        let headers = grid.accessibilityColumnHeaderUIElements() as? [GridHeaderElement] ?? []
        #expect(headers.first?.accessibilityLabel() == "id" && headers.count == grid.columns(in: grid.shownRect).count)

        let cell = grid.accessibilityCell(forColumn: 1, row: 3) as? GridCellElement
        #expect(cell?.accessibilityValue() as? String == "Customer 3 Dennis" && cell?.accessibilityLabel() == "name_1")
        #expect(cell === grid.accessibilityCell(forColumn: 1, row: 3) as? GridCellElement)  // the same element each time
        #expect((grid.accessibilityCell(forColumn: 4, row: 3) as? GridCellElement)?.accessibilityValue() as? String == "NULL")
        #expect(cell.map { NSAccessibility.screenRect(fromView: grid, rect: grid.cellRect($0.position)) == $0.accessibilityFrame() } == true)

        main.window?.makeFirstResponder(grid)
        grid.selection.select(GridPosition(row: 3, column: 1))
        #expect(cell?.isAccessibilitySelected() == true && cell?.isAccessibilityFocused() == true)
        #expect(grid.accessibilityFocusedUIElement as? GridCellElement === cell)
        #expect((grid.accessibilitySelectedCells() ?? []).count == 1)
        #expect(headers[2].accessibilityPerformPress() && grid.selection.containsColumn(2))

        // Editing: only where the delegate allows it, as a pending change.
        let setValue = #selector(NSAccessibilityElement.setAccessibilityValue(_:))
        #expect(cell?.isAccessibilitySelectorAllowed(setValue) == false)
        content.editable = true
        #expect(cell?.isAccessibilitySelectorAllowed(setValue) == true)
        cell?.setAccessibilityValue("Grace")
        #expect(content.edits.last.map { [String($0.row), String($0.column), $0.text] } == ["3", "1", "Grace"])

        // Scrolling far keeps a bounded number of elements.
        for row in stride(from: 0, to: 600_000, by: 100) { _ = grid.accessibilityCell(forColumn: row % 50, row: row) }
        #expect(grid.accessibilityElements.cells.count <= 4_001)
    }
}
