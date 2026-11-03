import Foundation
import Testing
@testable import AirSQLCore

/// The agents' gate in the driver (plan §2.8, R3): while an agent's request is carried out, a statement on the person's
/// sessions that isn't proven read-only waits for the person, and is refused when nobody can be asked.
@Suite struct AgentGateTests {
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [AgentGate.Request] = []
        var all: [AgentGate.Request] { lock.locked { requests } }
        func add(_ request: AgentGate.Request) { lock.locked { requests.append(request) } }
    }

    static func session(_ role: DBConnection.Role) -> DBConnection {
        DBConnection(options: ConnectOptions(name: "Production", host: "db.invalid", user: "app"), role: role)
    }

    @Test func onlyAnAgentsWritesOnThePersonsSessionsAsk() async throws {
        let asked = Asked()
        let approve: @Sendable (AgentGate.Request) async throws -> Void = { asked.add($0) }
        let writes = ["UPDATE t SET a = 1", "DELETE FROM t", "DROP TABLE t", "COMMIT", "KILL 12", "SET GLOBAL read_only = 0",
                      "SELECT * FROM t FOR UPDATE", "SELECT SLEEP(5)", "SELECT my_function()", "CALL p()", "SELECT 1; DROP TABLE t",
                      "/*!50000 DELETE FROM t */", "LOAD DATA LOCAL INFILE 'x' INTO TABLE t"]
        for sql in writes + ["SELECT * FROM t", "SHOW TABLES", "EXPLAIN SELECT 1"] {
            try await AgentGate.check(sql, on: Self.session(.main), approve: approve)  // the person's own: never asks
        }
        #expect(asked.all.isEmpty)
        try await AgentGate.$agent.withValue("Claude Code") {
            for sql in ["SELECT * FROM t", "SHOW TABLES", "EXPLAIN SELECT 1", "WITH x AS (SELECT 1) SELECT * FROM x"] {
                try await AgentGate.check(sql, on: Self.session(.main), approve: approve)
            }
            #expect(asked.all.isEmpty, "proven read-only runs")
            for role in [DBConnection.Role.main, .data, .tools] {
                for sql in writes { try await AgentGate.check(sql, on: Self.session(role), approve: approve) }
            }
            for role in [DBConnection.Role.agent, .schema] {
                try await AgentGate.check("SET SESSION information_schema_stats_expiry = 0", on: Self.session(role), approve: approve)
            }
        }
        #expect(asked.all.count == writes.count * 3)
        #expect(asked.all.allSatisfy { $0.agent == "Claude Code" && $0.connection == "Production" })
        #expect(asked.all.prefix(writes.count).map(\.sql) == writes)
    }

    @Test func nobodyToAskOrADeclineStopsIt() async throws {
        await AgentGate.$agent.withValue("Claude Code") {
            await #expect(throws: AirSQLError.self) { try await AgentGate.check("DELETE FROM t", on: Self.session(.main), approve: nil) }
            let declined = await #expect(throws: AirSQLError.self) {
                try await AgentGate.check("DELETE FROM t", on: Self.session(.main)) { _ in
                    throw AirSQLError(.cancelled, AgentGate.declined)
                }
            }
            #expect(declined?.message == AgentGate.declined)
        }
    }

    /// The driver asks before anything reaches the server, in the tasks the agent's work starts too: a session that
    /// isn't connected shows which statements got past the gate (they fail as not connected).
    @Test func theDriverAsksFirstAlsoInTasksTheWorkStarts() async throws {
        let session = Self.session(.main)
        func failure(_ sql: String) async -> AirSQLError? {
            do {
                _ = try await session.query(sql)
                return nil
            } catch {
                return error as? AirSQLError
            }
        }
        #expect(await failure("DELETE FROM t")?.kind == .disconnected, "the person's own statement goes to the server")
        let inherited = await AgentGate.$agent.withValue("Claude Code") {
            Task { await failure("DELETE FROM t") }
        }.value
        #expect(inherited != nil && inherited?.kind != .disconnected, "stopped at the gate: \(inherited?.message ?? "")")
        let read = await AgentGate.$agent.withValue("Claude Code") { await failure("SELECT 1") }
        #expect(read?.kind == .disconnected)
        await #expect(throws: AirSQLError.self) {
            try await AgentGate.$agent.withValue("Claude Code") { try await session.stream("DELETE FROM t") { _ in } }
        }
    }
}
