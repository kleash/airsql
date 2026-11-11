// MongoDB users and roles (docs/dev/mongo-plan.md, Phase 4 "users"): the commands the sheets' fields give, the password
// shown as the command log has it, plain words for refusals, and the replies read; then, on the Mongo lab
// (AIRSQL_MONGO_LAB=1), a throwaway user made, granted, revoked, re-passworded, logged in with and dropped on the
// standalone and the replica set, a custom role dropped, the reader login's fallback and refusal, and the page itself.
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

private func doc(_ fields: KeyValuePairs<String, BSONValue>) -> BSONDocument { BSONDocument(fields.map { ($0.key, $0.value) }) }

struct MongoUsersTests {
    @Test func theSheetsFieldsGiveTheCommandsOrSayWhichIsWrong() throws {
        let create = try MongoUsers.createUser(database: " shop ", name: " ana ", password: "s3cret pass", repeated: "s3cret pass",
                                               role: "read", roleDatabase: "")
        #expect(create.database == "shop")
        #expect(create.command == doc(["createUser": .string("ana"), "pwd": .string("s3cret pass"),
                                       "roles": .array([.document(doc(["role": .string("read"), "db": .string("shop")]))])]))
        #expect(try MongoUsers.createUser(database: "admin", name: "x", password: "p", repeated: "p").command["roles"] == .array([]))
        #expect(try MongoUsers.createUser(database: "admin", name: "x", password: "p", repeated: "p", role: "readAnyDatabase",
                                          roleDatabase: "admin").command["roles"]
                == .array([.document(doc(["role": .string("readAnyDatabase"), "db": .string("admin")]))]))
        func problem(_ make: () throws -> MongoAdminCommand) -> String? {
            do { _ = try make(); return nil } catch { return "\(error)" }
        }
        #expect(problem { try MongoUsers.createUser(database: "admin", name: "x", password: "a", repeated: "b") }?.hasPrefix("Repeat:") == true)
        #expect(problem { try MongoUsers.createUser(database: "admin", name: "x", password: "", repeated: "") }?.hasPrefix("Password:") == true)
        #expect(problem { try MongoUsers.createUser(database: "admin", name: "  ", password: "p", repeated: "p") }?.hasPrefix("Name:") == true)
        #expect(problem { try MongoUsers.createUser(database: "my db", name: "x", password: "p", repeated: "p") }?.hasPrefix("Database:") == true)
        #expect(problem { try MongoUsers.createUser(database: "a", name: "x", password: "p", repeated: "p", role: "r", roleDatabase: "a.b") }?
            .hasPrefix("On Database:") == true)

        let ana = MongoAccount(name: "ana", database: "shop")
        #expect(try MongoUsers.changePassword(ana, password: "n", repeated: "n").command == doc(["updateUser": .string("ana"), "pwd": .string("n")]))
        #expect(problem { try MongoUsers.changePassword(ana, password: "n", repeated: "m") }?.hasPrefix("Repeat:") == true)
        let grant = try MongoUsers.grant(" readWrite ", on: "", to: ana)
        #expect(grant.database == "shop" && grant.command == doc(["grantRolesToUser": .string("ana"),
                                                                  "roles": .array([.document(doc(["role": .string("readWrite"), "db": .string("shop")]))])]))
        #expect(try MongoUsers.grant("read", on: "reports", to: ana).shellForm.contains("[ { role: \"read\", db: \"reports\" } ]"))
        #expect(problem { try MongoUsers.grant(" ", on: "", to: ana) }?.hasPrefix("Role:") == true)
        #expect(MongoUsers.revoke(MongoRoleName(role: "read", db: "reports"), from: ana).shellForm
                == "db.getSiblingDB(\"shop\").runCommand({ revokeRolesFromUser: \"ana\", roles: [ { role: \"read\", db: \"reports\" } ] })")
        #expect(MongoUsers.drop(ana).shellForm == "db.getSiblingDB(\"shop\").runCommand({ dropUser: \"ana\" })")
        #expect(MongoUsers.drop(MongoAccount(name: "auditor", database: "admin", isRole: true)).command == doc(["dropRole": .string("auditor")]))
    }

    /// The preview shows `pwd` as the command log has it; other commands show as they are.
    @Test func thePasswordIsRedactedInThePreviewAndTheCommandLog() throws {
        let create = try MongoUsers.createUser(database: "admin", name: "ana", password: "hunter2!", repeated: "hunter2!")
        let change = try MongoUsers.changePassword(MongoAccount(name: "ana", database: "admin"), password: "n3w-pass", repeated: "n3w-pass")
        for (command, secret) in [(create, "hunter2!"), (change, "n3w-pass")] {
            #expect(!command.shellForm.contains(secret) && command.shellForm.contains("pwd: \"<secret>\""), "\(command.shellForm)")
            #expect(command.shellForm.hasSuffix(MongoLog.line(command.command) + ")"), "the same redaction as the command log")
            #expect(!MongoLog.line(command.command).contains(secret))
        }
        #expect(create.command["pwd"] == .string("hunter2!"), "the server gets it")
        // A collection's rules may name a field password: they show whole.
        let rules = try MongoAdmin.setValidation(database: "shop", collection: "users",
                                                 validator: doc(["password": .document(doc(["$type": .string("string")]))]),
                                                 level: "strict", action: "error")
        #expect(rules.shellForm.contains("password: { $type: \"string\" }"))
    }

    @Test func refusalsAreInPlainWordsWithoutThePassword() {
        // As MongoErrorMapping gives the server's errors: its words, the server's text in details, the code.
        func server(_ code: Int, _ message: String) -> AirSQLError {
            AirSQLError(code == 13 ? .accessDenied : .other, code == 13 ? "This user lacks the privilege for that." : message,
                        details: "Error \(code): \(message)", code: code)
        }
        let atlas = server(8000, "user is not allowed to do action [createUser] on [admin.]")
        #expect(MongoUsers.failure(atlas).contains("Atlas's Database Access page"))
        let denied = server(13, "not authorized on fixture to execute command { createUser: \"p4x\", pwd: \"hunter2!\" }")
        let words = MongoUsers.failure(denied, hiding: "hunter2!")
        #expect(words.contains("userAdmin") && !words.contains("hunter2!"), "\(words)")
        // An error without words of its own shows the server's text, the password left out.
        let other = MongoUsers.failure(server(50687, "bad pwd hunter2! here"), hiding: "hunter2!")
        #expect(other.contains("bad pwd <secret> here") && !other.contains("hunter2!"), "\(other)")
        #expect(MongoUsers.failure(server(51003, "User \"ana@admin\" already exists")) == "A user of that name already exists in that database.")
        #expect(MongoUsers.failure(server(31, "Could not find role: nosuch@fixture")).hasPrefix("No role of that name"))
        #expect(MongoUsers.failure(server(2, "Cannot create users in the local database")).contains("Cannot create users in the local database"))
    }

    @Test func usersAndRolesAreReadFromTheirReplies() {
        let users = MongoUsers.accounts(doc(["users": .array([
            .document(doc(["_id": .string("admin.ana"), "user": .string("ana"), "db": .string("admin"),
                           "roles": .array([.document(doc(["role": .string("read"), "db": .string("shop")]))]),
                           "mechanisms": .array([.string("SCRAM-SHA-1"), .string("SCRAM-SHA-256")])])),
            .document(doc(["user": .string("broken")])),
        ])]), roles: false)
        #expect(users.count == 1 && users[0].key == "user:admin.ana" && users[0].roles == [MongoRoleName(role: "read", db: "shop")])
        #expect(users[0].mechanisms == ["SCRAM-SHA-1", "SCRAM-SHA-256"] && users[0].info["_id"] == .string("admin.ana"))
        let roles = MongoUsers.accounts(doc(["roles": .array([
            .document(doc(["role": .string("auditor"), "db": .string("shop"), "isBuiltin": .bool(false),
                           "roles": .array([.document(doc(["role": .string("read"), "db": .string("shop")]))]),
                           "privileges": .array([.document(doc([:])), .document(doc([:]))])])),
        ])]), roles: true)
        #expect(roles.count == 1 && roles[0].isRole && roles[0].privileges == 2 && roles[0].key == "role:shop.auditor")
        let me = MongoUsers.authenticated(doc(["authInfo": .document(doc(["authenticatedUsers": .array([
            .document(doc(["user": .string("reader"), "db": .string("admin")]))])]))]))
        #expect(me.count == 1 && me[0].user == "reader" && me[0].db == "admin")
    }

    @Test @MainActor func aReadOnlyProductionOrAgentsConnectionRefusesUsers() {
        var saved = SavedConnection(name: "m")
        saved.engine = .mongodb
        #expect(saved.usersRefusal == nil)
        #expect(AgentGate.$agent.withValue("an agent") { saved.usersRefusal }?.hasPrefix("Only the person at the Mac") == true)
        saved.colour = .production
        #expect(saved.usersRefusal?.contains("Production") == true)
        saved.colour = .none
        saved.readOnly = true
        #expect(saved.usersRefusal?.contains("read-only") == true)
    }
}

// MARK: The lab

@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter MongoUsers"))
struct MongoUsersLabTests {
    static let database = "lane_mongo_users"

    /// The standalone directly and the replica set through the SOCKS proxy (TLS), as `user`, logging to `log`.
    static func both(user: String = "airsql", password: String = "airsql-pass", log: SQLLog = .shared) -> [MongoConnection] {
        let solo = SavedConnection(name: "Mongo lab", host: "127.0.0.1", port: MongoLab.soloPort, user: user, route: .direct)
        var set = SavedConnection(name: "Mongo lab", host: MongoLab.members[0], port: 27017, user: user, route: .proxy)
        let proxy = Lab.socksProxy
        set.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: proxy.port, user: proxy.user)
        return [MongoConnection(uri: "mongodb://127.0.0.1:\(MongoLab.soloPort)/", user: user, password: password,
                                route: MongoRoute(solo), name: "Mongo lab", log: log),
                MongoConnection(uri: MongoLab.allSeeds, user: user, password: password, tls: MongoLab.tls,
                                route: MongoRoute(set, proxyPassword: proxy.password), name: "Mongo lab", log: log)]
    }

    @Test func rootMakesGrantsRevokesRepasswordsAndDropsAThrowawayUser() async throws {
        let file = URL(fileURLWithPath: TestEnvironment.root).appendingPathComponent("mongo-users-\(UUID().uuidString).log")
        let log = SQLLog(fileURL: file)
        for (index, connection) in Self.both(log: log).enumerated() {
            try await connection.connect()
            let session = try await connection.session(.data)
            let name = "p4test_" + UUID().uuidString.prefix(8).lowercased()
            let user = MongoAccount(name: name, database: "admin"), role = MongoAccount(name: name + "_role", database: Self.database, isRole: true)
            func found(_ key: String) async throws -> MongoAccount? {
                let read = try await session.usersAndRoles()
                #expect(read.problems.isEmpty, "\(read.problems)")
                return read.accounts.first { $0.key == key }
            }
            var failed: Error?
            do {
                try await session.run(MongoUsers.createUser(database: "admin", name: name, password: "first-pass1", repeated: "first-pass1",
                                                            role: "read", roleDatabase: "fixture"))
                let made = try #require(try await found(user.key))
                #expect(made.roles == [MongoRoleName(role: "read", db: "fixture")] && made.mechanisms.contains("SCRAM-SHA-256"))
                #expect(made.info["credentials"] == nil, "never showCredentials")
                // Made again: refused in plain words.
                do {
                    try await session.run(MongoUsers.createUser(database: "admin", name: name, password: "again-pass", repeated: "again-pass"))
                    Issue.record("a second createUser went through")
                } catch {
                    #expect(MongoUsers.failure(error, hiding: "again-pass") == "A user of that name already exists in that database.")
                }

                try await session.run(MongoUsers.grant("readWrite", on: Self.database, to: user))
                try await session.run(MongoUsers.revoke(MongoRoleName(role: "read", db: "fixture"), from: user))
                #expect(try await found(user.key)?.roles == [MongoRoleName(role: "readWrite", db: Self.database)])
                try await session.run(MongoUsers.changePassword(user, password: "second-pass2", repeated: "second-pass2"))

                // The new password logs in and may write where readWrite says; the old one no longer logs in.
                let (fresh, old) = (Self.both(user: name, password: "second-pass2")[index], Self.both(user: name, password: "first-pass1")[index])
                try await fresh.connect()
                try await fresh.session(.data).insertOne(database: Self.database, collection: "written", BSONDocument([("by", .string(name))]))
                await fresh.close()
                await #expect { try await old.connect() } throws: { ($0 as? AirSQLError)?.kind == .authFailed }
                await old.close()

                // A custom role: listed read-only with its privileges, and dropped.
                _ = try await session.command(BSONDocument([
                    ("createRole", .string(role.name)), ("roles", .array([])),
                    ("privileges", .array([.document(BSONDocument([
                        ("resource", .document(BSONDocument([("db", .string(Self.database)), ("collection", .string(""))]))),
                        ("actions", .array([.string("find")])),
                    ]))])),
                ]), database: Self.database)
                #expect(try await found(role.key)?.privileges == 1)
                try await session.run(MongoUsers.drop(role))
                #expect(try await found(role.key) == nil)

                try await session.run(MongoUsers.drop(user))
                #expect(try await found(user.key) == nil)
            } catch {
                failed = error
            }
            // Cleaned up even when something failed.
            _ = try? await session.run(MongoUsers.drop(user))
            _ = try? await session.run(MongoUsers.drop(role))
            _ = try? await session.run(MongoAdmin.dropDatabase(Self.database))
            await connection.close()
            if let failed { throw failed }
        }
        let logged = try String(contentsOf: file, encoding: .utf8)
        #expect(logged.contains("createUser: \"p4test_") && logged.contains("updateUser: \"p4test_") && logged.contains("pwd: \"<secret>\""))
        #expect(!logged.contains("first-pass1") && !logged.contains("second-pass2"), "\(logged)")
    }

    /// The reader login (read on fixture) sees only itself, says what it can't see, and the server refuses its writes.
    @Test func aLimitedLoginFallsBackAndIsRefusedInPlainWords() async throws {
        for connection in Self.both(user: "reader", password: "reader-pass") {
            try await connection.connect()
            let session = try await connection.session(.data)
            let read = try await session.usersAndRoles()
            #expect(read.accounts.map(\.key) == ["user:admin.reader"], "\(read.accounts.map(\.key))")
            #expect(read.problems.contains { $0.contains("viewUser") } && read.problems.contains { $0.contains("viewRole") }, "\(read.problems)")
            do {
                try await session.run(MongoUsers.createUser(database: "fixture", name: "p4test_no", password: "never-pass", repeated: "never-pass"))
                Issue.record("reader made a user")
            } catch {
                let words = MongoUsers.failure(error, hiding: "never-pass")
                #expect(words.hasPrefix("This login may not change users or roles there") && !words.contains("never-pass"), "\(words)")
            }
            await connection.close()
        }
    }
}

// MARK: The page

extension AppTests {
    @Test(.enabled(if: MongoLab.enabled)) func theMongoUsersPageMakesAUserThroughThePreviewAndRefusesWhenReadOnly() async throws {
        let (main, harness, mongo) = try await mongoWindow()
        let shown = await call(harness, "menu", ["path": "Connection > MongoDB Server > Users and Roles"])
        #expect(shown.error == nil, "\(shown.error ?? "")")
        let page = try #require(main.selectedTab?.shown as? MongoUsersContent)
        #expect(await eventually(timeout: 20) { page.reads > 0 && !page.isReading })
        #expect(page.list.rows.contains { $0.cells["name"] == "reader" && $0.cells["roles"] == "read on fixture" }, "\(page.list.caption.stringValue)")
        #expect(page.newButton.isEnabled && !page.passwordButton.isEnabled && page.passwordButton.toolTip == "Select one user first",
                "\(page.newButton.toolTip ?? "") \(page.list.caption.stringValue)")

        // New User…: the passwords must match; the preview shows <secret>; Run makes it.
        let name = "p4test_" + UUID().uuidString.prefix(8).lowercased()
        page.newMongoUser(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        for (id, value) in [("mongoUsers.name", name), ("mongoUsers.newPassword", "ui-pass-1"), ("mongoUsers.repeat", "ui-pass-2"),
                            ("mongoUsers.role", "read"), ("mongoUsers.roleDatabase", "fixture")] {
            #expect(await call(harness, "set", ["id": id, "value": value]).error == nil, "\(id)")
        }
        let sheet = try #require(main.window?.attachedSheet?.windowController as? MongoAdminSheet)
        #expect(await call(harness, "press", ["id": "mongoUsers.create.preview"]).error == nil)
        #expect(sheet.problem.stringValue.hasPrefix("Repeat:"))
        #expect(await call(harness, "set", ["id": "mongoUsers.repeat", "value": "ui-pass-1"]).error == nil)
        #expect(await call(harness, "press", ["id": "mongoUsers.create.preview"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        let preview = try #require(main.window?.attachedSheet?.windowController as? SQLPreviewSheet)
        let content = try #require(preview.window?.contentView)
        let text = try #require(find(NSTextView.self, id: "preview.sql", in: content)).string
        #expect(text.contains("createUser: \"\(name)\", pwd: \"<secret>\"") && !text.contains("ui-pass-1"), "\(text)")
        let words = Self.texts(in: content).joined(separator: " ")
        #expect(words.contains("neither TLS nor an SSH route"), "the standalone has no TLS: \(words)")
        #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(await eventually(timeout: 20) { page.list.rows.contains { $0.cells["name"] == name } })

        // Drop…: its name typed first.
        let row = try #require(page.list.rows.firstIndex { $0.cells["name"] == name })
        page.list.table.selectRowIndexes([row], byExtendingSelection: false)
        #expect(page.passwordButton.isEnabled && page.details.string.contains("user: \"\(name)\""))
        page.dropMongoAccount(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect(await call(harness, "set", ["id": "preview.confirm", "value": name]).error == nil)
        #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(await eventually(timeout: 20) { !page.list.rows.contains { $0.cells["name"] == name } })

        // Read-only: every write is off and says why.
        var saved = try #require(main.model.connection(mongo.saved.id))
        saved.readOnly = true
        main.model.save(saved)
        page.refresh(nil)
        #expect(await eventually(timeout: 20) { !page.isReading })
        #expect(!page.newButton.isEnabled && page.newButton.toolTip?.contains("read-only") == true)
        for command in Commands.mongoUsersCommands.dropFirst() {
            let item = command.item()
            #expect(!page.validateMenuItem(item) && item.toolTip?.contains("read-only") == true, "\(command.title)")
        }
        _ = try? await mongo.connection.session(.main).run(MongoUsers.drop(MongoAccount(name: name, database: "admin")))
    }
}
