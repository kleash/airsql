import Foundation

/// What a table, structure or process-list tab showed, by name only: no rows, filters or edits.
public struct SavedPlace: Codable, Equatable, Sendable {
    /// The last five are `ObjectKind`'s: the object editors.
    public enum Kind: String, Codable, Sendable {
        case table, structure, processes, view, procedure, function, trigger, event
    }

    public var kind: Kind
    public var database: String?
    public var object: String?

    public init(kind: Kind, database: String? = nil, object: String? = nil) {
        self.kind = kind
        self.database = database
        self.object = object
    }
}

/// An open tab as it is kept for the next launch (plan §2.6: unsaved tabs come back after relaunch): a console, or with
/// `place` a tab that comes back as a placeholder.
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
    /// The database a query tab with a session of its own worked in.
    public var database: String?
    /// What the tab showed, when it isn't a console.
    public var place: SavedPlace?
    /// It was the window's preview tab.
    public var preview: Bool?
    /// It was the tab shown.
    public var selected: Bool?

    public init(id: UUID, title: String, connection: UUID?, path: String?, text: String?, caret: Int, place: SavedPlace? = nil,
                preview: Bool? = nil, selected: Bool? = nil, database: String? = nil) {
        self.database = database
        self.id = id
        self.title = title
        self.connection = connection
        self.path = path
        self.text = text
        self.caret = caret
        self.place = place
        self.preview = preview
        self.selected = selected
    }
}

/// The window as it is kept for the next launch: its tabs in their order, and the rows selected in the sidebar.
public struct SavedWindow: Codable, Equatable, Sendable {
    public var tabs: [SavedConsole]
    /// The connections and folders selected.
    public var sidebar: [UUID]

    public init(tabs: [SavedConsole] = [], sidebar: [UUID] = []) {
        self.tabs = tabs
        self.sidebar = sidebar
    }
}

/// Consoles.json in Application Support: the tabs open at the last change, in their order. File work: call
/// these off the main thread.
public enum ConsoleTabStore {
    public static var fileURL: URL { Store.directory.appendingPathComponent("Consoles.json") }

    public static func load(from url: URL = fileURL) -> SavedWindow {
        guard let data = try? Data(contentsOf: url) else { return SavedWindow() }
        if let window = try? JSONDecoder().decode(SavedWindow.self, from: data) { return window }
        // 1.0.0 kept a plain list of consoles.
        return SavedWindow(tabs: (try? JSONDecoder().decode([SavedConsole].self, from: data)) ?? [])
    }

    public static func save(_ window: SavedWindow, to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(window).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
