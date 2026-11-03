import Foundation

/// An open console tab as it is kept for the next launch (plan §2.6: unsaved tabs come back after relaunch).
public struct SavedConsole: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var connection: UUID?
    /// The .sql file it shows, if any.
    public var path: String?
    /// The text when it isn't the file's (unsaved changes, or no file); nil: read the file again.
    public var text: String?
    /// The cursor's place (UTF-16).
    public var caret: Int

    public init(id: UUID, title: String, connection: UUID?, path: String?, text: String?, caret: Int) {
        self.id = id
        self.title = title
        self.connection = connection
        self.path = path
        self.text = text
        self.caret = caret
    }
}

/// Consoles.json in Application Support: the console tabs open at the last change, in their order. File work: call
/// these off the main thread.
public enum ConsoleTabStore {
    public static var fileURL: URL { Store.directory.appendingPathComponent("Consoles.json") }

    public static func load(from url: URL = fileURL) -> [SavedConsole] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SavedConsole].self, from: data)) ?? []
    }

    public static func save(_ consoles: [SavedConsole], to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(consoles).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
