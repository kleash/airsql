import Foundation

/// A connection as an agent call reaches it: the person's settings for it, and what is open now.
public struct AgentTarget {
    public var saved: SavedConnection
    /// The safety settings that apply (row cap and timeout).
    public var safety: SafetySettings
    /// The open connection; nil: not connected.
    public var connection: Connection?
    /// Its schema cache; nil: not loaded.
    public var schema: SchemaCache?
    /// The database statements run in when the call names none: the person's current one.
    public var database: String?

    public init(saved: SavedConnection, safety: SafetySettings, connection: Connection? = nil, schema: SchemaCache? = nil,
                database: String? = nil) {
        self.saved = saved
        self.safety = safety
        self.connection = connection
        self.schema = schema
        self.database = database
    }

    /// The access level, which nothing an agent sends can change.
    public var access: AgentAccess { saved.agentAccess }

    /// The most rows a statement returns, and how long it may run: the safety settings', ten and four times as much
    /// with analytics.
    public var rowCap: Int { max(1, safety.agentRowCap) * (access == .schemaReadAnalytics ? 10 : 1) }
    public var timeout: Int { max(1, safety.agentTimeout) * (access == .schemaReadAnalytics ? 4 : 1) }

    /// Refuses unless the access level is at least `level`.
    func require(_ level: AgentAccess) throws {
        guard access.rank >= level.rank else {
            throw AirSQLError(.accessDenied, "“\(saved.displayName)” allows agents \(access.title) access, and this needs "
                              + "\(level.title). Only the person at the Mac can change that (Settings ▸ Agents).")
        }
    }

    /// The agent session, opened on first use, of an open connection.
    func session() async throws -> DBConnection {
        guard let connection else { throw notConnected }
        return try await connection.session(.agent)
    }

    /// The schema as loaded; it loads now if nothing has yet.
    func snapshot() async throws -> SchemaSnapshot {
        guard let schema else { throw notConnected }
        if schema.snapshot.server == nil { try await schema.load() }
        return schema.snapshot
    }

    private var notConnected: AirSQLError {
        AirSQLError(.disconnected, "“\(saved.displayName)” isn't connected: ask the person to connect it in AirSQL.")
    }
}

extension AgentAccess {
    /// Off < Schema < Schema + read < Schema + read + analytics.
    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Agent tool results in MCP's shape.
public enum AgentReply {
    /// A result: `structured` as structuredContent, and the same JSON as text.
    public static func success(_ structured: [String: Any]) -> [String: Any] {
        ["content": [["type": "text", "text": AgentJSON.text(structured)]], "structuredContent": structured, "isError": false]
    }

    /// An error: its message (and the server's words, when they add something).
    public static func failure(_ error: Error) -> [String: Any] {
        AgentBridge.failure(message(error))
    }

    static func message(_ error: Error) -> String {
        guard let error = error as? AirSQLError else { return error.localizedDescription }
        return error.details.isEmpty || error.message == error.details ? error.message : error.message + " " + error.details
    }
}
