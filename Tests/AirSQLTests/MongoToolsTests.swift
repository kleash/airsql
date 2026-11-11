// mongodump and mongorestore (mongo-plan, Phase 4: lane dump): the command line, its TLS refusals and the password
// file; against the Mongo lab (AIRSQL_MONGO_LAB=1), a dump and a restore into another database on the standalone and on
// the replica set over SSH.
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

struct MongoToolsTests {
    private func saved(route: Route = .direct, tls: TLSOptions = TLSOptions(mode: .off)) -> SavedConnection {
        var saved = SavedConnection(name: "Shop", host: "db1.example.internal", port: 27018, user: "ana", route: route)
        saved.engine = .mongodb
        saved.mongoHosts = ["db2.example.internal:27018"]
        saved.replicaSet = "rs0"
        saved.database = "shop"
        saved.tls = tls
        return saved
    }

    /// The user on the command line, the password only in the file named by --config; no database in the string, the
    /// login's database said; over a route the socket with directConnection.
    @Test func theCommandLineHasTheUserAndThePasswordFileOnly() throws {
        let scope = MongoToolCommand.dumpScope(database: "shop", collection: "orders")
        #expect(scope == ["--db=shop", "--collection=orders", "--archive", "--gzip"])
        var command = MongoToolCommand(program: "/opt/homebrew/bin/mongodump", saved: saved(), socket: nil, scope: scope)
        let argv = try command.argv(config: "/private/p.yaml")
        #expect(argv[0] == "/opt/homebrew/bin/mongodump" && Array(argv[2...]) == ["--username=ana", "--config=/private/p.yaml"] + scope)
        let uri = try MongoURI(String(argv[1].dropFirst("--uri=".count)))
        #expect(uri.hosts == ["db1.example.internal:27018", "db2.example.internal:27018"] && uri.database.isEmpty)
        #expect(uri.option("authSource") == "admin" && uri.option("replicaSet") == "rs0" && uri.option("connectTimeoutMS") == nil)
        #expect(uri.user == nil && uri.password == nil)
        #expect(command.display(password: true).contains("--config=‹private temporary file›"))
        #expect(!command.display(password: false).contains("--config"))

        command.socket = "/Users/x/Library/Application Support/AirSQL/Routes/abc-s0.sock"
        command.saved.route = .ssh
        let routed = try MongoURI(String(try command.argv(config: nil)[1].dropFirst("--uri=".count)))
        #expect(routed.hosts == ["%2FUsers%2Fx%2FLibrary%2FApplication%20Support%2FAirSQL%2FRoutes%2Fabc-s0.sock"])
        #expect(routed.option("directConnection") == "true" && routed.option("replicaSet") == nil)
        // A typed Auth source stays; X.509's login has none.
        command.saved.authSource = "users"
        #expect(try MongoURI(String(try command.argv(config: nil)[1].dropFirst(6))).option("authSource") == "users")
        command.saved.mongoX509 = true
        command.saved.authSource = ""
        #expect(try MongoURI(String(try command.argv(config: nil)[1].dropFirst(6))).option("authSource") == nil)
    }

    /// The tools know only --tlsInsecure: a route's socket, Verify CA and a pinned certificate are refused unless the
    /// person ticks the box; Required runs as the connection does; Verify Identity on Direct checks, with the CA file.
    @Test func certificatesTheToolsCantCheckNeedTheTickBox() throws {
        func run(_ tls: TLSOptions, route: Route = .direct, unchecked: Bool = false) throws -> [String] {
            var command = MongoToolCommand(program: "mongodump", saved: saved(route: route, tls: tls),
                                           socket: route == .direct ? nil : "/s.sock", scope: [])
            command.unchecked = unchecked
            return Array(try command.argv(config: nil).dropFirst(3))
        }
        #expect(try run(TLSOptions(mode: .off)) == [])
        #expect(try run(TLSOptions(mode: .required)) == ["--tlsInsecure"])
        #expect(try run(TLSOptions(mode: .verifyIdentity, caFile: "/ca.pem")) == ["--tlsCAFile=/ca.pem"])
        #expect(try run(TLSOptions(mode: .verifyIdentity)) == [])
        var pinned = TLSOptions(mode: .verifyIdentity)
        pinned.pinnedFingerprint = "AB:CD"
        var pinnedWithCA = TLSOptions(mode: .verifyIdentity, caFile: "/ca.pem")
        pinnedWithCA.pinnedFingerprint = "AB:CD"
        #expect(try run(pinnedWithCA) == ["--tlsCAFile=/ca.pem"])
        var requiredPin = TLSOptions(mode: .required)
        requiredPin.pinnedFingerprint = "AB:CD"
        for (tls, route, words) in [(TLSOptions(mode: .verifyIdentity, caFile: "/ca.pem"), Route.ssh, "socket on this Mac"),
                                    (TLSOptions(mode: .verifyCA, caFile: "/ca.pem"), .direct, "Verify CA"),
                                    (pinned, .direct, "you trusted"), (requiredPin, .direct, "you trusted")] {
            #expect { try run(tls, route: route) } throws: {
                ($0 as? AirSQLError)?.kind == .tls && ($0 as? AirSQLError)?.message.contains(words) == true
            }
            #expect(try run(tls, route: route, unchecked: true) == ["--tlsInsecure"])
        }
        // A client certificate goes as the tools take it.
        #expect(try run(TLSOptions(mode: .verifyIdentity, caFile: "/ca.pem", certFile: "/me.pem"))
                == ["--tlsCAFile=/ca.pem", "--tlsCertificateKeyFile=/me.pem"])
    }

    @Test func restoreRenamesOneDatabaseOfTheFileTakenLiterally() {
        #expect(MongoToolCommand.restoreScope(rename: nil, drop: false, gzip: true) == ["--archive", "--gzip"])
        #expect(MongoToolCommand.restoreScope(rename: ("shop", "shop_copy"), drop: true, gzip: false)
                == ["--archive", "--nsInclude=shop.*", "--nsFrom=shop.*", "--nsTo=shop_copy.*", "--drop"])
        #expect(MongoToolCommand.pattern(#"a*b\c$d"#) == #"a\*b\\c\$d"#)
        #expect(MongoToolCommand.database(inFileName: "shop-2026-11-11-1407.archive.gz") == "shop")
        #expect(MongoToolCommand.database(inFileName: "shop.orders-2026-11-11-1407.archive.gz") == "shop")
        #expect(MongoToolCommand.database(inFileName: "my-db.archive") == "my-db")
        #expect(MongoToolCommand.database(inFileName: "backup.gz") == "backup")
    }

    /// The password file is private and YAML reads the password back exactly.
    @Test func thePasswordFileIsPrivateAndHoldsThePasswordOnly() throws {
        let url = try MongoToolCommand.configFile("p\"a#s s\\w:d\n")
        defer { unlink(url.path) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "password: \"p\\\"a#s s\\\\w:d\\n\"\n")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600 && url.pathExtension == "yaml")
    }

    @Test func theToolsAreFoundInTheToolsFolders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-mongotools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(MongoToolCommand.find(.dump, folders: [folder.path]) == nil)
        let tool = folder.appendingPathComponent("mongorestore")
        #expect(FileManager.default.createFile(atPath: tool.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]))
        #expect(MongoToolCommand.find(.restore, folders: ["/nowhere", folder.path]) == tool.path)
        #expect(MongoToolCommand.find(.dump, folders: [folder.path]) == nil)
    }
}

/// A dump of fixture restored into another database, compared by counts and the BSON of every type, then dropped: on the
/// standalone (Direct) and on the replica set over SSH, whose TLS the tools can't check through the socket.
@Suite(.serialized, .enabled(if: MongoLab.enabled && MongoToolCommand.find(.dump) != nil && MongoToolCommand.find(.restore) != nil,
                             "Mongo lab and mongodump: AIRSQL_MONGO_LAB=1 ./test.sh --filter MongoTools"))
struct MongoToolsLabTests {
    private let copy = "lane_mongo_dump_copy"

    private func roundTrip(_ saved: SavedConnection, connection: MongoConnection, socket: String?, unchecked: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-dump-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture-2026-11-11-1407.archive.gz")
        let password = MongoLab.airsql.password

        var dump = MongoToolCommand(program: MongoToolCommand.find(.dump)!, saved: saved, socket: socket,
                                    scope: MongoToolCommand.dumpScope(database: "fixture", collection: nil))
        dump.unchecked = unchecked
        let bytes = try await dump.dump(password: password, to: file, cancellation: Cancellation()) { _ in }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64
        #expect(bytes > 1000 && size == bytes)
        // Nothing but the dump is left in the folder, and no password file.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [file.lastPathComponent])
        #expect(passwordFiles().isEmpty)

        // A wrong password fails and leaves no file: the password file is what logs in.
        let failed = folder.appendingPathComponent("wrong.archive.gz")
        await #expect(throws: AirSQLError.self) { _ = try await dump.dump(password: "wrong", to: failed, cancellation: Cancellation()) { _ in } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [file.lastPathComponent])

        let session = try await connection.session(.main)
        _ = try await session.command(BSONDocument([("dropDatabase", .int32(1))]), database: copy)
        var restore = MongoToolCommand(program: MongoToolCommand.find(.restore)!, saved: saved, socket: socket,
                                       scope: MongoToolCommand.restoreScope(rename: (MongoToolCommand.database(inFileName: file.lastPathComponent), copy),
                                                                            drop: false, gzip: true))
        restore.unchecked = unchecked
        var read: Int64 = 0
        let said = try await restore.restore(password: password, from: file, cancellation: Cancellation()) { read = $0 }
        #expect(read == bytes && said?.hasSuffix("0 document(s) failed to restore.") == true, "\(said ?? "")")
        #expect(passwordFiles().isEmpty)

        // Every collection with its count; every BSON type the same, byte for byte.
        let collections = try await session.listCollections(database: "fixture").filter { $0.kind == .collection && !$0.name.hasPrefix("system.") }.map(\.name)
        #expect(collections.contains("all_types"))
        for name in collections {
            let (from, to) = (try await session.estimatedCount(database: "fixture", collection: name),
                              try await session.estimatedCount(database: copy, collection: name))
            #expect(from == to, "\(name): \(from) vs \(to)")
        }
        let sorted = MongoFind(sort: BSONDocument([("_id", .int32(1))]))
        let original = try await session.all(try await session.find(database: "fixture", collection: "all_types", sorted))
        let restored = try await session.all(try await session.find(database: copy, collection: "all_types", sorted))
        #expect(original.count == 19 && original == restored)
        #expect(try original.map { try $0.bytes() } == restored.map { try $0.bytes() })

        // Again with --drop: each collection replaced, not doubled.
        restore.scope = MongoToolCommand.restoreScope(rename: ("fixture", copy), drop: true, gzip: true)
        _ = try await restore.restore(password: password, from: file, cancellation: Cancellation()) { _ in }
        #expect(try await session.estimatedCount(database: copy, collection: "all_types") == 19)

        // One collection, restored without --drop where its documents are: every _id is there, so nothing is inserted.
        dump.scope = MongoToolCommand.dumpScope(database: "fixture", collection: "all_types")
        let one = folder.appendingPathComponent("fixture.all_types.archive.gz")
        _ = try await dump.dump(password: password, to: one, cancellation: Cancellation()) { _ in }
        restore.scope = MongoToolCommand.restoreScope(rename: ("fixture", copy), drop: false, gzip: true)
        let again = try await restore.restore(password: password, from: one, cancellation: Cancellation()) { _ in }
        #expect(again == "0 document(s) restored successfully. 19 document(s) failed to restore.", "\(again ?? "")")
        #expect(try await session.estimatedCount(database: copy, collection: "all_types") == 19)
        _ = try await session.command(BSONDocument([("dropDatabase", .int32(1))]), database: copy)
    }

    /// This process's password files left in the tools' private folder.
    private func passwordFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: OptionFile.folder.path)) ?? [])
            .filter { $0.hasPrefix("\(getpid())-") && $0.hasSuffix(".yaml") }
    }

    @Test func standaloneDirect() async throws {
        var saved = SavedConnection(name: "Mongo solo", host: "127.0.0.1", port: MongoLab.soloPort, user: MongoLab.airsql.user, route: .direct)
        saved.engine = .mongodb
        saved.tls = TLSOptions(mode: .off)
        let connection = MongoConnection(uri: saved.mongoURI.string, user: saved.user, password: MongoLab.airsql.password,
                                         route: MongoRoute(saved), name: saved.name)
        try await connection.connect()
        defer { Task { await connection.close() } }
        try await roundTrip(saved, connection: connection, socket: nil, unchecked: false)
    }

    @Test func replicaSetOverSSH() async throws {
        var saved = SavedConnection(name: "Mongo rs", host: MongoLab.members[0], port: 27017, user: MongoLab.airsql.user, route: .ssh)
        saved.engine = .mongodb
        saved.replicaSet = "rs0"
        saved.tls = MongoLab.tls
        saved.sshHost = SSHHop(host: Lab.bastion.host, port: Lab.bastion.port, user: Lab.bastion.user, login: .keyFile, keyFile: Lab.key)
        let connection = MongoConnection(uri: MongoLab.oneSeed, user: saved.user, password: MongoLab.airsql.password, tls: MongoLab.tls,
                                         route: MongoRoute(saved, askpass: try RouteTesting.askpass(for: saved.id)), name: saved.name)
        let server = try await connection.connect()
        defer { Task { await connection.close() } }
        let socket = try #require(try MongoShell.socket(connection.route, saved: saved, primary: server.primary))
        // Through the socket the tools can't check the server's name: refused unless ticked.
        let refused = MongoToolCommand(program: "mongodump", saved: saved, socket: socket, scope: [])
        #expect(refused.tlsProblem != nil)
        #expect(throws: AirSQLError.self) { try refused.argv(config: nil) }
        try await roundTrip(saved, connection: connection, socket: socket, unchecked: true)
    }
}

extension AppTests {
    /// The tree's menus have Dump (and a database's Restore); Restore is refused on a read-only connection and both for
    /// agents; a dump of one collection from its sheet, then its restore under another name after the confirmation.
    @Test(.enabled(if: MongoLab.enabled && MongoToolCommand.find(.dump) != nil && MongoToolCommand.find(.restore) != nil))
    func aCollectionIsDumpedAndRestoredUnderAnotherNameFromTheSheets() async throws {
        let (main, _, mongo) = try await mongoWindow()
        let id = mongo.saved.id, copy = "lane_mongo_dump_ui"
        let fixture = try await open(MongoTreeItem(database: "fixture"), in: main, mongo)
        let titles = main.sidebar.treeMenu([fixture]).items.map(\.title)
        #expect(titles.contains(Commands.mongoDump.title) && titles.contains(Commands.mongoRestore.title))
        let row = SidebarNode.Kind.mongo(id, MongoTreeItem(database: "fixture", collection: "all_types"))
        let collection = try #require(main.sidebar.treeNodes[row])
        let collectionTitles = main.sidebar.treeMenu([collection]).items.map(\.title)
        #expect(collectionTitles.contains(Commands.mongoDump.title) && !collectionTitles.contains(Commands.mongoRestore.title))
        let connectionMenu = try #require({ () -> NSMenu? in
            main.sidebar.outline.deselectAll(nil)
            _ = main.sidebar.reveal(.connection(id))
            return main.sidebar.contextMenu()
        }())
        #expect(connectionMenu.items.contains { $0.action == Commands.mongoRestore.action && $0.target === MongoDumpMenu.shared })
        #expect(!connectionMenu.items.contains { $0.action == Commands.restore.action })

        #expect(main.sidebar.reveal(row))
        main.window?.makeFirstResponder(main.sidebar.outline)
        let menu = MongoDumpMenu.shared
        #expect(menu.target(in: main)?.collection == "all_types")
        #expect(menu.refusal(Commands.mongoRestore.action, in: main) == nil)
        let index = try #require(main.model.data.connections.firstIndex { $0.id == id })
        main.model.data.connections[index].readOnly = true
        #expect(menu.refusal(Commands.mongoRestore.action, in: main)?.contains("read-only") == true)
        #expect(menu.refusal(Commands.mongoDump.action, in: main) == nil)
        main.model.data.connections[index].readOnly = false
        // Agents: refused before anything is found or shown.
        AgentGate.$agent.withValue("test agent") { menu.dumpMongo(nil) }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!ToolSheet.open.contains { $0 is MongoDumpSheet })

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-dump-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        menu.dumpMongo(nil)
        #expect(await eventually(timeout: 10) { ToolSheet.open.contains { $0 is MongoDumpSheet } })
        let dump = try #require(ToolSheet.open.last as? MongoDumpSheet)
        let file = folder.appendingPathComponent("fixture.all_types-2026-11-11-1407.archive.gz")
        dump.use(file)
        let dumpView = try #require(dump.window?.contentView)
        let shown = try #require(descendants(of: dumpView).first { $0.accessibilityIdentifier() == "mongoDump.command" } as? NSTextView).string
        #expect(shown.contains("--db=fixture --collection=all_types --archive --gzip") && shown.contains("--username=airsql"))
        #expect(shown.contains("--config=‹private temporary file›") && !shown.contains(MongoLab.airsql.password))
        #expect(dump.runButton.isEnabled, "\(dump.runButton.toolTip ?? "")")
        dump.runButton.performClick(nil)
        #expect(await eventually(timeout: 30) { !dump.running && dump.status.stringValue.hasPrefix("Dumped fixture") }, "\(dump.status.stringValue)")
        #expect(FileManager.default.fileExists(atPath: file.path))
        dump.close()

        menu.restoreMongo(nil)
        #expect(await eventually(timeout: 10) { ToolSheet.open.contains { $0 is MongoDumpSheet } })
        let restore = try #require(ToolSheet.open.last as? MongoDumpSheet)
        #expect(!restore.runButton.isEnabled && restore.runButton.toolTip == "Choose the file to restore first")
        restore.use(file)
        let restoreView = try #require(restore.window?.contentView)
        let into = try #require(descendants(of: restoreView).first { $0.accessibilityIdentifier() == "mongoDump.into" } as? NSTextField)
        into.stringValue = copy
        restore.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(await eventually(timeout: 5) { restore.runButton.isEnabled })
        restore.runButton.performClick(nil)
        let alert = try #require(await eventually(timeout: 5) { restore.window?.attachedSheet != nil } ? restore.window?.attachedSheet : nil)
        let words = descendants(of: try #require(alert.contentView)).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
        #expect(words.contains("“fixture” of the file into “\(copy)”") && words.contains("--nsTo=\(copy).*") && words.contains("127.0.0.1:"))
        restore.window?.endSheet(alert, returnCode: .alertSecondButtonReturn)
        #expect(await eventually(timeout: 30) { !restore.running && restore.status.stringValue.hasPrefix("Restored") }, "\(restore.status.stringValue)")
        #expect(restore.status.stringValue.hasSuffix("19 document(s) restored successfully. 0 document(s) failed to restore."))
        let session = try await mongo.connection.session(.main)
        #expect(try await session.estimatedCount(database: copy, collection: "all_types") == 19)
        _ = try await session.command(BSONDocument([("dropDatabase", .int32(1))]), database: copy)
        restore.close()
        main.model.connector.disconnect(id)
    }
}

