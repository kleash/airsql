import Foundation

/// The agents' gate (plan §2.8, R3): what an agent sets off through AirSQL's windows changes nothing until the person at
/// the Mac approves it. The app binds `agent` while it carries out an agent's UI request (a menu command, a button, a
/// key, a click), and the tasks that work starts inherit it. A statement sent from such work on a session of the
/// person's (main, data, tools) that the read-only classifier can't prove read-only waits for `approve`; with no
/// approver it is refused: the gate fails closed. The agent's own session (read-only) and the schema session (only
/// AirSQL's introspection) aren't the person's.
public enum AgentGate {
    /// The agent (its client's name) whose request the current work carries out; nil: the person's own.
    @TaskLocal public static var agent: String?

    /// A statement waiting for the person at the Mac.
    public struct Request: Sendable {
        public var agent: String
        public var sql: String
        /// The saved connection's name (`ConnectOptions.name`).
        public var connection: String
        public var noBackslashEscapes: Bool
    }

    /// Shows the person the statement, and returns once they approved it; throws when they declined. The app sets it.
    public static var approve: (@Sendable (Request) async throws -> Void)? {
        get { lock.locked { approver } }
        set { lock.locked { approver = newValue } }
    }
    private static var approver: (@Sendable (Request) async throws -> Void)?
    private static let lock = NSLock()

    public static let declined = "The person at the Mac declined it: nothing ran."
    static let nobodyToAsk = "An agent's request would change data or structure, and AirSQL has nowhere to ask the person at "
        + "the Mac: nothing ran."

    /// Whether `sql` is proven read-only: what may run for an agent without asking.
    public static func isReadOnly(_ sql: String, noBackslashEscapes: Bool) -> Bool {
        if case .readOnly = ReadOnlyClassifier.classify(sql, noBackslashEscapes: noBackslashEscapes) { return true }
        return false
    }

    /// Before `session` sends `sql`: lets it through, waits for the person's approval, or throws.
    static func check(_ sql: String, on session: DBConnection,
                      approve: (@Sendable (Request) async throws -> Void)? = AgentGate.approve) async throws {
        guard let agent, ![.agent, .schema, .cancel].contains(session.role),
              !isReadOnly(sql, noBackslashEscapes: session.noBackslashEscapes) else { return }
        guard let approve else { throw AirSQLError(.readOnly, nobodyToAsk) }
        try await approve(Request(agent: agent, sql: sql, connection: session.options.name,
                                  noBackslashEscapes: session.noBackslashEscapes))
    }
}

/// What only the person at the Mac may change (plan §2.8), even with approval: who agents may reach and how far, what
/// marks production, what asks first, what AirSQL runs and where and how it connects. Everything but a few plain fields
/// (names, folders, comments, looks), so a field added later is the person's too.
extension AgentGate {
    /// The first person-only change from `old` to `new`, in a few words ("a connection's colour"), or nil. A connection
    /// that is new is compared with a new connection's defaults.
    public static func personOnlyChange(from old: AirSQLData, to new: AirSQLData) -> String? {
        if old.settings.safety != new.settings.safety { return "the safety settings" }
        if old.settings.agentsAllowed != new.settings.agentsAllowed { return "whether agents may use AirSQL" }
        if old.settings.clientPath != new.settings.clientPath || old.settings.dumpPath != new.settings.dumpPath {
            return "the client tools AirSQL runs"
        }
        if personsPart(old.settings) != personsPart(new.settings) { return "these settings" }
        if old.connections.contains(where: { new.connection($0.id) == nil }) { return "which connections there are" }
        for connection in new.connections {
            let before = old.connection(connection.id) ?? SavedConnection(id: connection.id)
            if before.agentAccess != connection.agentAccess || before.agentSampleRows != connection.agentSampleRows {
                return "what agents may do with a connection"
            }
            if before.colour != connection.colour { return "a connection's colour" }
            if before.readOnly != connection.readOnly { return "whether a connection is read-only" }
            if before.safety != connection.safety { return "a connection's safety settings" }
            if personsPart(before) != personsPart(connection) {
                return "a connection's server, route, login, TLS, startup SQL or client tools"
            }
        }
        return nil
    }

    /// The settings without those anyone may change (the look of the app, the editor and the grid).
    static func personsPart(_ settings: AppSettings) -> AppSettings {
        var part = settings
        let plain = AppSettings()
        part.appearance = plain.appearance
        part.editorFontSize = plain.editorFontSize
        part.editorWordWrap = plain.editorWordWrap
        part.editorFontFamily = plain.editorFontFamily
        part.editorTabWidth = plain.editorTabWidth
        part.editorUsesTabs = plain.editorUsesTabs
        part.gridFontSize = plain.gridFontSize
        part.rowsPerPage = plain.rowsPerPage
        part.longValueLimit = plain.longValueLimit
        part.newestFirst = plain.newestFirst
        part.gridFontFamily = plain.gridFontFamily
        part.gridRowLines = plain.gridRowLines
        part.gridDatePattern = plain.gridDatePattern
        part.nullText = plain.nullText
        part.detailsTableThreshold = plain.detailsTableThreshold
        return part
    }

    /// A connection without the fields anyone may change (its name, folder, comment, databases and how its list looks).
    static func personsPart(_ connection: SavedConnection) -> SavedConnection {
        var part = connection
        part.name = ""
        part.folderID = nil
        part.comment = ""
        part.database = ""
        part.databaseFilter = ""
        part.lastDatabase = ""
        return part
    }
}
