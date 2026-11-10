// The MongoDB spike (docs/dev/mongo-plan.md, Phase 0) against the Mongo lab (testenv/mongo, AIRSQL_MONGO_LAB=1): every
// connection through the stream initiator and a route's sockets, TLS checked per member, Cancel, the aborted
// transaction and a failover.
import CMongoC
import Foundation
import Testing
@testable import AirSQLCore

/// The Mongo lab as testenv/mongo sets it up (testenv/AGENT.md); its servers sit on airsql-lab's inner network.
enum MongoLab {
    static let enabled = ProcessInfo.processInfo.environment["AIRSQL_MONGO_LAB"] == "1"
    static let airsql = Lab.Login(user: "airsql", password: "airsql-pass")
    static let reader = Lab.Login(user: "reader", password: "reader-pass")
    /// The standalone, also on 127.0.0.1:44370; no TLS.
    static let solo = "mongo-solo"
    static let soloPort = 44370
    /// The replica set rs0, TLS required, each member's certificate for its own name from the lab CA.
    static let members = ["mongo-rs1", "mongo-rs2", "mongo-rs3"]
    static let oneSeed = "mongodb://mongo-rs1:27017/?replicaSet=rs0&tls=true"
    static let allSeeds = "mongodb://mongo-rs1:27017,mongo-rs2:27017,mongo-rs3:27017/?replicaSet=rs0&tls=true"
    static let tls = TLSOptions(mode: .verifyIdentity, caFile: Lab.caFile)
    /// Where tests write (dropped after).
    static let scratch = "lane_mongo_spike"

    /// Runs `docker compose` on the Mongo lab (pause, unpause).
    static func compose(_ arguments: [String]) throws {
        let docker = FileManager.default.isExecutableFile(atPath: "/Applications/Docker.app/Contents/Resources/bin/docker")
            ? "/Applications/Docker.app/Contents/Resources/bin/docker" : "/usr/local/bin/docker"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["compose", "-f", Lab.testenv + "/mongo/docker-compose.yml"] + arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SupportError("docker compose \(arguments) failed") }
    }
}

@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter MongoSpikeTests"))
struct MongoSpikeTests {
    /// A saved connection on `route`: the bastion as SSH host; .sshJump and .sshProxy go on through the jump host.
    private func saved(_ route: Route, proxy: Lab.Proxy? = nil) -> SavedConnection {
        var connection = SavedConnection(name: "Mongo lab", host: MongoLab.members[0], port: 27017, user: "airsql", route: route)
        let bastion = SSHHop(host: Lab.bastion.host, port: Lab.bastion.port, user: Lab.bastion.user, login: .keyFile,
                             keyFile: Lab.key)
        connection.sshHost = bastion
        if route == .sshJump || route == .sshProxy {
            // Through a proxy, the bastion is reached by its name inside the lab.
            connection.jumpHosts = [route == .sshProxy ? SSHHop(host: "bastion", port: 22, user: Lab.bastion.user,
                                                               login: .keyFile, keyFile: Lab.key) : bastion]
            connection.sshHost = SSHHop(host: Lab.jump.host, port: Lab.jump.port, user: Lab.jump.user, login: .keyFile,
                                        keyFile: Lab.key)
        }
        if let proxy {
            connection.proxy = ProxySettings(kind: proxy.kind == .socks5 ? .socks5 : .http, host: "127.0.0.1", port: proxy.port,
                                             user: proxy.user)
        }
        return connection
    }

    private func connection(_ uri: String, route: Route, proxy: Lab.Proxy? = Lab.socksProxy,
                            login: Lab.Login = MongoLab.airsql,
                            tls: TLSOptions = MongoLab.tls) throws -> MongoConnection {
        let saved = saved(route, proxy: proxy)
        let askpass = route == .direct || route == .proxy ? nil : try RouteTesting.askpass(for: saved.id)
        return MongoConnection(uri: uri, user: login.user, password: login.password, tls: tls,
                               route: MongoRoute(saved, proxyPassword: proxy?.password ?? "", askpass: askpass))
    }

    private func hello(_ connection: MongoConnection) async throws -> [String: Any] {
        MongoConnection.object(try await connection.command(#"{"hello": 1}"#)) ?? [:]
    }

    @Test func standaloneDirectWithSCRAMSHA256() async throws {
        let uri = "mongodb://127.0.0.1:\(MongoLab.soloPort)/?authMechanism=SCRAM-SHA-256"
        let session = try connection(uri, route: .direct)
        try await session.connect()
        let status = MongoConnection.object(try await session.command(#"{"connectionStatus": 1}"#))
        let users = (status?["authInfo"] as? [String: Any])?["authenticatedUsers"] as? [[String: Any]]
        #expect(users?.first?["user"] as? String == "airsql")
        let count = MongoConnection.object(try await session.command(#"{"count": "all_types"}"#, database: "fixture"))
        #expect(count?["n"] as? Int == 19)
        await session.close()

        let wrong = MongoConnection(uri: uri, user: "airsql", password: "wrong", route: MongoRoute(saved(.direct)))
        await #expect { try await wrong.connect() } throws: { ($0 as? AirSQLError)?.kind == .authFailed }
    }

    @Test func standaloneThroughSSH() async throws {
        let session = try connection("mongodb://mongo-solo:27017/", route: .ssh)
        try await session.connect()
        let count = MongoConnection.object(try await session.command(#"{"count": "all_types"}"#, database: "fixture"))
        #expect(count?["n"] as? Int == 19)
        #expect(session.route.requested == ["mongo-solo:27017"] && session.route.logins == 1)
        await session.close()
    }

    /// One ssh for every member (plan decision 3): one login when the connection string names every member, two when
    /// the seed has to name the others first.
    @Test(arguments: [(MongoLab.oneSeed, 2), (MongoLab.allSeeds, 1)])
    func replicaSetThroughSSH(_ uri: String, _ logins: Int) async throws {
        let started = Date()
        let session = try connection(uri, route: .ssh)
        try await session.connect()
        let found = try await hello(session)
        #expect(found["setName"] as? String == "rs0" && found["isWritablePrimary"] as? Bool == true)
        #expect(Set(session.route.requested) == Set(MongoLab.members.map { $0 + ":27017" }), "\(session.route.requested)")
        #expect(session.route.logins == logins)
        // Each member's certificate was checked against its own name.
        #expect(Set(session.certificates.keys) == Set(MongoLab.members.map { $0 + ":27017" }), "\(session.certificates.keys)")
        print("mongo-spike: ssh, \(uri == MongoLab.oneSeed ? "one seed" : "all seeds"): \(session.route.logins) "
              + "logins, connected in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        await session.close()
    }

    @Test func replicaSetThroughJumpHost() async throws {
        let session = try connection(MongoLab.oneSeed, route: .sshJump)
        try await session.connect()
        #expect(try await hello(session)["isWritablePrimary"] as? Bool == true)
        #expect(session.route.requested.count == 3 && session.route.logins == 2)
        await session.close()
    }

    /// The plan's "done when" route: a proxy, then the bastion, then the jump host.
    @Test func replicaSetThroughProxySSHAndJumpHost() async throws {
        let session = try connection(MongoLab.oneSeed, route: .sshProxy, proxy: Lab.httpProxy)
        try await session.connect()
        #expect(try await hello(session)["isWritablePrimary"] as? Bool == true)
        #expect(session.route.requested.count == 3 && session.certificates.count == 3)
        await session.close()
    }

    @Test(arguments: [Lab.httpProxy, Lab.digestProxy, Lab.socksProxy])
    func replicaSetThroughEachProxy(_ proxy: Lab.Proxy) async throws {
        let session = try connection(MongoLab.oneSeed, route: .proxy, proxy: proxy)
        try await session.connect()
        #expect(try await hello(session)["isWritablePrimary"] as? Bool == true)
        #expect(session.route.requested.count == 3 && session.certificates.count == 3 && session.route.logins == 0)
        await session.close()
    }

    @Test func trustIsCheckedAgainstEachMembersName() async throws {
        // Without the lab CA the Mac doesn't trust the members: the Trust sheet's case, with the certificate.
        let untrusted = try connection(MongoLab.oneSeed, route: .proxy, tls: TLSOptions(mode: .verifyIdentity))
        var shown: TLSCertificate?
        await #expect {
            try await untrusted.connect()
        } throws: { error in
            guard case .untrustedCertificate(let certificate) = (error as? AirSQLError)?.kind else { return false }
            shown = certificate
            return true
        }
        await untrusted.close()
        // Pinned, it connects without the CA (to that member alone: the others show other certificates).
        let certificate = try #require(shown)
        #expect(certificate.summary == "mongo-rs1")
        let pinned = try connection("mongodb://mongo-rs1:27017/?directConnection=true&tls=true", route: .proxy,
                                    tls: TLSOptions(mode: .verifyIdentity, pinnedFingerprint: certificate.fingerprint))
        try await pinned.connect()
        await pinned.close()
        // A member's certificate names it alone.
        for name in ["mongo-rs2", "localhost", "127.0.0.1"] {
            #expect(!TLSCheck(host: name, options: MongoLab.tls).verify([certificate.data]), "\(name)")
        }
        #expect(TLSCheck(host: "mongo-rs1", options: MongoLab.tls).verify([certificate.data]))
    }

    /// A member that takes connections and never answers (paused): what it costs a connect, and Cancel during it.
    @Test func deadMemberCostAndCancel() async throws {
        try MongoLab.compose(["pause", "mongo-rs3"])
        defer { try? MongoLab.compose(["unpause", "mongo-rs3"]) }
        for timeout in [2000, 10_000] {
            let started = Date()
            let session = try connection(MongoLab.allSeeds + "&connectTimeoutMS=\(timeout)", route: .proxy)
            try await session.connect()
            let took = Date().timeIntervalSince(started)
            print("mongo-spike: a paused member, connectTimeoutMS=\(timeout): connected in \(String(format: "%.2f", took)) s")
            #expect(took < Double(timeout) / 1000 + 3)
            await session.close()
        }
        // Cancel: the route closes under the driver, which then gives up at once.
        for route in [Route.proxy, .ssh] {
            let session = try connection(MongoLab.allSeeds + "&connectTimeoutMS=20000", route: route)
            let started = Date()
            let connecting = Task { try await session.connect() }
            try await Task.sleep(nanoseconds: 3_000_000_000)
            session.route.close()
            await #expect(throws: (any Error).self) { try await connecting.value }
            let took = Date().timeIntervalSince(started)
            print("mongo-spike: Cancel during discovery (\(route)): ended after \(String(format: "%.2f", took)) s")
            #expect(took < 6)
            await session.close()
        }
    }

    /// A running find, tagged with a comment, ended by killOp on its member over a second client; and maxTimeMS.
    @Test func cancelRunningOperation() async throws {
        let session = try connection(MongoLab.allSeeds, route: .proxy)
        try await session.connect()
        let (host, id) = try await session.withClient { client -> (String, UInt32) in
            var error = bson_error_t()
            guard let server = mongoc_client_select_server(client, false, nil, &error) else {
                throw MongoConnection.failure(error)
            }
            defer { mongoc_server_description_destroy(server) }
            return (MongoConnection.text(mongoc_server_description_host(server)!.pointee.host_and_port),
                    mongoc_server_description_id(server))
        }
        let tag = "airsql-cancel-" + UUID().uuidString
        let slow = #"{"find": "many", "filter": {"$where": "sleep(20) || true"}, "batchSize": 1000, "comment": "\#(tag)"}"#
        let started = Date()
        let running = Task { try await session.command(slow, database: "fixture", serverID: id) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let killer = try connection("mongodb://\(host)/?directConnection=true&tls=true", route: .proxy)
        try await killer.connect()
        let killed = try await killer.killOperations(comment: tag)
        #expect(killed == 1)
        do {
            _ = try await running.value
            Issue.record("the find wasn't ended")
        } catch let error as AirSQLError {
            #expect(error.code == 11601, "\(error)")  // Interrupted
        }
        print("mongo-spike: killOp ended the find after \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        await killer.close()

        let capped = #"{"find": "many", "filter": {"$where": "sleep(20) || true"}, "maxTimeMS": 300}"#
        await #expect { _ = try await session.command(capped, database: "fixture") } throws: {
            ($0 as? AirSQLError)?.code == 50  // MaxTimeMSExpired
        }
        await session.close()
    }

    /// Agents' second guard (plan): reads run inside a transaction that is always aborted. The server refuses $out and
    /// $merge there.
    @Test func abortedTransactionRefusesOutAndMerge() async throws {
        let session = try connection(MongoLab.allSeeds, route: .proxy)
        try await session.connect()
        // Each in a transaction of its own: an error aborts the transaction it happens in.
        let results = try await session.withClient { client -> [String: String] in
            var results: [String: String] = [:]
            for (name, pipeline) in [("read", #"[{"$match": {"type": "string"}}]"#),
                                     ("$out", #"[{"$out": {"db": "\#(MongoLab.scratch)", "coll": "out"}}]"#),
                                     ("$merge", #"[{"$merge": {"into": {"db": "\#(MongoLab.scratch)", "coll": "merge"}}}]"#)] {
                var error = bson_error_t()
                guard let transaction = mongoc_client_start_session(client, nil, &error),
                      mongoc_client_session_start_transaction(transaction, nil, &error) else {
                    throw MongoConnection.failure(error)
                }
                let command = bson_new_from_json(#"{"aggregate": "all_types", "pipeline": \#(pipeline), "cursor": {}}"#, -1, nil)!
                let options = bson_new()!, reply = bson_new()!
                _ = mongoc_client_session_append(transaction, options, &error)
                let ok = mongoc_client_read_write_command_with_opts(client, "fixture", command, nil, options, reply, &error)
                results[name] = ok ? "ok" : "\(error.code): \(MongoConnection.text(error.message))"
                _ = mongoc_client_session_abort_transaction(transaction, nil)
                [command, options, reply].forEach { bson_destroy($0) }
                mongoc_client_session_destroy(transaction)
            }
            return results
        }
        print("mongo-spike: in a transaction: \(results)")
        #expect(results["read"] == "ok")
        // 263: OperationNotSupportedInTransaction.
        #expect(results["$out"]?.hasPrefix("263:") == true && results["$merge"]?.hasPrefix("263:") == true, "\(results)")
        let databases = try await session.command(#"{"listDatabases": 1, "nameOnly": true}"#)
        #expect(!databases.contains(MongoLab.scratch))
        await session.close()
    }

    /// The primary steps down; the same client finds the new one (retryable writes), no reconnect by hand.
    @Test func failoverIsFollowed() async throws {
        let session = try connection(MongoLab.allSeeds, route: .proxy)
        try await session.connect()
        let before = try #require(try await hello(session)["primary"] as? String)
        func insert() async throws {
            try await session.withClient { client in
                var error = bson_error_t()
                let collection = mongoc_client_get_collection(client, MongoLab.scratch, "failover")!
                defer { mongoc_collection_destroy(collection) }
                let document = bson_new_from_json(#"{"at": "failover"}"#, -1, nil)!
                defer { bson_destroy(document) }
                guard mongoc_collection_insert_one(collection, document, nil, nil, &error) else {
                    throw MongoConnection.failure(error)
                }
            }
        }
        try await insert()
        _ = try? await session.command(#"{"replSetStepDown": 30, "secondaryCatchUpPeriodSecs": 5}"#)
        let started = Date()
        var failures: [String] = []
        while true {
            do {
                try await insert()
                break
            } catch {
                failures.append("\(error)")
                guard Date().timeIntervalSince(started) < 60 else { throw error }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        let after = try await hello(session)["primary"] as? String
        print("mongo-spike: failover \(before) -> \(after ?? "?") followed in "
              + "\(String(format: "%.2f", Date().timeIntervalSince(started))) s, \(failures.count) failed tries first")
        #expect(after != nil && after != before)
        _ = try await session.command(#"{"dropDatabase": 1}"#, database: MongoLab.scratch)
        await session.close()
    }

    /// mongodb+srv: the SRV lookup happens on this Mac (a public record of MongoDB's driver tests, which names
    /// localhost.test.build.10gen.cc:27017), and the host it gives still goes through the route.
    @Test func srvHostsGoThroughTheRoute() async throws {
        let session = try connection("mongodb+srv://test3.test.build.10gen.cc/?tls=false&connectTimeoutMS=2000",
                                     route: .proxy)
        await #expect(throws: (any Error).self) { try await session.connect() }
        #expect(session.route.requested == ["localhost.test.build.10gen.cc:27017"], "\(session.route.requested)")
        await session.close()
    }
}
