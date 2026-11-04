import Foundation

/// A statement the person ran in a console, as the history keeps it.
public struct HistoryEntry: Codable, Equatable, Sendable {
    /// Masked as the SQL log masks it: no passwords or keys.
    public var sql: String
    public var date: Date
    public var connection: UUID
    public var database: String?
    public var duration: Double?
    public var rows: Int?
    /// Its error, if it failed.
    public var error: String?

    public init(sql: String, date: Date = Date(), connection: UUID, database: String? = nil, duration: Double? = nil,
                rows: Int? = nil, error: String? = nil) {
        self.sql = sql
        self.date = date
        self.connection = connection
        self.database = database
        self.duration = duration
        self.rows = rows
        self.error = error
    }
}

/// The console's history (plan §2.6): every statement run, per connection, newest first, searchable. One file per
/// connection, History/<id>.jsonl in Application Support (mode 0600), a JSON line per statement; credentials are masked
/// before anything is written, as in the SQL log. Written and read on a queue of its own, never the main thread.
public final class QueryHistory: @unchecked Sendable {
    public static let shared = QueryHistory(directory: Store.directory.appendingPathComponent("History", isDirectory: true))

    public let directory: URL
    /// Entries kept per connection: the file is trimmed to the newest when it passes `limit` × 400 bytes.
    let limit: Int
    private let queue = DispatchQueue(label: "com.kleash.airsql.history")

    public init(directory: URL, limit: Int = 5_000) {
        self.directory = directory
        self.limit = limit
    }

    func file(_ connection: UUID) -> URL { directory.appendingPathComponent(connection.uuidString + ".jsonl") }

    /// Adds a statement (masked) to its connection's history.
    public func add(_ entry: HistoryEntry, noBackslashEscapes: Bool = false) {
        var entry = entry
        entry.sql = SQLLog.mask(entry.sql, noBackslashEscapes: noBackslashEscapes)
        queue.async { [self] in
            guard var line = try? JSONEncoder().encode(entry) else { return }
            line.append(0x0A)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let url = file(entry.connection)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(line)
            let size = handle.offsetInFile
            try? handle.close()
            // Trimmed now and then, not at every statement.
            if size > UInt64(limit) * 400 { trim(url) }
        }
    }

    /// The connection's statements, newest first, those containing every word of `search` (any case).
    public func entries(_ connection: UUID, matching search: String = "") async -> [HistoryEntry] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let words = search.lowercased().split(separator: " ").map(String.init)
                let all = read(file(connection)).reversed()
                continuation.resume(returning: all.filter { entry in
                    let sql = entry.sql.lowercased()
                    return words.allSatisfy { sql.contains($0) }
                })
            }
        }
    }

    /// Forgets the connection's history.
    public func clear(_ connection: UUID) {
        queue.async { [self] in try? FileManager.default.removeItem(at: file(connection)) }
    }

    /// Forgets these statements of the connection's history; the rest stay as they are.
    public func remove(_ entries: [HistoryEntry], from connection: UUID) {
        queue.async { [self] in
            let url = file(connection), encoder = JSONEncoder()
            let data = read(url).filter { !entries.contains($0) }.reduce(into: Data()) { result, entry in
                guard let line = try? encoder.encode(entry) else { return }
                result.append(line)
                result.append(0x0A)
            }
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Waits for the writes asked for so far (tests).
    public func flush() { queue.sync {} }

    private func read(_ url: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(HistoryEntry.self, from: $0) }
    }

    /// Keeps the newest entries: at most `limit`, and at most half the size that set off the trim.
    private func trim(_ url: URL) {
        let encoder = JSONEncoder()
        var lines: [Data] = [], bytes = 0
        for entry in read(url).reversed() {
            guard lines.count < limit, let line = try? encoder.encode(entry), bytes + line.count < limit * 200 else { break }
            lines.append(line)
            bytes += line.count + 1
        }
        let data = lines.reversed().reduce(into: Data()) { result, line in
            result.append(line)
            result.append(0x0A)
        }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
