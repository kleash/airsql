import Foundation

/// How agents' statements run (plan §2.8, R4), always with every guard: the read-only classifier accepts the statement
/// (for SQL an agent wrote), on the agent session, which is SET SESSION TRANSACTION READ ONLY (checked through
/// @@transaction_read_only before each statement), inside START TRANSACTION READ ONLY … ROLLBACK, with the server's
/// statement timeout (max_execution_time, MariaDB's max_statement_time) and a watchdog that cancels at the timeout.
/// One agent call at a time per session, so no call's statement runs inside another's transaction.
public enum AgentReadOnly {
    /// Why an agent's statement may not run (nil: it may), for a session whose sql_mode has NO_BACKSLASH_ESCAPES or
    /// not (it decides where strings end). Tests swap it to show the session's own guards.
    public static var refusal: (_ sql: String, _ noBackslashEscapes: Bool) -> String? = classifier

    /// The read-only classifier's verdict.
    static let classifier: (String, Bool) -> String? = { sql, noBackslashEscapes in
        guard case .refused(let reason) = ReadOnlyClassifier.classify(sql, noBackslashEscapes: noBackslashEscapes) else {
            return nil
        }
        return "Refused: " + reason
    }

    /// The refusal of a statement an agent's SQL ended up in, as an error.
    static func check(_ sql: String, on session: DBConnection) throws {
        if let reason = refusal(sql, session.noBackslashEscapes) { throw AirSQLError(.readOnly, reason) }
    }

    /// Runs `body` with the session to itself, its statement timeout set to `timeout` seconds.
    static func session<T>(_ session: DBConnection, timeout: Int,
                           _ body: (Runner) async throws -> T) async throws -> T {
        try await turns.run(session) {
            guard let server = session.server else { throw AirSQLError.disconnected }
            let mariaDB = server.flavor == .mariadb
            _ = try await session.query(mariaDB ? "SET SESSION max_statement_time = \(timeout)"
                                        : "SET SESSION max_execution_time = \(timeout * 1000)")
            let variable = mariaDB ? (server.versionNumber >= 110100 ? "transaction_read_only" : "tx_read_only")
                : (server.versionNumber >= 50720 ? "transaction_read_only" : "tx_read_only")
            let runner = Runner(session: session, timeout: timeout, check: "SELECT @@session." + variable)
            try await runner.checkReadOnly()
            return try await body(runner)
        }
    }

    /// Runs statements read-only on a session `session(_:timeout:_:)` holds.
    struct Runner {
        let session: DBConnection
        let timeout: Int
        let check: String

        func checkReadOnly() async throws {
            guard try await session.query(check).first?.rows?.string(0, 0) == "1" else {
                throw AirSQLError(.readOnly, "AirSQL's agent session isn't read-only, so nothing runs on it.")
            }
        }

        /// One statement and its first result, at most `rowCap` rows; or, with `batch`, the rows go there in batches,
        /// keeping none. `written` (SQL an agent wrote, or took part in) is classified, the session checked again, and
        /// the statement runs in a read-only transaction; AirSQL's own statements (built from quoted names) run as they
        /// are, on the read-only session.
        func run(_ sql: String, written: Bool, rowCap: Int = 1_000,
                 batch: ((ResultStore) throws -> Void)? = nil) async throws -> StatementResult? {
            try Task.checkCancellation()  // the person cancelled the call, or turned agents off
            if written {
                try AgentReadOnly.check(sql, on: session)
                try await checkReadOnly()
                _ = try await session.query("START TRANSACTION READ ONLY")
            }
            let watchdog = Task { [session, timeout] in
                try await Task.sleep(nanoseconds: UInt64(timeout + 2) * 1_000_000_000)
                _ = try? await session.cancel()
            }
            defer { watchdog.cancel() }
            do {
                let result: StatementResult?
                if let batch {
                    try await session.stream(sql, batch: batch)
                    result = nil
                } else {
                    result = try await session.query(sql, rowCap: rowCap).first
                }
                if written { _ = try? await session.query("ROLLBACK") }
                return result
            } catch var error as AirSQLError {
                if written { _ = try? await session.query("ROLLBACK") }
                if Task.isCancelled { throw CancellationError() }  // the person's Cancel stopped it
                // MySQL's max_execution_time (3024), MariaDB's max_statement_time (1969), or the watchdog's KILL QUERY.
                if [3024, 1969, 1317].contains(error.code) || error.kind == .cancelled {
                    error.message = "Stopped at the agent timeout (\(timeout) s)."
                }
                throw error
            } catch {
                if written { _ = try? await session.query("ROLLBACK") }
                throw error
            }
        }
    }

    private static let turns = Turns()

    /// One holder at a time per session; the others wait their turn, in order.
    final class Turns: @unchecked Sendable {
        private let lock = NSLock()
        private var busy: Set<ObjectIdentifier> = []
        private var waiting: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]

        func run<T>(_ key: AnyObject, _ body: () async throws -> T) async throws -> T {
            let id = ObjectIdentifier(key)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now: Bool = lock.locked {
                    if busy.insert(id).inserted { return true }
                    waiting[id, default: []].append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
            defer {
                let next: CheckedContinuation<Void, Never>? = lock.locked {
                    guard var queue = waiting[id], !queue.isEmpty else {
                        busy.remove(id)
                        return nil
                    }
                    let first = queue.removeFirst()
                    waiting[id] = queue.isEmpty ? nil : queue
                    return first  // the turn passes on: still busy
                }
                next?.resume()
            }
            return try await body()
        }
    }
}
