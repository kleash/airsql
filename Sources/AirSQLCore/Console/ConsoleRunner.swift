import Foundation

/// How one statement of a console run ended (plan §2.6): its results (a result set each, or rows affected), the
/// server's warnings, or the error and the line of the console's text it points to.
public struct ConsoleOutcome {
    public var statement: SQLStatement
    public var results: [StatementResult] = []
    /// SHOW WARNINGS after it, one line each ("Warning 1292: Truncated incorrect INTEGER value: 'abc'").
    public var warnings: [String] = []
    public var error: AirSQLError?
    /// The line of the console's text the error points to, when the server names one.
    public var errorLine: Int?
    public var duration: TimeInterval = 0
    /// Stopped by the connection's query timeout.
    public var timedOut = false

    public init(statement: SQLStatement) {
        self.statement = statement
    }
}

/// How the console's transactions see each other's changes (SET SESSION TRANSACTION ISOLATION LEVEL).
public enum IsolationLevel: String, CaseIterable, Sendable {
    case readUncommitted = "READ UNCOMMITTED"
    case readCommitted = "READ COMMITTED"
    case repeatableRead = "REPEATABLE READ"
    case serializable = "SERIALIZABLE"

    public var title: String { rawValue.capitalized }
    public var sql: String { "SET SESSION TRANSACTION ISOLATION LEVEL " + rawValue }
}

/// Runs the console's statements, one at a time, on the connection's main session (statements are split on the
/// client: multi-statements stay off).
public enum ConsoleRunner {
    /// The most warnings read after a statement.
    static let warningLimit = 20

    /// Runs `statement` (of `text`, for the line an error points to) on `session`. One that runs longer than
    /// `timeout` seconds (0: no limit) is stopped through Cancel's safe KILL QUERY. A result set stops at `rowCap` rows.
    public static func run(_ statement: SQLStatement, in text: String, on session: DBConnection, rowCap: Int = 100_000,
                           timeout: Int = 0) async -> ConsoleOutcome {
        var outcome = ConsoleOutcome(statement: statement)
        let started = Date()
        let watchdog = Watchdog(seconds: timeout, session: session)
        do {
            outcome.results = try await session.query(statement.sql, rowCap: rowCap)
        } catch {
            let failure = error as? AirSQLError ?? AirSQLError(.other, error.localizedDescription)
            outcome.errorLine = ConsoleScript.errorLine(failure.details.isEmpty ? failure.message : failure.details,
                                                        statement: statement, in: text)
            outcome.error = failure
        }
        // Stopped by the timeout: an error even when the server ended the statement normally (SLEEP and BENCHMARK
        // return early when killed), as what came back is cut short.
        if watchdog.stop() {
            outcome.timedOut = true
            outcome.error = AirSQLError(.cancelled, "The statement ran longer than \(timeout) s, this connection's query "
                                        + "timeout, and was stopped.")
            outcome.errorLine = nil
        }
        outcome.duration = Date().timeIntervalSince(started)
        if outcome.results.contains(where: { $0.warnings > 0 }) {
            outcome.warnings = await warnings(on: session)
        }
        return outcome
    }

    /// The last statement's warnings, as SHOW WARNINGS lists them.
    static func warnings(on session: DBConnection) async -> [String] {
        guard let rows = try? await session.query("SHOW WARNINGS LIMIT \(warningLimit)").first?.rows else { return [] }
        return (0..<rows.rowCount).map { row in
            "\(rows.string(row, 0) ?? "Warning") \(rows.string(row, 1) ?? ""): \(rows.string(row, 2) ?? "")"
        }
    }

    /// Stops the statement under way after `seconds`, unless stopped first.
    private final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false, fired = false
        private var task: Task<Void, Never>?

        init(seconds: Int, session: DBConnection) {
            guard seconds > 0 else { return }
            task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard let self, !Task.isCancelled, self.lock.locked({ () -> Bool in
                    if !self.finished { self.fired = true }
                    return !self.finished
                }) else { return }
                _ = try? await session.cancel()
            }
        }

        /// The statement ended: no more stopping. Whether the watchdog stopped it.
        @discardableResult
        func stop() -> Bool {
            task?.cancel()
            return lock.locked {
                finished = true
                return fired
            }
        }
    }
}
