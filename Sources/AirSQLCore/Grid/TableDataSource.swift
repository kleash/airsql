import Foundation

/// A table's rows as its tab shows them (the table tab of `GridSource`'s notes): the pages fetched so far on the data
/// session, each kept as the `ResultStore` it arrived in, one after another, so a page costs nothing to add. Long
/// values are shortened on screen (never a key column's); their whole text stays for copying and the value panel.
public final class TableDataSource: GridSource {
    public private(set) var columns: [GridColumn]
    public private(set) var rowCount = 0
    /// The last page came back short: every row is loaded.
    public private(set) var isComplete = false
    private var pages: [ResultStore] = []
    /// The first row of each page.
    private var starts: [Int] = []

    /// `table`: the schema of the table, for the header's types, keys and comments.
    public init(_ page: ResultStore, table: SchemaTable?, pageSize: Int) {
        columns = page.columns.map(\.gridColumn)
        if let table {
            for index in columns.indices { columns[index].describe(table) }
        }
        append(page, pageSize: pageSize)
    }

    /// Adds the next page, asked for with `pageSize` rows: fewer means it was the last.
    public func append(_ page: ResultStore, pageSize: Int) {
        if page.rowCount > 0 {
            starts.append(rowCount)
            pages.append(page)
            rowCount += page.rowCount
        }
        isComplete = page.rowCount < pageSize
    }

    private func locate(_ row: Int) -> (ResultStore, Int) {
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= row { low = middle } else { high = middle - 1 }
        }
        return (pages[low], row - starts[low])
    }

    public func cell(_ row: Int, _ column: Int) -> GridCell {
        let (page, local) = locate(row)
        guard !page.isNull(local, column) else { return .null }
        let text = page.display(local, column) ?? ""
        guard !columns[column].isKey, text.count > ResultSetSource.shownLimit else { return .text(text) }
        return .text(String(text.prefix(ResultSetSource.shownLimit)) + "…")
    }

    public func value(_ row: Int, _ column: Int) -> String? {
        let (page, local) = locate(row)
        return page.isNull(local, column) ? nil : page.display(local, column) ?? ""
    }

    /// The cell's bytes as the server sent them (hex, image preview): nil for NULL.
    public func bytes(_ row: Int, _ column: Int) -> [UInt8]? {
        let (page, local) = locate(row)
        return page.bytes(local, column)
    }
}
