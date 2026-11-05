import CryptoKit
import Foundation

/// Every saved state of a .sql file, so an older one can come back: a folder per file under LocalHistory in Application
/// Support (0700, each state 0600), the newest `limit` kept. File work: call these off the main thread.
public final class LocalHistory: @unchecked Sendable {
    public static let shared = LocalHistory(directory: Store.directory.appendingPathComponent("LocalHistory", isDirectory: true))

    public struct Version: Equatable, Sendable {
        public var date: Date
        public var url: URL
    }

    let directory: URL
    let limit: Int

    public init(directory: URL, limit: Int = 50) {
        self.directory = directory
        self.limit = limit
    }

    private func folder(_ file: URL) -> URL {
        let name = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    /// The file's saved states, newest first.
    public func versions(of file: URL) -> [Version] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder(file).path)) ?? []
        return names.compactMap { name in
            Double(name.replacingOccurrences(of: ".sql", with: "")).map {
                Version(date: Date(timeIntervalSince1970: $0 / 1000), url: folder(file).appendingPathComponent(name))
            }
        }.sorted { $0.date > $1.date }
    }

    /// Keeps `text` as the file's newest state, unless it is that already.
    public func save(_ text: String, of file: URL, at date: Date = Date()) {
        let existing = versions(of: file)
        if let newest = existing.first, (try? String(contentsOf: newest.url, encoding: .utf8)) == text { return }
        let manager = FileManager.default, folder = folder(file)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(String(Int64(date.timeIntervalSince1970 * 1000)) + ".sql")
        guard manager.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { return }
        for old in existing.dropFirst(limit - 1) { try? manager.removeItem(at: old.url) }
    }
}
