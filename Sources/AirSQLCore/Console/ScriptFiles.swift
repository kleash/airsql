import Foundation

/// What the Files panel reads and writes on disk: attached folders, and the scratch files AirSQL keeps for you. File
/// work: call these off the main thread.
public enum ScriptFiles {
    public struct Entry: Equatable, Sendable {
        public var url: URL
        public var isFolder: Bool
    }

    /// The files the panel lists: what a query tab or a sheet of AirSQL can open.
    static let extensions: Set<String> = ["sql", "ddl", "txt", "gz", "csv", "tsv", "xlsx", "json", "jsonl"]

    /// Throwaway files, outside any folder of yours; each save still goes in Local History.
    public static var scratchFolder: URL { Store.directory.appendingPathComponent("Scratches", isDirectory: true) }

    /// A folder's folders, then its files, each by name; hidden ones left out. An unreadable folder is empty.
    public static func entries(in folder: URL) -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: .skipsHiddenFiles)) ?? []
        let entries = urls.compactMap { url -> Entry? in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return isFolder || extensions.contains(url.pathExtension.lowercased()) ? Entry(url: url, isFolder: isFolder) : nil
        }
        return entries.sorted {
            $0.isFolder != $1.isFolder ? $0.isFolder : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    /// The .sql and .sql.gz files a folder's Run takes: its own and its folders', in the order the panel shows them.
    public static func scripts(in folder: URL) -> [URL] {
        entries(in: folder).flatMap { entry -> [URL] in
            if entry.isFolder { return scripts(in: entry.url) }
            let name = entry.url.lastPathComponent.lowercased()
            return name.hasSuffix(".sql") || name.hasSuffix(".sql.gz") ? [entry.url] : []
        }
    }

    /// A new empty file "scratch N.sql", N one more than the largest there.
    public static func newScratch(in folder: URL = scratchFolder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let numbers = entries(in: folder).compactMap { Int($0.url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "scratch ", with: "")) }
        let url = folder.appendingPathComponent("scratch \((numbers.max() ?? 0) + 1).sql")
        try Data().write(to: url, options: .withoutOverwriting)
        return url
    }

    /// The file behind a connection's default console, made empty the first time.
    public static func defaultConsole(of connection: UUID, in folder: URL = scratchFolder) throws -> URL {
        let consoles = folder.appendingPathComponent(".consoles", isDirectory: true)  // hidden: the panel lists no ids
        try FileManager.default.createDirectory(at: consoles, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = consoles.appendingPathComponent(connection.uuidString + ".sql")
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        return url
    }

    /// `url` is one of the scratch files, so closing it saves it without asking.
    public static func isScratch(_ url: URL, in folder: URL = scratchFolder) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }
}
