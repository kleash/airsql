/// What a data grid shows, by index: a table's rows paged from the server, a result set, one record turned on its side
/// (Transpose) or two result sets compared (a diff). The grid asks only for the cells on screen, on the main thread, so
/// `cell` answers from memory; a source that fetches shows `.loading` until its page arrives.
///
/// How a screen hosts a grid (the embedding API): it makes a source and a `GridViewer` (the app's `Grid` folder: a
/// `DataGridView` with the status bar's figures, the value panel, Record View, Transpose and the copy formats), becomes
/// the viewer's `host` (a `DataGridViewDelegate`) and shows the source with `show(_:)`. It calls the viewer's
/// `reloadData()` when the columns, the rows or their values change. The grid never writes anything: edits, sorting and
/// the first items of its menus go to the host, which decides what they mean.
/// - Table tab: a `TableDataSource` holds the pages of `SELECT … LIMIT … OFFSET …` loaded so far off the main thread on
///   the data session: the first one, then one per Load More, or the rest streamed in batches by Load All. Rows don't
///   load as they scroll into view, so `rowCount` is the rows loaded and nothing is `.loading`. The key columns (primary
///   key, or a NOT NULL unique key) are never shortened, so an edit addresses the exact row; edits are pending changes,
///   which the source draws over its rows (`mark`, new rows after the loaded ones) until Apply.
/// - Console result tab: a `ResultSetSource` over the statement's `ResultStore` (every row in memory, so never
///   `.loading`); read-only unless the result comes from one table with a key.
/// - Transpose and Record View: a `TransposedSource` wraps another source: a row per column, its name, then a column
///   per row (the first 1,000, or Record View's one); `base(_:_:)` maps a cell back to the source's.
/// - Diff (the compare window's rows that differ, a console result compared with another result or a table): a
///   `DiffSource` shows a `ReconTableData`, rows matched by key: those only the first side has (`.inserted`), those only
///   the second has (`.deleted`), then those both have with other values (`.edited` on the cells that differ, whose
///   `note` gives the second side's value).
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
    /// The cell's whole value, never shortened (copy, the value panel, the selection's sum): nil for NULL and while
    /// loading.
    func value(_ row: Int, _ column: Int) -> String?
    /// What the cell's tooltip says instead of its value: a diff's other value for a changed cell; nil for nothing.
    func note(_ row: Int, _ column: Int) -> String?
}

public extension GridSource {
    func prefetch(_ rows: Range<Int>) {}
    func mark(_ row: Int, _ column: Int) -> GridMark { .none }
    func value(_ row: Int, _ column: Int) -> String? {
        if case .text(let text) = cell(row, column) { return text }
        return nil
    }
    func note(_ row: Int, _ column: Int) -> String? { nil }
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
    /// What the header marks besides the name and type: from the result's column flags, or the table's schema.
    public var marks: Marks
    /// The column's comment (from the schema), shown in the header's tooltip.
    public var comment: String

    /// The header's marks: key icons for the first four, words after the type for the rest.
    public struct Marks: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let primary = Marks(rawValue: 1 << 0)
        public static let foreign = Marks(rawValue: 1 << 1)
        public static let unique = Marks(rawValue: 1 << 2)
        public static let indexed = Marks(rawValue: 1 << 3)
        public static let autoIncrement = Marks(rawValue: 1 << 4)
        public static let hasDefault = Marks(rawValue: 1 << 5)
        public static let generated = Marks(rawValue: 1 << 6)
        public static let nullable = Marks(rawValue: 1 << 7)
    }

    public init(name: String, type: String = "", kind: Kind = .text, isKey: Bool = false, marks: Marks = [], comment: String = "") {
        self.name = name
        self.type = type
        self.kind = kind
        self.isKey = isKey
        self.marks = marks
        self.comment = comment
    }
}

extension GridColumn {
    /// The header's second line: the type, then "auto", "default" or "generated", then "null" when NULL is allowed.
    public var typeLine: String {
        var words = type.isEmpty ? [] : [type]
        if marks.contains(.autoIncrement) { words.append("auto") }
        if marks.contains(.generated) { words.append("generated") }
        if marks.contains(.hasDefault) { words.append("default") }
        if marks.contains(.nullable) { words.append("null") }
        return words.joined(separator: " · ")
    }

    /// The header's tooltip after what a click does: the type in words, the keys, the comment.
    public var details: String {
        var facts: [String] = []
        if marks.contains(.primary) { facts.append("primary key") }
        if marks.contains(.unique) { facts.append("unique key") }
        if marks.contains(.foreign) { facts.append("foreign key") }
        if marks.contains(.indexed) { facts.append("indexed") }
        if marks.contains(.autoIncrement) { facts.append("auto-increment") }
        if marks.contains(.generated) { facts.append("generated, read-only") }
        if marks.contains(.hasDefault) { facts.append("has a default") }
        if marks.contains(.nullable) { facts.append("NULL allowed") }
        let first = ([name] + (type.isEmpty ? [] : [type])).joined(separator: " · ")
        return ([first] + (facts.isEmpty ? [] : [facts.joined(separator: ", ")]) + (comment.isEmpty ? [] : ["“\(comment)”"]))
            .joined(separator: "\n")
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
