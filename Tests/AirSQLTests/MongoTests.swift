// MongoDB's core (docs/dev/mongo-plan.md, lane M1): connection strings, plain-words errors and the command log's
// redaction; then, against the Mongo lab (testenv/mongo, AIRSQL_MONGO_LAB=1), every route, trust per member, Cancel,
// byte-bounded batches, every BSON type through insert and find, transactions, explain, and a failover.
import CMongoC
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The Mongo lab as testenv/mongo sets it up (testenv/AGENT.md); its servers sit on airsql-lab's inner network.
enum MongoLab {
    static let enabled = ProcessInfo.processInfo.environment["AIRSQL_MONGO_LAB"] == "1"
    static let airsql = Lab.Login(user: "airsql", password: "airsql-pass")
    /// The standalone, also on 127.0.0.1:44370; no TLS.
    static let solo = "mongo-solo"
    static let soloPort = 44370
    /// The replica set rs0, TLS required, each member's certificate for its own name from the lab CA.
    static let members = ["mongo-rs1", "mongo-rs2", "mongo-rs3"]
    static let oneSeed = "mongodb://mongo-rs1:27017/?replicaSet=rs0&tls=true"
    static let allSeeds = "mongodb://mongo-rs1:27017,mongo-rs2:27017,mongo-rs3:27017/?replicaSet=rs0&tls=true"
    static let tls = TLSOptions(mode: .verifyIdentity, caFile: Lab.caFile)
    /// Where tests write (dropped after).
    static let scratch = "lane_mongo_m1"

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

private func document(_ fields: KeyValuePairs<String, BSONValue>) -> BSONDocument {
    BSONDocument(fields.map { ($0.key, $0.value) })
}

struct MongoTests {
    @Test func connectionStringsAreTakenApart() throws {
        let uri = try MongoURI("mongodb://us%40er:p%40ss%3Aw%2Fd@db1.example.com:27018,[::1]:27019,db3/shop?replicaSet=rs0&authSource=admin&readPreference=secondary")
        #expect(!uri.srv && uri.hosts == ["db1.example.com:27018", "[::1]:27019", "db3"])
        #expect(uri.user == "us@er" && uri.password == "p@ss:w/d" && uri.database == "shop")
        #expect(uri.option("replicaset") == "rs0" && uri.option("AUTHSOURCE") == "admin")
        #expect(MongoURI.split("[::1]:27019")! == ("::1", 27019) && MongoURI.split("db3")! == ("db3", nil))
        #expect(MongoURI.split("db:0") == nil && MongoURI.split("[::1") == nil && MongoURI.split("") == nil)
        // Put back together, it reads the same.
        let again = try MongoURI(uri.string)
        #expect(again.hosts == uri.hosts && again.user == uri.user && again.password == uri.password
                && again.options.map(\.value) == uri.options.map(\.value))

        let srv = try MongoURI("mongodb+srv://cluster0.example.net/?retryWrites=true&w=majority")
        #expect(srv.srv && srv.hosts == ["cluster0.example.net"] && srv.user == nil && srv.database == "")
        for bad in ["http://x", "mongodb://", "mongodb://a,,b", "mongodb+srv://a:27017", "mongodb+srv://a,b", "mongodb://a/?w",
                    "mongodb://a:99999", "mongodb://u:%zz@a"] {
            #expect(throws: AirSQLError.self, "\(bad)") { try MongoURI(bad) }
        }
    }

    @Test func aConnectionStringFillsASavedConnectionWithoutItsPassword() throws {
        var saved = SavedConnection(name: "Docs")
        saved.engine = .mongodb
        let password = saved.apply(try MongoURI("mongodb://app:s3cr%C3%A9t@m1:27017,m2:27018/orders?replicaSet=rs0&tls=true"
                                                + "&tlsCAFile=%2Ftmp%2Fca.pem&authSource=admin&w=majority&appName=x%26y"))
        #expect(password == "s3crét")
        #expect(saved.host == "m1" && saved.port == 27017 && saved.mongoHosts == ["m2:27018"] && saved.user == "app")
        #expect(saved.database == "orders" && saved.replicaSet == "rs0" && saved.authSource == "admin" && !saved.mongoSRV)
        #expect(saved.tls.mode == .verifyIdentity && saved.tls.caFile == "/tmp/ca.pem")
        #expect(saved.mongoOptions == "w=majority&appName=x%26y")
        let back = try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(saved))
        #expect(try back == saved && !String(decoding: JSONEncoder().encode(saved), as: UTF8.self).contains("s3cr"))

        // What it connects with: no login, TLS on (TLSCheck checks it), the options kept, a short connect timeout.
        let uri = saved.mongoURI
        #expect(uri.string == "mongodb://m1:27017,m2:27018/orders?tls=true&authSource=admin&replicaSet=rs0&w=majority"
                + "&appName=x%26y&connectTimeoutMS=5000")

        var plain = SavedConnection()
        _ = plain.apply(try MongoURI("mongodb://[::1]/?directConnection=true&tlsInsecure=true&ssl=true&connectTimeoutMS=900"))
        #expect(plain.host == "::1" && plain.port == nil && plain.directConnection && plain.tls.mode == .required)
        #expect(plain.mongoURI.string == "mongodb://[::1]/?tls=true&directConnection=true&connectTimeoutMS=900")
        _ = plain.apply(try MongoURI("mongodb://h"))
        #expect(plain.tls.mode == .off && !plain.directConnection && plain.mongoURI.string == "mongodb://h/?connectTimeoutMS=5000")
        _ = plain.apply(try MongoURI("mongodb+srv://c.example.net/?tls=false"))
        #expect(plain.mongoSRV && plain.tls.mode == .off && plain.mongoURI.string == "mongodb+srv://c.example.net/?tls=false&connectTimeoutMS=5000")

        // Agents may not change where it connects.
        var moved = saved
        moved.replicaSet = "rs1"
        #expect(AgentGate.personOnlyChange(from: AirSQLData(connections: [saved]), to: AirSQLData(connections: [moved])) != nil)
    }

    @Test func cancelsSideSessionGoesToOneMemberWithTheSameLogin() throws {
        let route = MongoRoute(SavedConnection())
        let srv = MongoConnection(uri: "mongodb+srv://c.example.net/?replicaSet=x&w=1", route: route)
        #expect(try srv.direct(to: "c-1.example.net:27017") == "mongodb://c-1.example.net:27017/?w=1&tls=true&authSource=admin&directConnection=true")
        let set = MongoConnection(uri: "mongodb://a,b/db?tls=false&replicaSet=rs0", route: route)
        #expect(try set.direct(to: "b:27017") == "mongodb://b:27017/db?tls=false&directConnection=true")
    }

    @Test func theCommandLogHidesSecrets() {
        let command = document(["createUser": .string("app"), "pwd": .string("hunter2"),
                                "roles": .array([.document(document(["Password": .string("x"), "db": .string("shop")]))]),
                                "key": .document(document(["a": .int32(1)]))])
        let line = MongoLog.line(command)
        #expect(!line.contains("hunter2") && !line.contains("\"x\"") && line.contains("<secret>") && line.contains("shop"))
        #expect(line.contains("a: 1"), "\(line)")
    }

    @Test func errorsAreInPlainWords() {
        let server = MONGOC_ERROR_SERVER.rawValue
        #expect(MongoErrorMapping.map(domain: server, code: 18, message: "Authentication failed.").kind == .authFailed)
        #expect(MongoErrorMapping.map(domain: MONGOC_ERROR_CLIENT.rawValue, code: MONGOC_ERROR_CLIENT_AUTHENTICATE.rawValue,
                                      message: "Authentication failed.").kind == .authFailed)
        #expect(MongoErrorMapping.map(domain: server, code: 50, message: "operation exceeded time limit").kind == .timeout)
        #expect(MongoErrorMapping.map(domain: server, code: 11601, message: "operation was interrupted").kind == .cancelled)
        #expect(MongoErrorMapping.map(domain: server, code: 10107, message: "not primary").kind == .readOnly)
        #expect(MongoErrorMapping.map(domain: server, code: 13, message: "not authorized").kind == .accessDenied)
        #expect(MongoErrorMapping.map(domain: server, code: 263, message: "$out in a transaction").message
                == "The server doesn't allow that command here.")
        #expect(MongoErrorMapping.map(domain: server, code: 11000, message: "E11000").kind == .duplicate)
        // A network error: on a read it's a lost connection, on a write an unknown outcome (never sent again).
        let stream = MONGOC_ERROR_STREAM.rawValue, socket = MONGOC_ERROR_STREAM_SOCKET.rawValue
        #expect(MongoErrorMapping.map(domain: stream, code: socket, message: "socket error").kind == .disconnected)
        #expect(MongoErrorMapping.map(domain: stream, code: socket, message: "socket error", write: true).kind == .outcomeUnknown)
        #expect(MongoErrorMapping.map(domain: server, code: 112, message: "x", labels: ["UnknownTransactionCommitResult"]).kind
                == .outcomeUnknown)
        #expect(MongoErrorMapping.map(domain: MONGOC_ERROR_SERVER_SELECTION.rawValue,
                                      code: MONGOC_ERROR_SERVER_SELECTION_FAILURE.rawValue, message: "No suitable servers found: timed out").kind == .timeout)
        let other = MongoErrorMapping.map(domain: server, code: 9999, message: "something new")
        #expect(other.kind == .other && other.message == "something new" && other.code == 9999)
    }
}

// MARK: The lab

@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter Mongo"))
struct MongoLabTests {
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

    private func connection(_ uri: String, route: Route, proxy: Lab.Proxy? = Lab.socksProxy, login: Lab.Login = MongoLab.airsql,
                            tls: TLSOptions = MongoLab.tls, log: SQLLog = .shared) throws -> MongoConnection {
        let saved = saved(route, proxy: proxy)
        let askpass = route == .direct || route == .proxy ? nil : try RouteTesting.askpass(for: saved.id)
        return MongoConnection(uri: uri, user: login.user, password: login.password, tls: tls,
                               route: MongoRoute(saved, proxyPassword: proxy?.password ?? "", askpass: askpass),
                               name: "Mongo lab", log: log)
    }

    private static let solo = "mongodb://127.0.0.1:\(MongoLab.soloPort)/?authMechanism=SCRAM-SHA-256"

    /// The standalone, and the replica set through a proxy.
    private func both() throws -> [MongoConnection] {
        [try connection(Self.solo, route: .direct), try connection(MongoLab.allSeeds, route: .proxy)]
    }

    private func hello(_ connection: MongoConnection) async throws -> BSONDocument {
        try await connection.session(.main).command(document(["hello": .int32(1)]), database: "admin")
    }

    @Test func standaloneDirectWithSCRAMSHA256() async throws {
        let session = try connection(Self.solo, route: .direct)
        let server = try await session.connect()
        #expect(server.version.hasPrefix("7.0") && server.setName == nil && server.summary.hasSuffix("standalone"))
        let status = try await session.session(.main).command(document(["connectionStatus": .int32(1)]), database: "admin")
        guard case .document(let auth)? = status["authInfo"], case .array(let users)? = auth["authenticatedUsers"],
              case .document(let user)? = users.first else { Issue.record("\(status)"); return }
        #expect(user["user"] == .string("airsql"))
        #expect(try await session.session(.data).estimatedCount(database: "fixture", collection: "all_types") == 19)
        await session.close()

        let wrong = MongoConnection(uri: Self.solo, user: "airsql", password: "wrong", route: MongoRoute(saved(.direct)))
        await #expect { try await wrong.connect() } throws: { ($0 as? AirSQLError)?.kind == .authFailed }
        // Again over the same route, with the right password.
        wrong.password = MongoLab.airsql.password
        #expect(try await wrong.connect().version == server.version)
        await wrong.close()
    }

    @Test func standaloneThroughSSH() async throws {
        let session = try connection("mongodb://mongo-solo:27017/", route: .ssh)
        try await session.connect()
        #expect(try await session.session(.main).estimatedCount(database: "fixture", collection: "all_types") == 19)
        #expect(session.route.requested == ["mongo-solo:27017"] && session.route.logins == 1)
        await session.close()
    }

    /// One ssh for every member (plan decision 3): one login when the connection string names every member, two when
    /// the seed has to name the others first. Each member's certificate is checked against its own name.
    @Test(arguments: [(MongoLab.oneSeed, 2), (MongoLab.allSeeds, 1)])
    func replicaSetThroughSSH(_ uri: String, _ logins: Int) async throws {
        let session = try connection(uri, route: .ssh)
        let server = try await session.connect()
        #expect(server.setName == "rs0" && server.primary != nil && server.summary.hasSuffix("replica set rs0"))
        #expect(try await hello(session)["isWritablePrimary"] == .bool(true))
        #expect(Set(session.route.requested) == Set(MongoLab.members.map { $0 + ":27017" }), "\(session.route.requested)")
        #expect(session.route.logins == logins)
        #expect(Set(session.certificates.keys) == Set(MongoLab.members.map { $0 + ":27017" }), "\(session.certificates.keys)")
        // Another session reuses the forwards: no more logins.
        _ = try await session.session(.data).listDatabases()
        #expect(session.route.logins == logins)
        await session.close()
    }

    @Test func replicaSetThroughJumpHost() async throws {
        let session = try connection(MongoLab.oneSeed, route: .sshJump)
        try await session.connect()
        #expect(try await hello(session)["isWritablePrimary"] == .bool(true))
        #expect(session.route.requested.count == 3 && session.route.logins == 2)
        await session.close()
    }

    /// The plan's "done when" route: a proxy, then the bastion, then the jump host.
    @Test func replicaSetThroughProxySSHAndJumpHost() async throws {
        let session = try connection(MongoLab.oneSeed, route: .sshProxy, proxy: Lab.httpProxy)
        try await session.connect()
        #expect(try await hello(session)["isWritablePrimary"] == .bool(true))
        #expect(session.route.requested.count == 3 && session.certificates.count == 3)
        await session.close()
    }

    @Test(arguments: [Lab.httpProxy, Lab.digestProxy, Lab.socksProxy])
    func replicaSetThroughEachProxy(_ proxy: Lab.Proxy) async throws {
        let session = try connection(MongoLab.oneSeed, route: .proxy, proxy: proxy)
        try await session.connect()
        #expect(try await hello(session)["isWritablePrimary"] == .bool(true))
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
        for name in ["mongo-rs2", "localhost", "127.0.0.1"] {
            #expect(!TLSCheck(host: name, options: MongoLab.tls).verify([certificate.data]), "\(name)")
        }
        #expect(TLSCheck(host: "mongo-rs1", options: MongoLab.tls).verify([certificate.data]))
    }

    /// A member that takes connections and never answers (paused): what it costs a connect, and Cancel during it.
    @Test func deadMemberCostAndCancel() async throws {
        try MongoLab.compose(["pause", "mongo-rs3"])
        defer { try? MongoLab.compose(["unpause", "mongo-rs3"]) }
        let started = Date()
        let session = try connection(MongoLab.allSeeds + "&connectTimeoutMS=2000", route: .proxy)
        try await session.connect()
        #expect(Date().timeIntervalSince(started) < 5)
        await session.close()
        // Cancel: the route closes under the driver, which then gives up at once.
        for route in [Route.proxy, .ssh] {
            let session = try connection(MongoLab.allSeeds + "&connectTimeoutMS=20000", route: route)
            let started = Date()
            let connecting = Task { try await session.connect() }
            try await Task.sleep(nanoseconds: 3_000_000_000)
            session.route.close()
            await #expect(throws: (any Error).self) { try await connecting.value }
            #expect(Date().timeIntervalSince(started) < 6)
            await session.close()
        }
    }

    /// A running find ended by Cancel (killOp on its member, from a side session), and by maxTimeMS.
    @Test func cancelAndTimeLimit() async throws {
        for connection in try both() {
            try await connection.connect()
            let data = try await connection.session(.data)
            let slow = MongoFind(filter: document(["$where": .string("sleep(20) || true")]))
            let started = Date()
            let running = Task { try await data.find(database: "fixture", collection: "many", slow).next() }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await data.cancel()
            await #expect { _ = try await running.value } throws: { ($0 as? AirSQLError)?.kind == .cancelled }
            #expect(Date().timeIntervalSince(started) < 5)

            var capped = slow
            capped.maxTimeMS = 300
            await #expect { _ = try await data.find(database: "fixture", collection: "many", capped).next() } throws: {
                ($0 as? AirSQLError)?.kind == .timeout && ($0 as? AirSQLError)?.code == 50
            }
            // The session goes on.
            #expect(try await data.count(database: "fixture", collection: "many", filter: document(["n": .document(document(["$lt": .int32(10)]))])) == 10)
            await connection.close()
        }
    }

    /// Cancel works for a login that may only read (the one AirSQL recommends for agents): it finds its own operation.
    @Test func cancelWorksForALoginThatOnlyReads() async throws {
        let connection = try connection(Self.solo, route: .direct, login: Lab.Login(user: "reader", password: "reader-pass"))
        try await connection.connect()
        let data = try await connection.session(.data)
        let slow = MongoFind(filter: document(["$where": .string("sleep(20) || true")]))
        let started = Date()
        let running = Task { try await data.find(database: "fixture", collection: "many", slow).next() }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await data.cancel()
        await #expect { _ = try await running.value } throws: { ($0 as? AirSQLError)?.kind == .cancelled }
        #expect(Date().timeIntervalSince(started) < 5)
        await connection.close()
    }

    /// Batches stop at a count or at a size, whichever comes first, and the cursor reads on with getMore.
    @Test func findReadsInBatchesBoundedByCountAndBytes() async throws {
        let connection = try connection(Self.solo, route: .direct)
        try await connection.connect()
        let data = try await connection.session(.data)
        let cursor = try await data.find(database: "fixture", collection: "many", MongoFind(sort: document(["_id": .int32(1)])))
        let small = try await cursor.next(maxCount: 500, maxBytes: 1000)
        let size = small[0].count
        #expect(small.count == (1000 + size - 1) / size, "\(small.count) of \(size) bytes")
        let more = try await cursor.next(maxCount: 300)
        #expect(more.count == 300)
        var total = small.count + more.count, last = BSONValue.null
        while !cursor.isExhausted {
            let batch = try await cursor.next(maxCount: 250)
            total += batch.count
            if let end = batch.last { last = try BSONDocument(bytes: end)["_id"]! }
        }
        #expect(total == 1000 && last == .int32(999))
        #expect(try await cursor.next().isEmpty)

        // The query bar's options.
        let query = MongoFind(filter: document(["n": .document(document(["$gte": .int32(10)]))]), projection: document(["n": .int32(1)]),
                              sort: document(["n": .int32(-1)]), skip: 2, limit: 3, hint: .string("_id_"), maxTimeMS: 5000)
        let found = try await data.find(database: "fixture", collection: "many", query).next().map { try BSONDocument(bytes: $0) }
        #expect(found.map { $0["n"] } == [.int32(997), .int32(996), .int32(995)])
        // The collection's case-insensitive collation, and the simple one Apply overrides it with.
        let alice = document(["name": .string("alice")])
        #expect(try await data.count(database: "fixture", collection: "names_ci", filter: alice) == 2)
        let simple = try await data.find(database: "fixture", collection: "names_ci",
                                         MongoFind(filter: alice, collation: document(["locale": .string("simple")]))).next()
        #expect(simple.count == 1)
        #expect(try await data.distinct(database: "fixture", collection: "all_types", key: "type").count == 19)
        await connection.close()
    }

    /// Every BSON type of the lab's fixture goes in and comes back exactly (insert then find, typeExact).
    @Test func everyBSONTypeRoundTrips() async throws {
        for connection in try both() {
            try await connection.connect()
            let data = try await connection.session(.data)
            let fixture = try await data.find(database: "fixture", collection: "all_types").next().map { try BSONDocument(bytes: $0) }
            #expect(fixture.count == 19)
            _ = try? await data.command(document(["drop": .string("types")]), database: MongoLab.scratch)
            #expect(try await data.insertMany(database: MongoLab.scratch, collection: "types", fixture) == 19)
            let back = try await data.find(database: MongoLab.scratch, collection: "types", MongoFind(sort: document(["_id": .int32(1)])))
                .next().map { try BSONDocument(bytes: $0) }
            let sorted = fixture.sorted { ($0["_id"]?.integer ?? 0) < ($1["_id"]?.integer ?? 0) }
            #expect(back.count == 19)
            for (a, b) in zip(sorted, back) { #expect(a.typeExactEqual(b), "\(a.shellForm())") }
            _ = try await data.command(document(["dropDatabase": .int32(1)]), database: MongoLab.scratch)
            await connection.close()
        }
    }

    /// Writes, listings, indexes, sizes and explain on both kinds of server.
    @Test func writesListingsIndexesAndExplain() async throws {
        for connection in try both() {
            try await connection.connect()
            let main = try await connection.session(.main)
            let data = try await connection.session(.data)
            try await data.insertOne(database: MongoLab.scratch, collection: "things", document(["_id": .int32(1), "n": .int32(1)]))
            await #expect { try await data.insertOne(database: MongoLab.scratch, collection: "things", document(["_id": .int32(1)])) } throws: {
                ($0 as? AirSQLError)?.kind == .duplicate
            }
            let changed = try await data.updateOne(database: MongoLab.scratch, collection: "things",
                                                   filter: document(["_id": .int32(1), "n": .int32(1)]),
                                                   update: document(["$set": .document(document(["n": .int64(2)]))]),
                                                   collation: document(["locale": .string("simple")]))
            #expect(changed.matched == 1 && changed.modified == 1)
            // The old value no longer matches: Apply sees 0 and says the document changed.
            let stale = try await data.updateOne(database: MongoLab.scratch, collection: "things",
                                                 filter: document(["_id": .int32(1), "n": .int32(1)]),
                                                 update: document(["$set": .document(document(["n": .int32(3)]))]))
            #expect(stale.matched == 0)

            try await main.createIndex(database: MongoLab.scratch, collection: "things", keys: document(["n": .int32(-1)]))
            #expect(try await main.listIndexes(database: MongoLab.scratch, collection: "things").compactMap { $0["name"] }
                    == [.string("_id_"), .string("n_-1")])
            try await main.dropIndex(database: MongoLab.scratch, collection: "things", name: "n_-1")
            #expect(try await main.listIndexes(database: MongoLab.scratch, collection: "things").count == 1)
            #expect(try await data.deleteOne(database: MongoLab.scratch, collection: "things", filter: document(["_id": .int32(1)])) == 1)

            let databases = try await main.listDatabases().compactMap { $0["name"] }
            #expect(databases.contains(.string("fixture")) && databases.contains(.string(MongoLab.scratch)))
            let collections = try await main.listCollections(database: "fixture")
            #expect(collections.first { $0.name == "all_types_names" }?.kind == .view)
            #expect(collections.first { $0.name == "readings" }?.kind == .timeseries)
            #expect(collections.first { $0.name == "names_ci" }?.options["collation"] != nil)
            let stats = try await main.collectionStats(database: "fixture", collection: "many")
            #expect(stats["count"]?.integer == 1000 && (stats["size"]?.integer ?? 0) > 0)
            #expect((try await main.databaseStats(database: "fixture")["collections"]?.integer ?? 0) >= 4)

            let plan = try await main.explain(database: "fixture", collection: "many",
                                              MongoFind(filter: document(["n": .document(document(["$gt": .int32(990)]))])))
            guard case .document(let stats2)? = plan["executionStats"], case .document(let planner)? = plan["queryPlanner"] else {
                Issue.record("\(plan.shellForm())"); return
            }
            #expect(stats2["nReturned"]?.integer == 9 && planner["winningPlan"] != nil)
            let aggregated = try await main.explain(database: "fixture", collection: "many",
                                                    pipeline: [document(["$match": .document(document(["n": .int32(5)]))])])
            #expect(aggregated["ok"]?.integer == 1)
            _ = try await data.command(document(["dropDatabase": .int32(1)]), database: MongoLab.scratch)
            await connection.close()
        }
    }

    /// Transactions on the replica set: commit keeps, abort drops; a standalone says it has none. Agents' guard: the
    /// server refuses $out and $merge inside one.
    @Test func transactions() async throws {
        let set = try connection(MongoLab.allSeeds, route: .proxy)
        try await set.connect()
        let data = try await set.session(.data)
        _ = try? await data.command(document(["drop": .string("tx")]), database: MongoLab.scratch)
        _ = try await data.command(document(["create": .string("tx")]), database: MongoLab.scratch)
        for commit in [true, false] {
            try await data.startTransaction()
            #expect(data.inTransaction)
            try await data.insertOne(database: MongoLab.scratch, collection: "tx", document(["kept": .bool(commit)]))
            // Inside it, the transaction sees its own write.
            #expect(try await data.count(database: MongoLab.scratch, collection: "tx", filter: document(["kept": .bool(commit)])) == 1)
            if commit { try await data.commitTransaction() } else { try await data.abortTransaction() }
            #expect(!data.inTransaction)
        }
        #expect(try await data.count(database: MongoLab.scratch, collection: "tx") == 1)

        for stage in [document(["$out": .document(document(["db": .string(MongoLab.scratch), "coll": .string("out")]))]),
                      document(["$merge": .document(document(["into": .document(document(["db": .string(MongoLab.scratch), "coll": .string("merge")]))]))])] {
            try await data.startTransaction()
            await #expect { _ = try await data.aggregate(database: "fixture", collection: "all_types", pipeline: [stage]).next() } throws: {
                ($0 as? AirSQLError)?.code == 263
            }
            try await data.abortTransaction()
        }
        _ = try await data.command(document(["dropDatabase": .int32(1)]), database: MongoLab.scratch)
        await set.close()

        let solo = try connection(Self.solo, route: .direct)
        try await solo.connect()
        let alone = try await solo.session(.data)
        await #expect {
            try await alone.startTransaction()
            try await alone.insertOne(database: MongoLab.scratch, collection: "tx", document([:]))
        } throws: {
            ($0 as? AirSQLError)?.message.contains("replica set") == true
        }
        try await alone.abortTransaction()
        await solo.close()
    }

    /// The command log: every command, its tag, and no login.
    @Test func commandsAreLogged() async throws {
        let file = URL(fileURLWithPath: TestEnvironment.root).appendingPathComponent("mongo-\(UUID().uuidString).log")
        let connection = try connection(Self.solo, route: .direct, log: SQLLog(fileURL: file))
        try await connection.connect()
        _ = try await connection.session(.data).find(database: "fixture", collection: "many", MongoFind(limit: 1)).next()
        await connection.close()
        let log = try String(contentsOf: file, encoding: .utf8)
        #expect(log.contains("[Mongo lab main:1] admin: { ping: 1, comment: \"airsql:main:"), "\(log)")
        #expect(log.contains("[Mongo lab data:2] fixture: { find: \"many\", filter: {}, limit: NumberLong(1), comment: \"airsql:data:"), "\(log)")
        #expect(log.contains("-- connected: MongoDB 7.0") && !log.contains(MongoLab.airsql.password))
    }

    /// The primary steps down; the same session writes to the new one (retryable writes), no reconnect by hand.
    @Test func failoverIsFollowed() async throws {
        let connection = try connection(MongoLab.allSeeds, route: .proxy)
        let before = try #require(try await connection.connect().primary)
        let data = try await connection.session(.data)
        try await data.insertOne(database: MongoLab.scratch, collection: "failover", document(["at": .string("before")]))
        _ = try? await connection.session(.main).command(document(["replSetStepDown": .int32(30), "secondaryCatchUpPeriodSecs": .int32(5)]),
                                                         database: "admin")
        let started = Date()
        while true {
            do {
                try await data.insertOne(database: MongoLab.scratch, collection: "failover", document(["at": .string("after")]))
                break
            } catch {
                guard Date().timeIntervalSince(started) < 60 else { throw error }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        guard case .string(let after)? = try await hello(connection)["primary"] else { Issue.record("no primary"); return }
        #expect(after != before)
        _ = try await data.command(document(["dropDatabase": .int32(1)]), database: MongoLab.scratch)
        await connection.close()
    }

    /// mongodb+srv: the SRV lookup happens on this Mac (a public record of MongoDB's driver tests, which names
    /// localhost.test.build.10gen.cc:27017), and the host it gives still goes through the route.
    @Test func srvHostsGoThroughTheRoute() async throws {
        let session = try connection("mongodb+srv://test3.test.build.10gen.cc/?tls=false&connectTimeoutMS=2000", route: .proxy)
        await #expect(throws: (any Error).self) { try await session.connect() }
        #expect(session.route.requested == ["localhost.test.build.10gen.cc:27017"], "\(session.route.requested)")
        await session.close()
    }
}

// MARK: The app

extension AppTests {
    /// Connect from the app: the standalone straight, and the replica set from its pasted connection string through a
    /// SOCKS proxy, the lab CA in the TLS tab; then Disconnect closes it.
    @Test(.enabled(if: MongoLab.enabled)) func aMongoDBConnectionConnectsAndDisconnects() async throws {
        var solo = SavedConnection(name: "Mongo solo", host: "127.0.0.1", port: MongoLab.soloPort, user: MongoLab.airsql.user)
        solo.engine = .mongodb
        solo.tls.mode = .off
        var set = SavedConnection(name: "Mongo set", route: .proxy)
        set.engine = .mongodb
        let password = set.apply(try MongoURI("mongodb://airsql:airsql-pass@" + MongoLab.allSeeds.dropFirst(10)))
        set.tls.caFile = Lab.caFile
        set.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: Lab.socksProxy.port, user: Lab.socksProxy.user)
        let model = testModel([solo, set])
        model.setSavedPassword(solo.id.uuidString, MongoLab.airsql.password)
        model.setSavedPassword(set.id.uuidString, password ?? "")
        model.setSavedPassword(set.proxySecretKey, Lab.socksProxy.password)
        let (_, harness) = appWindow(model)
        for (saved, summary) in [(solo, "standalone"), (set, "replica set rs0")] {
            _ = await call(harness, "select", ["pane": "sidebar", "names": [saved.name]])
            #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
            #expect(await eventually(timeout: 30) { model.openMongo[saved.id] != nil }, "\(String(describing: model.states[saved.id]))")
            guard case .connected(let server)? = model.states[saved.id] else { continue }
            #expect(server.hasPrefix("MongoDB 7.0") && server.hasSuffix(summary), "\(server)")
            let open = try #require(model.openMongo[saved.id])
            #expect(try await open.connection.session(.data).estimatedCount(database: "fixture", collection: "many") == 1000)
            #expect(model.open[saved.id] == nil && model.activity.isIdle)
            #expect(await call(harness, "menu", ["path": "Connection > Disconnect"]).error == nil)
            #expect(await eventually(timeout: 10) { model.openMongo[saved.id] == nil && model.states[saved.id] == nil })
            #expect(await eventually(timeout: 10) { await (try? open.connection.session(.main)) == nil }, "its sessions are closed")
        }
    }
}
