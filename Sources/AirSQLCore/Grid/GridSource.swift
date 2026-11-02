/// What a data grid shows, by index: a table's rows paged from the server, a result set, one record turned on its side
/// (Transpose) or two result sets compared (a diff). The grid asks only for the cells on screen, on the main thread, so
/// `cell` answers from memory; a source that fetches shows `.loading` until its page arrives.
///
/// How a screen hosts a grid (the embedding API): it makes a source and a `DataGridView` (the app's `Grid` folder), sets
/// the grid's `source` and `delegate` and adds `grid.scrollView` to its own view. It calls `grid.reloadData()` when the
/// columns or the row count change and `grid.reloadRows(_:)` when a page arrives. The grid never writes anything:
/// edits, sorting, record view and menus go to the delegate, which decides what they mean.
/// - Table tab: a `TableDataSource` pages `SELECT … LIMIT … OFFSET …` off the main thread on the data session; `prefetch`
///   queues the pages about to be shown. The key columns (primary key, or a NOT NULL unique key) are fetched whole,
///   never shortened, so an edit addresses the exact row; committed edits become pending changes that the source shows
///   through `mark` until Apply.
/// - Console result tab: a `ResultSetSource` over the statement's `ResultStore` (every row in memory, so never
///   `.loading`); read-only unless the result comes from one table with a key.
/// - Transpose: a `TransposedSource` wraps another source and one of its rows: a row per column, name and value.
/// - Diff (compare results, recon): a `DiffSource` lines up two sources by key and marks rows added (`.inserted`),
///   removed (`.deleted`) or changed (`.edited`, on the cells that differ).
public protocol GridSource: AnyObject {
    /// The columns in the source's order; the grid keeps its own display order and widths.
    var columns: [GridColumn] { get }
    /// The rows the grid scrolls through: the total when it is known, otherwise the rows loaded so far.
    var rowCount: Int { get }
    /// A cell as the grid shows it. Main thread, cells on screen only: no waiting on the network or the disk.
    func cell(_ row: Int, _ column: Int) -> GridCell
    /// The rows about to be shown, so a paged source can fetch what it lacks. Called often; cheap when nothing is
    /// missing.
    func prefetch(_ rows: Range<Int>)
    /// A pending change or a difference on this cell, drawn in its colour.
    func mark(_ row: Int, _ column: Int) -> GridMark
}

public extension GridSource {
    func prefetch(_ rows: Range<Int>) {}
    func mark(_ row: Int, _ column: Int) -> GridMark { .none }
}

/// A column as the grid shows it.
public struct GridColumn: Equatable, Sendable {
    /// How the column's values look: numbers are right-aligned; each kind has its colour.
    public enum Kind: Sendable {
        case text, number, date, binary, json
    }

    public var name: String
    /// The column's type as the header's tooltip shows it ("int unsigned", "varchar(255)"); "" when unknown.
    public var type: String
    public var kind: Kind
    /// Part of the key that addresses a row: its values are never shortened, and the grid never cuts them on screen.
    public var isKey: Bool

    public init(name: String, type: String = "", kind: Kind = .text, isKey: Bool = false) {
        self.name = name
        self.type = type
        self.kind = kind
        self.isKey = isKey
    }
}

/// A cell's value as the grid shows it.
public enum GridCell: Equatable, Sendable {
    /// The value as text; "" is an empty string, which the grid shows as blank, unlike NULL. A source may shorten long
    /// values (ending them with "…"), but never a key column's.
    case text(String)
    case null
    /// Its page hasn't arrived yet.
    case loading

    /// The text an editor or a copy starts from: "" for NULL and for a cell still loading.
    public var text: String {
        if case .text(let text) = self { return text }
        return ""
    }
}

/// A pending change (until Apply) or a difference (in a diff), drawn in its colour.
public enum GridMark: Equatable, Sendable {
    case none, edited, inserted, deleted
}
