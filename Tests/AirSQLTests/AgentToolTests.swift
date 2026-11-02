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

    @Test func agentsSQLIsRefusedUntilTheClassifierIsInTheBuild() {
        #expect(AgentReadOnly.untilClassifier("SELECT 1") != nil)
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
}
