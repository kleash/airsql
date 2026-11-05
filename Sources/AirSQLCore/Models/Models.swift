// Ported from AirSCP 1.4.0 Sources/AirSCPCore/Models.swift: Env, Store and the append-only Codable models.
import Foundation
import os

/// The colour that marks a connection: a dot in the sidebar, the strip under the toolbar and the active tab's edge.
/// Production also starts with the strict safety preset and agent access Off.
public enum ConnectionColour: String, Codable, CaseIterable {
    case none, production, staging, development, test

    public var title: String {
        switch self {
        case .none: return "None"
        case .production: return "Production"
        case .staging: return "Staging"
        case .development: return "Development"
        case .test: return "Test"
        }
    }
}

/// How a connection reaches its server (plan §2.3). Every route but Direct ends in a private Unix socket on this Mac.
/// The route's own settings (SSH host, jump hosts, proxy) come with the connection editor.
public enum Route: String, Codable, CaseIterable {
    /// TCP to host:port, or the server's own Unix socket.
    case direct
    /// An SSH tunnel through one SSH host.
    case ssh
    /// SSH through one or more jump hosts first.
    case sshJump
    /// SSH, its first hop through an HTTP or SOCKS5 proxy.
    case sshProxy
    /// An HTTP CONNECT or SOCKS5 proxy, no SSH.
    case proxy
}

/// What agents may do with a connection (plan §2.8); a person-only setting.
public enum AgentAccess: String, Codable, CaseIterable {
    case off, schema, schemaRead, schemaReadAnalytics

    public var title: String {
        switch self {
        case .off: return "Off"
        case .schema: return "Schema"
        case .schemaRead: return "Schema + read"
        case .schemaReadAnalytics: return "Schema + read + analytics"
        }
    }
}

/// A saved connection: what the sidebar lists. Passwords are in the Keychain (`Keychain`, by the connection's id),
/// never here. New fields go last with a default and are decoded with `decodeIfPresent`, so older files still load.
public struct SavedConnection: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name = ""
    public var folderID: UUID?
    public var colour = ConnectionColour.none
    public var comment = ""
    public var route = Route.direct
    /// The database server's host name or address as typed: TLS is verified against it, whatever the route.
    public var host = ""
    /// nil: 3306.
    public var port: Int?
    /// The server's own Unix socket (Direct to a local server); empty: TCP to host and port.
    public var socket = ""
    public var user = ""
    /// The password is asked at each connect and held in memory until Disconnect, never saved.
    public var askPassword = false
    /// The database made current after connecting; empty: none.
    public var database = ""
    /// Refuses writes from the console, the grid and agents.
    public var readOnly = false
    /// This connection's own safety settings; nil: the defaults (Settings ▸ Safety), or the Production preset when the
    /// connection is coloured Production (`safety(defaults:)`).
    public var safety: SafetySettings?
    public var agentAccess = AgentAccess.off
    /// Agents may see sample rows (a separate switch from the access level).
    public var agentSampleRows = false
    /// The mysql and mysqldump this connection uses (chosen in the Restore and Export sheets); empty: the best found
    /// for its server, or Settings ▸ Client Tools' choice.
    public var clientPath = ""
    public var dumpPath = ""
    /// The TLS tab. Off for the server's own socket, which never leaves this Mac (`connectOptions`).
    public var tls = TLSOptions()
    /// A PAM or LDAP account, whose login sends the password as plain text: allowed only over TLS that proves the server.
    public var cleartextLogin = false
    /// The compressed protocol.
    public var compress = false
    /// SQL each session runs after logging in (SET sql_mode, time_zone…), statements ended by semicolons.
    public var startupSQL = ""
    /// The databases shown: names or patterns with * and ?, separated by commas; empty: all (`showsDatabase`).
    public var databaseFilter = ""
    /// Seconds a statement may run before it is cancelled; 0: no limit.
    public var queryTimeout = 0
    /// SSH routes: the SSH server that reaches the database, and the jump hosts on the way to it, first hop first.
    public var sshHost = SSHHop()
    public var jumpHosts: [SSHHop] = []
    /// Proxy routes: the proxy to the database (Proxy only) or to the first SSH host (SSH + proxy).
    public var proxy = ProxySettings()

    public init(id: UUID = UUID(), name: String = "", host: String = "", port: Int? = nil, user: String = "",
                colour: ConnectionColour = .none, route: Route = .direct) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.colour = colour
        self.route = route
    }

    /// Connections saved by another version may lack keys; those keep their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let defaults = SavedConnection()
        id = try value(.id, defaults.id)
        name = try value(.name, defaults.name)
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        colour = try value(.colour, defaults.colour)
        comment = try value(.comment, defaults.comment)
        route = try value(.route, defaults.route)
        host = try value(.host, defaults.host)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        socket = try value(.socket, defaults.socket)
        user = try value(.user, defaults.user)
        askPassword = try value(.askPassword, defaults.askPassword)
        database = try value(.database, defaults.database)
        readOnly = try value(.readOnly, defaults.readOnly)
        safety = try container.decodeIfPresent(SafetySettings.self, forKey: .safety)
        agentAccess = try value(.agentAccess, defaults.agentAccess)
        agentSampleRows = try value(.agentSampleRows, defaults.agentSampleRows)
        clientPath = try value(.clientPath, defaults.clientPath)
        dumpPath = try value(.dumpPath, defaults.dumpPath)
        tls = try value(.tls, defaults.tls)
        cleartextLogin = try value(.cleartextLogin, defaults.cleartextLogin)
        compress = try value(.compress, defaults.compress)
        startupSQL = try value(.startupSQL, defaults.startupSQL)
        databaseFilter = try value(.databaseFilter, defaults.databaseFilter)
        queryTimeout = try value(.queryTimeout, defaults.queryTimeout)
        sshHost = try value(.sshHost, defaults.sshHost)
        jumpHosts = try value(.jumpHosts, defaults.jumpHosts)
        proxy = try value(.proxy, defaults.proxy)
    }

    /// The name, else user@host:port (or the socket).
    /// Whether the server is on this Mac: a direct connection to a loopback name (through a route, that name is the far
    /// end's, reached over the network).
    public var isOnThisMac: Bool { route == .direct && ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()) }

    public var displayName: String {
        if !name.isEmpty { return name }
        let server = !socket.isEmpty && route == .direct ? socket : host + (port.map { ":\($0)" } ?? "")
        return (user.isEmpty ? "" : user + "@") + server
    }

    /// The safety settings that apply: its own, else the Production preset for a Production connection, else
    /// `defaults` (Settings ▸ Safety).
    public func safety(defaults: SafetySettings) -> SafetySettings {
        safety ?? (colour == .production ? .production : defaults)
    }

    /// The sidebar's "custom safety" mark: this connection overrides the settings that would apply.
    public var hasCustomSafety: Bool { safety != nil }

    /// What the connection is marked, in words, for wherever its colour alone would have to say it ("" when unmarked).
    public var marks: String {
        [colour == .none ? nil : colour.title, readOnly ? "read-only" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    /// What the sidebar shows at the row's end: Direct, Socket, SSH, Jump or Proxy.
    public var routeBadge: String {
        switch route {
        case .direct: return socket.isEmpty ? "Direct" : "Socket"
        case .ssh: return "SSH"
        case .sshJump: return "Jump"
        case .sshProxy: return "SSH + proxy"
        case .proxy: return "Proxy"
        }
    }
}

/// A sidebar folder of connections (HeidiSQL's session folders).
public struct ConnectionFolder: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name = ""

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// App-wide settings (the Settings window). New fields go last with a default (see `init(from:)`).
public struct AppSettings: Codable, Equatable {
    public enum Appearance: String, Codable, CaseIterable { case system, light, dark }

    public var appearance = Appearance.system
    /// The defaults every connection uses unless it has its own (Settings ▸ Safety, plan §2.10).
    public var safety = SafetySettings()
    /// Settings ▸ Editor: the SQL editor's font size in points (SF Mono).
    public var editorFontSize = 13.0
    /// Settings ▸ Editor: long lines wrap at the editor's edge instead of scrolling sideways. Not `editorWraps`, which
    /// 1.0.1 saved as false for everyone: the name leaves that behind, so this default reaches them.
    public var editorWordWrap = true
    /// Settings ▸ Grid: the grid's font size, rows per page, and how NULL is shown.
    public var gridFontSize = 12.0
    public var rowsPerPage = 1_000
    /// The grid's font family (empty: the system's) and Display As's date format.
    public var gridFontFamily = ""
    /// How many lines of a value with line breaks a grid row shows.
    public var gridRowLines = 1
    public var gridDatePattern = "yyyy-MM-dd HH:mm:ss"
    /// Tables with an AUTO_INCREMENT key open with their newest rows first, until sorted.
    public var newestFirst = true
    /// How much of a long value a table's page reads, in characters; the rest comes on demand. 0: all of it.
    public var longValueLimit = 1_000
    public var nullText = "NULL"
    /// Settings ▸ Connections: above this many tables on a server, a database's columns, indexes and keys load when
    /// it is opened rather than at connect (plan §2.7).
    public var detailsTableThreshold = 3_000
    /// Settings ▸ Agents: AI agents may use AirSQL over MCP. Off until the person turns it on.
    public var agentsAllowed = false
    /// Settings ▸ Client tools: the mysql (or mariadb) and mysqldump (or mariadb-dump) to use; empty: found
    /// automatically.
    public var clientPath = ""
    public var dumpPath = ""
    /// Settings ▸ Liquibase: how changesets and changelogs are written.
    public var liquibase = LiquibaseSettings()
    /// Settings ▸ Grid: Load All asks first when a table has more rows than this.
    public var loadAllAsksAbove = 100_000
    /// Settings ▸ Grid: a console result with one row opens transposed (its columns down the left).
    public var transposeSingleRow = true

    public init() {}

    /// Settings saved by another version may lack keys; those keep their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let defaults = AppSettings()
        appearance = try value(.appearance, defaults.appearance)
        safety = try value(.safety, defaults.safety)
        editorFontSize = try value(.editorFontSize, defaults.editorFontSize)
        editorWordWrap = try value(.editorWordWrap, defaults.editorWordWrap)
        gridFontSize = try value(.gridFontSize, defaults.gridFontSize)
        rowsPerPage = try value(.rowsPerPage, defaults.rowsPerPage)
        longValueLimit = try value(.longValueLimit, defaults.longValueLimit)
        newestFirst = try value(.newestFirst, defaults.newestFirst)
        gridFontFamily = try value(.gridFontFamily, defaults.gridFontFamily)
        gridRowLines = try value(.gridRowLines, defaults.gridRowLines)
        gridDatePattern = try value(.gridDatePattern, defaults.gridDatePattern)
        nullText = try value(.nullText, defaults.nullText)
        detailsTableThreshold = try value(.detailsTableThreshold, defaults.detailsTableThreshold)
        agentsAllowed = try value(.agentsAllowed, defaults.agentsAllowed)
        clientPath = try value(.clientPath, defaults.clientPath)
        dumpPath = try value(.dumpPath, defaults.dumpPath)
        liquibase = try value(.liquibase, defaults.liquibase)
        loadAllAsksAbove = try value(.loadAllAsksAbove, defaults.loadAllAsksAbove)
        transposeSingleRow = try value(.transposeSingleRow, defaults.transposeSingleRow)
    }
}

/// Everything AirSQL saves in airsql.json (secrets excepted: those are in the Keychain).
/// SavedConnection, AppSettings and AirSQLData load files that lack newer keys; new fields in ConnectionFolder must be
/// Optional or get such a decoder.
public struct AirSQLData: Codable, Equatable {
    public var connections: [SavedConnection] = []
    public var folders: [ConnectionFolder] = []
    public var settings = AppSettings()

    public init(connections: [SavedConnection] = [], folders: [ConnectionFolder] = [], settings: AppSettings = AppSettings()) {
        self.connections = connections
        self.folders = folders
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connections = try container.decodeIfPresent([SavedConnection].self, forKey: .connections) ?? []
        folders = try container.decodeIfPresent([ConnectionFolder].self, forKey: .folders) ?? []
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }

    public func connection(_ id: UUID?) -> SavedConnection? {
        id.flatMap { id in connections.first { $0.id == id } }
    }

    /// The safety settings that apply to a connection (`SavedConnection.safety(defaults:)`).
    public func safety(for connection: SavedConnection) -> SafetySettings {
        connection.safety(defaults: settings.safety)
    }
}

/// AirSQL's environment variables: AIRSQL_<name>.
public enum Env {
    public static func value(_ name: String, in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment["AIRSQL_" + name]
    }

    /// A throwaway instance (its own settings folder, AIRSQL_SUPPORT_DIR: tests, smoke runs, agents' instances): it
    /// keeps passwords in memory only and neither reads nor saves the user's window layout.
    public static func isThrowaway(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !(value("SUPPORT_DIR", in: environment) ?? "").isEmpty
    }
}

/// airsql.json in Application Support, written atomically on a background queue (never on the main thread).
public enum Store {
    private static let log = Logger(subsystem: "com.kleash.airsql", category: "store")
    private static let queue = DispatchQueue(label: "com.kleash.airsql.store")

    /// ~/Library/Application Support/AirSQL, or $AIRSQL_SUPPORT_DIR (tests and smoke runs).
    public static var directory: URL {
        if let dir = Env.value("SUPPORT_DIR"), !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("AirSQL", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent("airsql.json") }

    /// The saved data; empty when there is none. An unreadable file is moved aside (airsql.json.unreadable), never
    /// overwritten. File work: call it off the main thread.
    public static func load(from url: URL = fileURL) -> AirSQLData {
        guard let data = try? Data(contentsOf: url) else { return AirSQLData() }
        do {
            return try JSONDecoder().decode(AirSQLData.self, from: data)
        } catch {
            let aside = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            log.error("airsql.json unreadable, moved aside: \(error.localizedDescription, privacy: .public)")
            return AirSQLData()
        }
    }

    /// Writes `data` now (in a folder only this user can open). File work: call it off the main thread.
    public static func save(_ data: AirSQLData, to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(data).write(to: url, options: .atomic)
    }

    private static var pending: AirSQLData?

    /// Saves `data` on the store's queue: a burst of changes writes once, the newest. `failed` runs on the main queue
    /// when the write fails.
    public static func saveLater(_ data: AirSQLData, to url: URL = fileURL, failed: @escaping (Error) -> Void = { _ in }) {
        queue.async {
            let first = pending == nil
            pending = data
            guard first else { return }
            queue.async {
                guard let newest = pending else { return }
                pending = nil
                do {
                    try save(newest, to: url)
                } catch {
                    log.error("can't save airsql.json: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async { failed(error) }
                }
            }
        }
    }

    /// Waits until the writes asked for so far are done (tests, and quitting).
    public static func flush() {
        queue.sync {}
        queue.sync {}
    }
}
