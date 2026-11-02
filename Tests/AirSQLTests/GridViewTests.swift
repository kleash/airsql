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
}
