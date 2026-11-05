import Foundation

/// Run to File: a result's batches to a file as they arrive, in the format its extension says (.csv, .tsv, .json), so its
/// size never matters. Called on the session's thread, in order.
public final class RowFileWriter: @unchecked Sendable {
    private let url: URL
    private var handle: FileHandle?
    private var writer: CopyWriter?
    public private(set) var rows = 0

    public init(_ url: URL) { self.url = url }

    private func put(_ text: String) throws { try handle?.write(contentsOf: Data(text.utf8)) }

    public func write(_ page: ResultStore) throws {
        if writer == nil {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw AirSQLError(.other, "the file can't be written")
            }
            handle = try FileHandle(forWritingTo: url)
            let format = CopyFormat.allCases.first { $0.fileExtension == url.pathExtension.lowercased() } ?? .csv
            let options = CopyOptions(headers: true)
            let made = CopyWriter(format, columns: page.columns.map(\.gridColumn), options: options)
            try put(made.header())
            writer = made
        }
        for row in 0..<page.rowCount {
            try put(writer?.row((0..<page.columns.count).map { page.string(row, $0) }) ?? "")
            rows += 1
        }
    }

    public func finish() throws {
        if let footer = writer?.footer() { try put(footer) }
        close()
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }
}
