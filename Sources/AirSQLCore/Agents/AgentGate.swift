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
