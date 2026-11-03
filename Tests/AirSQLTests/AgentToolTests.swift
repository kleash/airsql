import CMariaDB
import Foundation
import Testing
@testable import AirSQLCore

/// The agent tools' logic without a server: access levels, the compact schema, names and formats.
struct AgentToolTests {
    static func target(_ access: AgentAccess, schema: SchemaCache? = nil, colour: ConnectionColour = .none) -> AgentTarget {
        var saved = SavedConnection(name: "Shop", host: "db.invalid", user: "app", colour: colour)
        saved.agentAccess = access
        return AgentTarget(saved: saved, safety: saved.safety(defaults: SafetySettings()), schema: schema)
    }

    static func refusal(_ body: () async throws -> Any) async -> String? {
        do {
            _ = try await body()
            return nil
        } catch let error as AirSQLError {
            return error.kind == .accessDenied ? error.message : "other: \(error.message)"
        } catch {
            return "other: \(error)"
        }
    }

    @Test func eachToolNeedsItsAccessLevel() async throws {
        let off = Self.target(.off), schema = Self.target(.schema), read = Self.target(.schemaRead)
        let query: [String: Any] = ["queries": [["sql": "SELECT 1"]]]
        #expect(await Self.refusal { try await off.getSchema([:]) }?.contains("needs Schema") == true)
        #expect(await Self.refusal { try await off.describe(["objects": ["t"]]) }?.contains("allows agents Off access") == true)
        #expect(await Self.refusal { try await schema.runQueries(query) }?.contains("needs Schema + read") == true)
        #expect(await Self.refusal { try await schema.explain(["sql": "SELECT 1"]) }?.contains("needs Schema + read") == true)
        #expect(await Self.refusal { try await read.profile(["table": "t"]) }?.contains("analytics") == true)
        let toFile = query.merging(["to_file": true]) { $1 }
        #expect(await Self.refusal { try await read.runQueries(toFile) }?.contains("analytics") == true)
        // Allowed calls go on to need the connection, which isn't open here.
        #expect(await Self.refusal { try await read.runQueries(query) }?.contains("isn't connected") == true)
    }

    @Test func agentsSQLMustBeProvablyReadOnly() {
        for sql in ["SELECT 1", "WITH t AS (SELECT 1 AS a) SELECT a FROM t", "SHOW TABLES", "EXPLAIN SELECT * FROM t"] {
            #expect(AgentReadOnly.classifier(sql, false) == nil, "\(sql)")
        }
        for sql in ["UPDATE t SET a = 1", "SELECT SLEEP(1)", "SELECT 1; DROP TABLE t", "SELECT * FROM t FOR UPDATE",
                    "EXPLAIN ANALYZE SELECT 1", "SELECT a INTO @x FROM t"] {
            #expect(AgentReadOnly.classifier(sql, false)?.hasPrefix("Refused: ") == true, "\(sql)")
        }
    }

    @Test func limitsFollowTheSafetySettingsAndAnalytics() {
        #expect(Self.target(.schemaRead).rowCap == 10_000 && Self.target(.schemaRead).timeout == 30)
        #expect(Self.target(.schemaRead, colour: .production).rowCap == 1_000)
        #expect(Self.target(.schemaRead, colour: .production).timeout == 15)
        #expect(Self.target(.schemaReadAnalytics).rowCap == 100_000 && Self.target(.schemaReadAnalytics).timeout == 120)
    }

    @Test func compactSchemaHasEveryTableOnOneLine() async throws {
        let (cache, _) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
        let target = Self.target(.schema, schema: cache)
        let reply = try await target.getSchema([:])
        let databases = try #require(reply["databases"] as? [[String: Any]])
        #expect(databases.compactMap { $0["name"] as? String } == ["airsql other", "airsql_fixture"])
        let text = try #require(databases.last?["text"] as? String)
        #expect(text.contains("customers: id int(10) unsigned PK AI, email varchar(255), name varchar(100) ='it\\'s'"))
        #expect(text.contains("-- People who buy"))
        #expect(text.contains("`we``ird 'name' ✓`: "))
        #expect(text.contains("view customer_emails: "))
        #expect(text.contains("sequence order_seq: "))
        #expect(text.contains("routines: procedure add_customer, function order_count → int(11)"))
        #expect(text.contains("triggers: ") && text.contains("orders_bi (BEFORE INSERT on orders)"))
        #expect(databases.allSatisfy { $0["details"] as? Bool == true && ($0["hash"] as? String)?.isEmpty == false })
        let hash = try #require(reply["hash"] as? String)
        let again = try await target.getSchema(["if_changed_from": hash])
        #expect(again["unchanged"] as? Bool == true && again["databases"] == nil)
        let one = try await target.getSchema(["databases": ["airsql_fixture"]])
        #expect((one["databases"] as? [[String: Any]])?.count == 1 && one["hash"] as? String != hash)
        #expect(await Self.refusal { try await target.getSchema(["databases": ["nope"]]) }?.contains("No database") == true)
        let resource = try await target.schemaText()
        #expect(resource.hasPrefix("-- Shop · schema hash \(hash)") && resource.contains("-- database `airsql other`"))
    }

    /// search_columns answers from the schema cache, sending nothing: part of a name, or a whole name with * and ?,
    /// narrowed by data type.
    @Test func searchColumnsReadsTheCache() async throws {
        let (cache, source) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
        let target = Self.target(.schema, schema: cache)
        let sent = source.sent.count
        func found(_ arguments: [String: Any]) async throws -> Set<String> {
            let reply = try await target.searchColumns(arguments)
            #expect(reply["connection"] as? String == "Shop" && reply["capped"] as? Bool == false)
            return Set((reply["columns"] as? [[String: Any]] ?? []).map { "\($0["table"] ?? "").\($0["column"] ?? "")" })
        }
        #expect(try await found(["pattern": "EMAIL"]) == ["customers.email", "customers.email_domain", "customer_emails.email"])
        #expect(try await found(["pattern": "*_id"]) == ["refs.customer_id", "orders.customer_id", "orders.parent_id"])
        #expect(try await found(["pattern": "id", "type": "BIGINT"]) == ["orders.id", "orders.parent_id"])
        #expect(try await found(["pattern": "*", "type": "*text", "databases": ["airsql_fixture"]])
                == ["customers.note", "customers.prefs"])
        let reply = try await target.searchColumns(["pattern": "id", "databases": ["airsql_fixture"]])
        let columns = try #require(reply["columns"] as? [[String: Any]])
        let id = try #require(columns.first { $0["table"] as? String == "customers" && $0["column"] as? String == "id" })
        #expect(id["type"] as? String == "int(10) unsigned" && id["primaryKey"] as? Bool == true && id["nullable"] as? Bool == false)
        #expect(columns.first { $0["table"] as? String == "customer_emails" }?["kind"] as? String == "view")
        #expect(source.sent.count == sent, "no SQL")
        #expect(await Self.refusal { try await target.searchColumns(["pattern": " "]) }?.contains("needs a pattern") == true)
        #expect(await Self.refusal { try await Self.target(.off, schema: cache).searchColumns(["pattern": "id"]) }?
            .contains("needs Schema") == true)
    }

    @Test func namesSplitOutsideBackquotes() {
        #expect(AgentTarget.split("orders") == (nil, "orders"))
        #expect(AgentTarget.split("shop.orders") == ("shop", "orders"))
        #expect(AgentTarget.split("`my db`.`order details`") == ("my db", "order details"))
        #expect(AgentTarget.split("`a.b`") == (nil, "a.b"))
        #expect(AgentTarget.split("`x``y`.z") == ("x`y", "z"))
    }

    @Test func csvQuotesOnlyWhatItMust() {
        #expect(AgentFormat.csvField("plain") == "plain")
        #expect(AgentFormat.csvField("") == "\"\"")
        #expect(AgentFormat.csvField("a,b") == "\"a,b\"")
        #expect(AgentFormat.csvField("say \"hi\"\n") == "\"say \"\"hi\"\"\n\"")
        #expect(AgentFormat.name("orders") == "orders" && AgentFormat.name("order details") == "`order details`")
    }

    /// A reply names its columns' types as the grid's header does: unsigned kept, MySQL 9's VECTOR named.
    @Test func columnTypesAreTheGridsNames() {
        let store = ResultStore(columns: [ResultStore.Column(name: "id", type: MYSQL_TYPE_LONGLONG, flags: UInt32(UNSIGNED_FLAG)),
                                          ResultStore.Column(name: "v", type: MYSQL_TYPE_VECTOR, charset: 63),
                                          ResultStore.Column(name: "note", type: MYSQL_TYPE_VAR_STRING)])
        #expect(AgentFormat.columns(store).types == ["bigint unsigned", "vector", "varchar"])
    }

    @Test func setupShowsTheChangeThenMakesIt() throws {
        let home = URL(fileURLWithPath: try scratch())
        let program = "/Applications/AirSQL.app/Contents/MacOS/AirSQL"
        let first = try AgentSetup.plan(.claudeCode, home: home, program: program, supportDir: nil)
        #expect(first.before == nil && first.after.contains("\"--mcp\"") && first.after.contains("\"stdio\""))
        try AgentSetup.apply(first)
        let claude = home.appendingPathComponent(".claude.json")
        #expect((try FileManager.default.attributesOfItem(atPath: claude.path)[.posixPermissions] as? Int) == 0o600)
        #expect(try AgentSetup.plan(.claudeCode, home: home, program: program, supportDir: nil).unchanged)

        let gemini = home.appendingPathComponent(".gemini/settings.json")
        try FileManager.default.createDirectory(at: gemini.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme": "Default", "mcpServers": {"other": {"command": "x"}}}"#.utf8).write(to: gemini)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: gemini.path)
        let change = try AgentSetup.plan(.geminiCLI, home: home, program: program, supportDir: "/tmp/a b")
        #expect(change.before == nil && change.after.contains("AIRSQL_SUPPORT_DIR") && !change.after.contains("stdio"))
        try AgentSetup.apply(change)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: gemini)) as? [String: Any])
        let servers = try #require(written["mcpServers"] as? [String: Any])
        #expect(written["theme"] as? String == "Default" && servers["other"] != nil)
        #expect((servers["airsql"] as? [String: Any])?["command"] as? String == program)
        #expect(FileManager.default.fileExists(atPath: gemini.path + ".airsql-backup"))
        #expect((try FileManager.default.attributesOfItem(atPath: gemini.path)[.posixPermissions] as? Int) == 0o644)

        try Data("// a comment\n{}".utf8).write(to: gemini)
        #expect(throws: AirSQLError.self) { try AgentSetup.plan(.geminiCLI, home: home, program: program, supportDir: nil) }
        #expect(AgentSetup.Client.claudeCode.command(program: "/Apps/Air SQL.app/x", supportDir: nil)
                == "claude mcp add --scope user airsql -- '/Apps/Air SQL.app/x' --mcp")
    }
}
