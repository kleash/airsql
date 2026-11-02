import Foundation
import Testing
@testable import AirSQLCore

/// The schema cache's source here: the connection's schema session (the app's comes with the navigator).
private struct SchemaSession: SchemaQuerying {
    let connection: Connection
    func rows(_ sql: String) async throws -> [[String?]] {
        guard let store = try await connection.session(.schema).query(sql, rowCap: .max).first?.rows else { return [] }
        return (0..<store.rowCount).map { row in (0..<store.columns.count).map { store.string(row, $0) } }
    }
}

/// The agent tools against the lab (AIRSQL_LAB=1) on MariaDB and MySQL: read-only queries with caps, timeouts and files,
/// the schema, describe, profile and explain. They only read the fixture. Serialized: one test swaps the classifier.
@Suite(.serialized, .enabled(if: Lab.enabled))
struct AgentLabTests {
    static let servers = [Lab.mariadb114, Lab.mysql84]

    /// A connection to `server`'s fixture as agents reach it.
    static func target(_ server: Lab.Server, _ access: AgentAccess, sampleRows: Bool = false,
                       safety: SafetySettings = SafetySettings()) async throws -> AgentTarget {
        let options = ConnectOptions(name: "Lab", host: "127.0.0.1", port: try #require(server.port), user: Lab.airsql.user,
                                     password: Lab.airsql.password, database: Lab.fixture,
                                     tls: TLSOptions(mode: server.flavor == .mysql ? .required : .off))
        let connection = Connection(options: options)
        try await connection.connect()
        let schema = SchemaCache(source: SchemaSession(connection: connection), includes: { $0 == Lab.fixture })
        var saved = SavedConnection(name: "Lab \(server.name)", host: "127.0.0.1", user: Lab.airsql.user)
        saved.agentAccess = access
        saved.agentSampleRows = sampleRows
        return AgentTarget(saved: saved, safety: safety, connection: connection, schema: schema, database: Lab.fixture)
    }

    /// Accepts what the classifier will accept, roughly: enough to test everything after it.
    static let testClassifier: (String) -> String? = { sql in
        let word = sql.trimmingCharacters(in: .whitespaces).split(separator: " ").first?.uppercased() ?? ""
        return ["SELECT", "WITH", "SHOW", "EXPLAIN", "DESCRIBE"].contains(word) ? nil : "not read-only"
    }

    static func results(_ reply: [String: Any]) -> [[String: Any]] { reply["results"] as? [[String: Any]] ?? [] }

    @Test(arguments: servers)
    func agentsSQLIsRefusedUntilTheClassifierIsInTheBuild(_ server: Lab.Server) async throws {
        let target = try await Self.target(server, .schemaRead)
        defer { Task { await target.connection?.disconnect() } }
        let reply = try await target.runQueries(["queries": [["sql": "SELECT 1"]]])
        #expect(Self.results(reply).first?["ok"] as? Bool == false)
        #expect((Self.results(reply).first?["error"] as? String)?.hasPrefix("Refused") == true)
        await #expect(throws: AirSQLError.self) { try await target.explain(["sql": "SELECT 1"]) }
    }

    @Test(arguments: servers)
    func queriesRunReadOnlyWithinTheirCapsTimeoutsAndFiles(_ server: Lab.Server) async throws {
        AgentReadOnly.refusal = Self.testClassifier
        defer { AgentReadOnly.refusal = AgentReadOnly.untilClassifier }
        var safety = SafetySettings()
        safety.agentRowCap = 2
        safety.agentTimeout = 1
        let target = try await Self.target(server, .schemaReadAnalytics, safety: safety)
        defer { Task { await target.connection?.disconnect() } }

        let reply = try await target.runQueries(["queries": [["sql": "SELECT id, name FROM big ORDER BY id", "max_rows": 3],
                                                             ["sql": "SELECT COUNT(*) AS n FROM customers"],
                                                             ["sql": "SELECT nope FROM customers"]]])
        let results = Self.results(reply)
        #expect(results.count == 3)
        #expect(results[0]["rowCount"] as? Int == 3 && results[0]["capped"] as? Bool == true)
        #expect((results[0]["rows"] as? [[Any]])?.first?.first as? String == "1")
        #expect(results[1]["columns"] as? [String] == ["n"] && results[1]["capped"] as? Bool == false)
        #expect(results[2]["ok"] as? Bool == false && (results[2]["error"] as? String)?.isEmpty == false)

        let csv = Self.results(try await target.runQueries(["queries": [["sql": "SELECT id, name FROM customers ORDER BY id",
                                                                         "max_rows": 2]], "format": "csv"]))
        #expect((csv.first?["csv"] as? String)?.hasPrefix("id,name\r\n1,") == true)

        // Even SQL the classifier wrongly let through can't write: the transaction and the session are read-only.
        AgentReadOnly.refusal = { _ in nil }
        let writes = Self.results(try await target.runQueries(["queries": ["UPDATE customers SET id = id WHERE 1 = 0",
                                                                           "DELETE FROM customers WHERE 1 = 0"]]))
        #expect(writes.allSatisfy { $0["ok"] as? Bool == false }, "\(writes)")
        AgentReadOnly.refusal = Self.testClassifier

        let slow = Self.results(try await target.runQueries(["queries": [
            "SELECT COUNT(*) FROM big a JOIN big b ON a.amount + b.amount < 0"]]))
        #expect((slow.first?["error"] as? String)?.contains("timeout (4 s)") == true, "\(slow)")

        let folder = URL(fileURLWithPath: try scratch()).appendingPathComponent("Agent Exports")
        let files = Self.results(try await target.runQueries([
            "queries": ["SELECT id, name FROM big ORDER BY id", "SELECT id, name FROM customers WHERE id < 0"],
            "to_file": true], exports: folder))
        #expect(files.first?["rowCount"] as? Int == 20 && files.first?["capped"] as? Bool == true)
        let path = try #require(files.first?["file"] as? String)
        #expect(path.hasPrefix(folder.path) && path.hasSuffix(".json"))
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        #expect(json["columns"] as? [String] == ["id", "name"] && (json["rows"] as? [[Any]])?.count == 20)
        let empty = try #require(files.last?["file"] as? String)
        let none = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: empty))) as? [String: Any]
        #expect((none?["rows"] as? [Any])?.isEmpty == true && files.last?["rowCount"] as? Int == 0)
        let csvFile = Self.results(try await target.runQueries(["queries": ["SELECT id FROM customers ORDER BY id LIMIT 2"],
                                                                "to_file": true, "format": "csv"], exports: folder))
        let text = try String(contentsOfFile: try #require(csvFile.first?["file"] as? String), encoding: .utf8)
        #expect(text.hasPrefix("id\r\n1\r\n") && csvFile.first?["capped"] as? Bool == false)

        let plan = try await target.explain(["sql": "SELECT * FROM customers WHERE id = 1;"])
        #expect((plan["columns"] as? [String])?.contains("select_type") == true)
        let jsonPlan = try await target.explain(["sql": "SELECT * FROM customers WHERE id = 1", "format": "json"])
        #expect(((jsonPlan["rows"] as? [[Any]])?.first?.first as? String)?.hasPrefix("{") == true)
    }

    @Test(arguments: servers)
    func schemaDescribeAndProfileReadTheFixture(_ server: Lab.Server) async throws {
        let target = try await Self.target(server, .schemaReadAnalytics, sampleRows: true)
        defer { Task { await target.connection?.disconnect() } }
        let schema = try await target.getSchema([:])
        let text = ((schema["databases"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("customers: id int") && text.contains("UNIQUE(email)"), "\(text.prefix(500))")
        let ddl = try await target.getSchema(["format": "ddl"])
        #expect((((ddl["databases"] as? [[String: Any]])?.first?["text"] as? String) ?? "").contains("CREATE TABLE `customers`"))

        let described = try await target.describe(["objects": ["customers", "fixture.orders", "nope"]])
        let objects = try #require(described["objects"] as? [[String: Any]])
        #expect(objects.compactMap { $0["name"] as? String } == ["customers", "orders"])
        #expect(described["missing"] as? [String] == ["nope"])
        #expect((objects[0]["ddl"] as? String)?.hasPrefix("CREATE TABLE") == true)
        #expect(((objects[0]["sample"] as? [String: Any])?["rows"] as? [[Any]])?.isEmpty == false)
        #expect((objects[0]["referencedBy"] as? [[String: Any]])?.contains { $0["table"] as? String == "orders" } == true)

        let profile = try await target.profile(["table": "big", "columns": ["id", "category", "note"]])
        #expect(profile["rows"] as? Int == Lab.bigRows)
        let columns = try #require(profile["columns"] as? [[String: Any]])
        #expect(columns[0]["distinct"] as? Int == Lab.bigRows && columns[0]["min"] as? String == "1")
        #expect((columns[1]["top"] as? [[String: Any]])?.count == 5)
        #expect(columns[0]["average"] != nil && columns[1]["average"] == nil)
    }
}
