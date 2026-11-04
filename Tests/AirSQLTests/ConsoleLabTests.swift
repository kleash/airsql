import Foundation
import Testing
@testable import AirSQLCore

/// The console against the lab (AIRSQL_LAB=1): statements run one at a time on the main session, errors point at their
/// line, warnings are read, Cancel and the query timeout stop a statement, and Manual mode holds changes until Commit
/// or Rollback, on MariaDB 11.8 and MySQL 8.4. Writes go to lane_l4_console_<flavour> only.
@Suite(.serialized, .enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
struct ConsoleLabTests {
    func session(_ flavor: String) async throws -> DBConnection {
        // TLS (the servers' own certificates): MySQL's airsql logs in with caching_sha2_password.
        let session = DBConnection(options: DBLab.options(DBLab.server(flavor), tls: DBLab.required), role: .main, log: DBLab.log)
        try await session.connect()
        return session
    }

    func run(_ sql: String, on session: DBConnection, timeout: Int = 0) async -> ConsoleOutcome {
        await ConsoleRunner.run(SQLSplitter.statements(in: sql)[0], in: sql, on: session, timeout: timeout)
    }

    @Test(arguments: ["mariadb", "mysql"])
    func runsStatementsAndPointsErrorsAtTheirLine(_ flavor: String) async throws {
        let session = try await session(flavor)
        let text = "SELECT 1 AS one;\n\nSELECT *\nFORM t;"
        let statements = SQLSplitter.statements(in: text)
        let ok = await ConsoleRunner.run(statements[0], in: text, on: session)
        #expect(ok.error == nil && ok.results.first?.rows?.string(0, 0) == "1" && ok.duration > 0)
        let bad = await ConsoleRunner.run(statements[1], in: text, on: session)
        #expect(bad.error?.kind == .syntax, "\(String(describing: bad.error))")
        #expect(bad.errorLine == 4, "\(bad.error?.message ?? "")")
        #expect(bad.problem?.range == (text as NSString).range(of: "FORM").location..<(text as NSString).range(of: "FORM").location + 4)
        let warned = await run("SELECT CAST('abc' AS SIGNED)", on: session)
        #expect(warned.warnings.first?.contains("1292") == true, "\(warned.warnings)")
        #expect(await run("SELECT 2", on: session).warnings.isEmpty)
        await session.close()
    }

    @Test(arguments: ["mariadb", "mysql"])
    func cancelAndTheQueryTimeoutStopTheStatement(_ flavor: String) async throws {
        let session = try await session(flavor)
        let heavy = "SELECT BENCHMARK(100000000000, MD5('airsql'))"
        let start = Date()
        let timed = await run(heavy, on: session, timeout: 1)
        #expect(timed.error?.kind == .cancelled, "\(String(describing: timed.error))")
        #expect(timed.error?.message.contains("query timeout") == true)
        #expect(Date().timeIntervalSince(start) < 15)

        // A statement the server ends with an error when killed (BENCHMARK and SLEEP just return early).
        let counting = "SELECT COUNT(*) FROM (" + DBLab.numbers(9, on: session.server) + ") AS x"
        let running = Task { await run(counting, on: session) }
        var result = CancelResult.notRunning
        _ = try await eventually(timeout: 5) {
            if session.isBusy { result = try await session.cancel() }
            return result != .notRunning
        }
        let cancelled = await running.value
        #expect(result == .cancelled && cancelled.error?.kind == .cancelled && cancelled.error?.message.contains("query timeout") == false)
        #expect(await run("SELECT 3", on: session).results.first?.rows?.string(0, 0) == "3", "the session carries on")
        await session.close()
    }

    /// EXPLAIN as a table and a tree: MySQL 8.4's own tree, MariaDB's JSON plan flattened.
    @Test(arguments: ["mariadb", "mysql"])
    func explainGivesATableAndATree(_ flavor: String) async throws {
        let session = try await session(flavor)
        // No aliases: both servers name tables by their alias in a plan.
        let sql = "SELECT customers.id, COUNT(orders.id) FROM fixture.customers JOIN fixture.orders "
            + "ON orders.customer_id = customers.id GROUP BY customers.id"
        let table = await run(ExplainPlan.tableSQL(sql), on: session)
        #expect(table.error == nil && (table.results.first?.rows?.rowCount ?? 0) >= 2, "\(String(describing: table.error))")
        let (treeSQL, json) = ExplainPlan.treeSQL(sql, server: session.server)
        #expect(json == (flavor == "mariadb"))
        let answer = try await session.query(treeSQL).first?.rows?.string(0, 0) ?? ""
        let tree = json ? ExplainPlan.tree(fromJSON: answer) : answer
        #expect(tree.contains("customers") && tree.contains("orders"), "\(tree.debugDescription)")
        if json { #expect(tree.hasPrefix("Query block") && !tree.contains("{"), "\(tree)") }
        await session.close()
    }

    @Test(arguments: ["mariadb", "mysql"])
    func manualModeHoldsChangesUntilCommitOrRollback(_ flavor: String) async throws {
        let console = try await session(flavor), other = try await session(flavor)
        let database = "lane_l4_console_\(flavor)"
        for sql in ["DROP DATABASE IF EXISTS \(database)", "CREATE DATABASE \(database)", "CREATE TABLE \(database).t (id INT PRIMARY KEY) ENGINE = InnoDB"] {
            #expect(await run(sql, on: console).error == nil, "\(sql)")
        }
        func count() async throws -> String? {
            try await other.query("SELECT COUNT(*) FROM \(database).t").first?.rows?.string(0, 0)
        }
        #expect(console.autocommit && !console.inTransaction)
        _ = await run("SET autocommit = 0", on: console)
        #expect(!console.autocommit)
        let insert = await run("INSERT INTO \(database).t VALUES (1), (2)", on: console)
        #expect(insert.results.first?.affectedRows == 2 && console.inTransaction && console.transactionStarted != nil)
        #expect(try await count() == "0", "not committed yet")
        _ = await run("ROLLBACK", on: console)
        #expect(!console.inTransaction)
        _ = await run("INSERT INTO \(database).t VALUES (3)", on: console)
        _ = await run("COMMIT", on: console)
        #expect(try await count() == "1" && !console.inTransaction)

        _ = await run(IsolationLevel.readCommitted.sql, on: console)
        let variable = flavor == "mysql" ? "@@transaction_isolation" : "@@tx_isolation"
        let level = await run("SELECT \(variable)", on: console)
        #expect(level.results.first?.rows?.string(0, 0) == "READ-COMMITTED")
        _ = await run("SET autocommit = 1", on: console)
        #expect(console.autocommit)
        _ = await run("DROP DATABASE \(database)", on: console)
        await console.close()
        await other.close()
    }

    /// Query ▸ Profile: performance_schema on MySQL 8.4 (whose stages are off by default, so the statement's own figures),
    /// SHOW PROFILE on MariaDB 11.4, and on MySQL 8.0, whose performance_schema the lab turns off, SHOW PROFILE saying so.
    @Test(arguments: [Lab.mysql84, Lab.mariadb114, Lab.mysql80])
    func profileReadsPerformanceSchemaOnMySQL8(_ server: Lab.Server) async throws {
        let session = DBConnection(options: DBLab.options(server, tls: DBLab.required), role: .main, log: DBLab.log)
        try await session.connect()
        let profile = await QueryProfile.start(on: session)
        // A warning, so AirSQL's SHOW WARNINGS follows the statement, as in the console.
        #expect(await run("SELECT COUNT(*), CAST('abc' AS SIGNED) FROM fixture.customers", on: session).warnings.isEmpty == false)
        let (rows, note) = await profile.read(on: session)
        let columns = rows?.columns.map(\.name) ?? []
        if server.name == "mysql84" {
            #expect(columns.first == "Duration (s)" && columns.contains("Rows examined"), "\(columns)")
            #expect(rows?.string(0, columns.firstIndex(of: "Rows sent") ?? 0) == "1")
            #expect(note?.contains("events_stages_history_long consumer is off") == true, "\(note ?? "")")
        } else {
            #expect(columns == ["Status", "Duration"] && (rows?.rowCount ?? 0) > 3, "\(columns)")
            #expect(note == (server.name == "mysql80" ? "This profile comes from SHOW PROFILE, which MySQL has deprecated: "
                + "performance_schema is off on this server." : nil), "\(note ?? "")")
        }
        await session.close()
    }
}
