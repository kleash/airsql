import Foundation
import os

/// How one table's grid was last left (plan §2.4): the WHERE filter and the last 20 filters, the sort, hidden columns,
/// column widths and display types, so a table opens as it was. Results of a query use the query's text as `table`.
public struct TableViewSettings: Codable, Equatable {
    public struct SortKey: Codable, Equatable {
        public var column: String
        public var ascending: Bool

        public init(column: String, ascending: Bool) {
            self.column = column
            self.ascending = ascending
        }
    }

    /// The WHERE bar's text, without "WHERE".
    public var filter = ""
    /// Newest first, at most `recentLimit`.
    public var recentFilters: [String] = []
    public var sort: [SortKey] = []
    public var hiddenColumns: [String] = []
    /// Column widths in points, by column name.
    public var widths: [String: Double] = [:]
    /// Display types by column name (the grid names them: "uuid", "hex", "unixTime"…).
    public var displayTypes: [String: String] = [:]
    /// The time zones date columns are shown in, by column name ("utcToLocal", "localToUTC").
    public var displayZones: [String: String] = [:]
    /// The columns' order on screen, by name, as last arranged (hidden ones too); [] for the table's own order.
    public var order: [String] = []
    /// How many columns, from the first shown, stay in view while the grid scrolls across (Freeze).
    public var frozenColumns = 0
    /// Foreign keys the person defined for the table, which the database doesn't have: the drop-down, Related Rows, the
    /// labels and the ER diagram follow them. Kept on this Mac, never written to the server.
    public var virtualKeys: [SchemaForeignKey] = []
    /// The column a row is shown by beside a key that refers to it ("Ada Lovelace" after 12); nil: the first text column.
    public var labelColumn: String?
    /// The database's saved ER diagrams, on the settings of the table named "" (the database itself).
    public var diagrams: [ERLayout] = []

    public static let recentLimit = 20

    public init() {}

    /// Puts `filter` first in the recent filters (once), keeping the newest `recentLimit`.
    public mutating func remember(_ filter: String) {
        let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        recentFilters.removeAll { $0 == text }
        recentFilters.insert(text, at: 0)
        if recentFilters.count > Self.recentLimit { recentFilters.removeLast(recentFilters.count - Self.recentLimit) }
    }

    /// Settings saved by another version may lack keys; those keep their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filter = try container.decodeIfPresent(String.self, forKey: .filter) ?? ""
        recentFilters = try container.decodeIfPresent([String].self, forKey: .recentFilters) ?? []
        sort = try container.decodeIfPresent([SortKey].self, forKey: .sort) ?? []
        hiddenColumns = try container.decodeIfPresent([String].self, forKey: .hiddenColumns) ?? []
        widths = try container.decodeIfPresent([String: Double].self, forKey: .widths) ?? [:]
        displayTypes = try container.decodeIfPresent([String: String].self, forKey: .displayTypes) ?? [:]
        displayZones = try container.decodeIfPresent([String: String].self, forKey: .displayZones) ?? [:]
        order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        frozenColumns = try container.decodeIfPresent(Int.self, forKey: .frozenColumns) ?? 0
        virtualKeys = try container.decodeIfPresent([SchemaForeignKey].self, forKey: .virtualKeys) ?? []
        labelColumn = try container.decodeIfPresent(String.self, forKey: .labelColumn)
        diagrams = try container.decodeIfPresent([ERLayout].self, forKey: .diagrams) ?? []
    }
}

/// Every table's `TableViewSettings`, in tableviews.json next to airsql.json, by connection, database and table.
/// Thread-safe; changes are written on a background queue, a burst of them once.
public final class TableViewSettingsStore {
    public static let shared = TableViewSettingsStore(fileURL: Store.directory.appendingPathComponent("tableviews.json"))

    private static let log = Logger(subsystem: "com.kleash.airsql", category: "tableviews")
    private let fileURL: URL
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.kleash.airsql.tableviews")
    private var all: [String: TableViewSettings]?
    private var writing = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private static func key(_ connection: UUID, _ database: String, _ table: String) -> String {
        // A separator no identifier holds (names may contain dots and slashes).
        [connection.uuidString, database, table].joined(separator: "\u{1F}")
    }

    /// The settings of one table (empty ones when it has none). Reads the file the first time: call it off the main
    /// thread then, or after `load()`.
    public func settings(connection: UUID, database: String, table: String) -> TableViewSettings {
        lock.lock()
        defer { lock.unlock() }
        return loaded()[Self.key(connection, database, table)] ?? TableViewSettings()
    }

    public func set(_ settings: TableViewSettings, connection: UUID, database: String, table: String) {
        lock.lock()
        var everything = loaded()
        everything[Self.key(connection, database, table)] = settings == TableViewSettings() ? nil : settings
        all = everything
        lock.unlock()
        saveLater()
    }

    /// Forgets every table of a connection (the connection was deleted).
    public func removeAll(connection: UUID) {
        lock.lock()
        let prefix = connection.uuidString + "\u{1F}"
        all = loaded().filter { !$0.key.hasPrefix(prefix) }
        lock.unlock()
        saveLater()
    }

    /// The virtual foreign keys of a connection's tables, by database and table.
    public func virtualKeys(connection: UUID) -> [String: [String: [SchemaForeignKey]]] {
        lock.lock()
        defer { lock.unlock() }
        var keys: [String: [String: [SchemaForeignKey]]] = [:]
        for (key, settings) in loaded() where !settings.virtualKeys.isEmpty {
            let parts = key.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[0] == connection.uuidString else { continue }
            keys[parts[1], default: [:]][parts[2]] = settings.virtualKeys
        }
        return keys
    }

    /// Reads the file now (off the main thread), so later calls don't.
    public func load() {
        lock.lock()
        defer { lock.unlock() }
        _ = loaded()
    }

    /// Waits for the writes asked for so far (tests).
    public func flush() {
        queue.sync {}
        queue.sync {}
    }

    private func loaded() -> [String: TableViewSettings] {
        if let all { return all }
        let read = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: TableViewSettings].self, from: $0) }
        all = read ?? [:]
        return all!
    }

    private func saveLater() {
        queue.async { [self] in
            guard !writing else { return }
            writing = true
            queue.async { [self] in
                writing = false
                lock.lock()
                let snapshot = all ?? [:]
                lock.unlock()
                do {
                    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
                } catch {
                    Self.log.error("can't save tableviews.json: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
