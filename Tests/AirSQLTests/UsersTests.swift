import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

@Suite struct UsersCoreTests {
    static let privileges = UserSQL.privileges([
        ["Select", "Tables", "To retrieve rows"], ["Insert", "Tables", ""], ["Update", "Tables", ""], ["References", "Databases,Tables", ""],
        ["Create routine", "Databases", ""], ["Execute", "Functions,Procedures", ""], ["Event", "Server Admin", ""],
        ["Grant option", "Databases,Tables,Functions,Procedures", ""], ["Process", "Server Admin", ""], ["Proxy", "Server Admin", ""],
        ["Usage", "Server Admin", "No privileges"],
    ])
    let maria = UserSQL(mariaDB: true, noBackslashEscapes: false)
    let mysql = UserSQL(mariaDB: false, noBackslashEscapes: false)

    private func account(_ change: (inout ServerAccount) -> Void = { _ in }) -> ServerAccount {
        var account = ServerAccount(user: "bob", host: "%")
        change(&account)
        return account
    }

    @Test func eachLevelOffersWhatTheServerFilesThere() {
        #expect(GrantLevel.global.offered(Self.privileges).contains("PROCESS"))
        #expect(!GrantLevel.global.offered(Self.privileges).contains("USAGE") && !GrantLevel.global.offered(Self.privileges).contains("PROXY"))
        let database = GrantLevel.database("shop").offered(Self.privileges)
        #expect(database.contains("EVENT") && database.contains("CREATE ROUTINE") && database.contains("EXECUTE") && !database.contains("PROCESS"))
        #expect(GrantLevel.table("shop", "t").offered(Self.privileges) == ["GRANT OPTION", "INSERT", "REFERENCES", "SELECT", "UPDATE"])
        #expect(GrantLevel.routine("shop", "p", isFunction: false).offered(Self.privileges) == ["EXECUTE", "GRANT OPTION"])
        #expect(GrantLevel.column("shop", "t", "c").offered(Self.privileges) == ["INSERT", "REFERENCES", "SELECT", "UPDATE"])
    }

    @Test func showGrantsKeepsTheCaseOfMySQL57sBareColumnNames() {
        let grants = AccountGrants(lines: ["GRANT SELECT (id), update (Name) ON `fixture`.`customers` TO 'bob'@'%'"], privileges: Self.privileges)
        #expect(grants.levels[.column("fixture", "customers", "id")] == ["SELECT"])
        #expect(grants.levels[.column("fixture", "customers", "Name")] == ["UPDATE"])
    }

    @Test func showGrantsReadsEveryLevelAsMariaDBWritesIt() {
        let grants = AccountGrants(lines: [
            "GRANT `lane_r` TO `bob`@`%` WITH ADMIN OPTION",
            "GRANT RELOAD, PROCESS, SLAVE MONITOR ON *.* TO `bob`@`%` IDENTIFIED VIA ed25519 USING 'hash' REQUIRE SSL WITH MAX_QUERIES_PER_HOUR 5",
            "GRANT USAGE ON `fixture`.* TO `bob`@`%` WITH GRANT OPTION",
            "GRANT ALL PRIVILEGES ON `lane\\_%`.* TO `bob`@`%`",
            "GRANT SELECT, INSERT (`id`), UPDATE (`name`, `id`), REFERENCES ON `fixture`.`customers` TO `bob`@`%` WITH GRANT OPTION",
            "GRANT EXECUTE ON PROCEDURE `fixture`.`p` TO `bob`@`%`",
            "GRANT EXECUTE ON FUNCTION `fixture`.`f` TO `bob`@`%`",
            "GRANT PROXY ON ''@'%' TO `bob`@`%` WITH GRANT OPTION",
            "SET DEFAULT ROLE `lane_r` FOR `bob`@`%`",
        ], privileges: Self.privileges)
        #expect(grants.levels[.global] == ["RELOAD", "PROCESS", "SLAVE MONITOR"])
        #expect(grants.levels[.database("fixture")] == ["GRANT OPTION"])
        #expect(grants.levels[.database("lane\\_%")]?.contains("EVENT") == true)
        #expect(grants.levels[.database("lane\\_%")]?.contains("GRANT OPTION") == false)
        #expect(grants.levels[.table("fixture", "customers")] == ["SELECT", "REFERENCES", "GRANT OPTION"])
        #expect(grants.levels[.column("fixture", "customers", "id")] == ["INSERT", "UPDATE"])
        #expect(grants.levels[.column("fixture", "customers", "name")] == ["UPDATE"])
        #expect(grants.levels[.routine("fixture", "p", isFunction: false)] == ["EXECUTE"])
        #expect(grants.levels[.routine("fixture", "f", isFunction: true)] == ["EXECUTE"])
        #expect(grants.levels.count == 8, "PROXY has no tick")
        #expect(grants.roles == [AccountGrants.Role(user: "lane_r", host: "", admin: true)])
        #expect(grants.defaultRoles == ["lane_r"])
    }

    @Test func showGrantsReadsMySQLsRolesAndDynamicPrivileges() {
        let grants = AccountGrants(lines: [
            "GRANT USAGE ON *.* TO `bob`@`%`",
            "GRANT BACKUP_ADMIN,AUDIT_ADMIN ON *.* TO `bob`@`%`",
            "GRANT `r1`@`%`,`r2`@`localhost` TO `bob`@`%`",
            "REVOKE SELECT ON `mysql`.* FROM `bob`@`%`",
        ], privileges: Self.privileges)
        #expect(grants.levels == [.global: ["BACKUP_ADMIN", "AUDIT_ADMIN"]])
        #expect(grants.roles == [AccountGrants.Role(user: "r1", host: "%"), AccountGrants.Role(user: "r2", host: "localhost")])
    }

    @Test func createWritesEachFlavoursWayOfSettingAPassword() {
        #expect(maria.create(account { $0.plugin = "ed25519" }, password: "pw") == "CREATE USER 'bob'@'%' IDENTIFIED VIA `ed25519` USING PASSWORD('pw')")
        #expect(mysql.create(account { $0.plugin = "caching_sha2_password" }, password: "pw")
                == "CREATE USER 'bob'@'%' IDENTIFIED WITH `caching_sha2_password` BY 'pw'")
        #expect(mysql.create(account(), password: "pw") == "CREATE USER 'bob'@'%' IDENTIFIED BY 'pw'")
        #expect(mysql.create(account(), password: nil) == "CREATE USER 'bob'@'%'")
        #expect(maria.create(account { $0.plugin = "unix_socket" }, password: "ignored") == "CREATE USER 'bob'@'%' IDENTIFIED VIA `unix_socket`")
        let full = account {
            $0.limits.queries = 5
            $0.limits.simultaneous = 2
            $0.tls.kind = .specified
            $0.tls.cipher = "AES"
            $0.tls.subject = "/CN=o'brien"
            $0.locked = true
            $0.expired = true
        }
        #expect(mysql.create(full, password: nil) == "CREATE USER 'bob'@'%' REQUIRE CIPHER 'AES' AND SUBJECT '/CN=o\\'brien' "
                + "WITH MAX_QUERIES_PER_HOUR 5 MAX_USER_CONNECTIONS 2 ACCOUNT LOCK PASSWORD EXPIRE")
        #expect(maria.create(ServerAccount(user: "r", host: "", isRole: true), password: nil) == "CREATE ROLE `r`")
        #expect(mysql.create(ServerAccount(user: "r", host: "%", isRole: true), password: nil) == "CREATE ROLE 'r'@'%'")
    }

    @Test func alterWritesOnlyWhatChanged() {
        let old = account { $0.plugin = "ed25519" }
        #expect(maria.alter(old, to: old, password: nil).isEmpty)
        #expect(maria.alter(old, to: old, password: "") .isEmpty)
        #expect(maria.alter(old, to: old, password: "pw") == ["ALTER USER 'bob'@'%' IDENTIFIED VIA `ed25519` USING PASSWORD('pw')"])
        var new = old
        new.host = "10.0.0.%"
        new.locked = true
        new.limits.updates = 9
        new.tls.kind = .any
        #expect(maria.alter(old, to: new, password: nil) == [
            "RENAME USER 'bob'@'%' TO 'bob'@'10.0.0.%'",
            "ALTER USER 'bob'@'10.0.0.%' REQUIRE SSL WITH MAX_UPDATES_PER_HOUR 9 ACCOUNT LOCK"])
        var unlocked = new
        unlocked.locked = false
        unlocked.tls.kind = .none
        #expect(mysql.alter(new, to: unlocked, password: nil) == ["ALTER USER 'bob'@'10.0.0.%' REQUIRE NONE ACCOUNT UNLOCK"])
    }

    @Test func aRoleHasItsOwnStatements() {
        let role = ServerAccount(user: "r", host: "", isRole: true)
        #expect(maria.drop(role) == "DROP ROLE `r`" && mysql.drop(account()) == "DROP USER 'bob'@'%'")
        #expect(maria.showGrants(role) == "SHOW GRANTS FOR `r`")
    }

    @Test func changesRevokeThenGrantLevelByLevel() {
        let old: [GrantLevel: Set<String>] = [.global: ["PROCESS"], .table("d", "t"): ["SELECT", "GRANT OPTION"],
                                              .column("d", "t", "c"): ["UPDATE"]]
        let new: [GrantLevel: Set<String>] = [.database("d"): ["SELECT"], .table("d", "t"): ["SELECT", "INSERT"],
                                              .column("d", "t", "c"): ["INSERT"], .routine("d", "p", isFunction: true): ["EXECUTE"]]
        #expect(maria.changes(account(), from: old, to: new) == [
            "REVOKE PROCESS ON *.* FROM 'bob'@'%'",
            "REVOKE GRANT OPTION ON `d`.`t` FROM 'bob'@'%'",
            "REVOKE UPDATE (`c`) ON `d`.`t` FROM 'bob'@'%'",
            "GRANT SELECT ON `d`.* TO 'bob'@'%'",
            "GRANT INSERT ON `d`.`t` TO 'bob'@'%'",
            "GRANT INSERT (`c`) ON `d`.`t` TO 'bob'@'%'",
            "GRANT EXECUTE ON FUNCTION `d`.`p` TO 'bob'@'%'"])
    }

    @Test func changesOfRolesKeepDefaultsLast() {
        var old = AccountGrants(), new = AccountGrants()
        old.roles = [.init(user: "a", host: ""), .init(user: "b", host: "", admin: true)]
        new.roles = [.init(user: "b", host: ""), .init(user: "c", host: "", admin: true)]
        new.defaultRoles = ["c"]
        #expect(maria.changes(account(), from: old, to: new) == [
            "REVOKE `a` FROM 'bob'@'%'", "REVOKE ADMIN OPTION FOR `b` FROM 'bob'@'%'", "GRANT `c` TO 'bob'@'%' WITH ADMIN OPTION",
            "SET DEFAULT ROLE `c` FOR 'bob'@'%'"])
        new.roles = [.init(user: "c", host: "%")]
        old.roles = new.roles
        old.defaultRoles = ["c"]
        new.defaultRoles = []
        #expect(mysql.changes(account(), from: old, to: new) == ["SET DEFAULT ROLE NONE TO 'bob'@'%'"])
        new.defaultRoles = ["c"]
        old.defaultRoles = []
        #expect(mysql.changes(account(), from: old, to: new) == ["SET DEFAULT ROLE 'c'@'%' TO 'bob'@'%'"])
        old.roles[0].admin = true
        old.defaultRoles = ["c"]
        #expect(mysql.changes(account(), from: old, to: new) == ["REVOKE 'c'@'%' FROM 'bob'@'%'", "GRANT 'c'@'%' TO 'bob'@'%'"],
                "MySQL has no REVOKE ADMIN OPTION")
    }

    @Test func theListReadsAccountsWithoutAnyHash() {
        let accounts = UserSQL.accounts([
            ["bob", "%", "ed25519", "N", "1", "Y", "1", "5", "6", "7", "8", "X509", "", "", ""],
            ["r", "", "", "Y", nil, "N", "0", "0", "0", "0", "0", "", "", "", ""],
        ])
        #expect(accounts[0].locked && accounts[0].expired && accounts[0].hasPassword && accounts[0].limits.simultaneous == 8)
        #expect(accounts[0].tls.kind == .x509 && !accounts[0].isRole)
        #expect(accounts[1].isRole && accounts[1].name == "r" && !accounts[1].takesPassword)
        for sql in [UserSQL.accounts(mariaDB: true), UserSQL.accounts(mariaDB: false)] {
            #expect(!sql.contains("SELECT u.authentication_string") && !sql.contains("Password,"))
            #expect(AgentGate.isReadOnly(sql, noBackslashEscapes: false), "an agent's look at the list asks nobody")
        }
        let mysqlRows: [[String?]] = [["r", "%", "caching_sha2_password", "N", "Y", "Y", "0", "0", "0", "0", "0", "", "", "", ""],
                                      ["s", "%", "caching_sha2_password", "N", "N", "N", "1", "0", "0", "0", "0", "", "", "", ""]]
        #expect(UserSQL.accounts(mysqlRows, roles: [["s", "%"]]).map(\.isRole) == [true, true])
        #expect(UserSQL.accounts(mysqlRows).map(\.isRole) == [false, false], "MySQL 5.7 has no roles")
    }

    @Test func aMistakeIsSaidBeforeAnythingIsShown() {
        func problem(_ old: ServerAccount?, _ new: ServerAccount, _ password: String = "", _ repeated: String = "") -> String? {
            UserSQL.problem(old, new, password: password, repeated: repeated)
        }
        #expect(problem(nil, ServerAccount(user: "", host: "%")) != nil)
        #expect(problem(nil, ServerAccount(user: "a", host: "")) != nil)
        #expect(problem(nil, ServerAccount(user: "a", host: "%"), "x", "y") == "The two passwords aren't the same")
        #expect(problem(nil, ServerAccount(user: "a", host: "%"), "x", "x") == nil)
        #expect(problem(nil, ServerAccount(user: "r", host: "", isRole: true)) == nil)
        let old = account { $0.plugin = "mysql_native_password"; $0.expired = true }
        var new = old
        new.plugin = "ed25519"
        #expect(problem(old, new) == "Type a new password to change the login method", "ALTER USER would empty the password")
        #expect(problem(old, new, "x", "x") == nil)
        new.plugin = "unix_socket"
        #expect(problem(old, new) == nil)
        var unexpired = old
        unexpired.expired = false
        #expect(problem(old, unexpired) != nil)
    }

    @Test func aGeneratedPasswordHasEveryKindOfCharacterAndNothingToEscape() {
        let first = UserSQL.generatedPassword(), second = UserSQL.generatedPassword()
        #expect(first != second && first.count == 20)
        #expect(first.contains(where: \.isUppercase) && first.contains(where: \.isLowercase) && first.contains(where: \.isNumber))
        #expect(first.contains { !$0.isLetter && !$0.isNumber })
        #expect(SQLQuote.string(first) == "'\(first)'")
    }

    // MARK: Secrets

    static let passwords = ["S3cret-pass", "it's", "back\\slash", "ends\\", "'; DROP USER x; --", "two\nlines", "quote\"d", "*/ x /*", "пароль"]

    @Test(arguments: passwords) func everyStatementThatCarriesAPasswordIsMasked(password: String) {
        for noBackslashEscapes in [false, true] {
            let maria = UserSQL(mariaDB: true, noBackslashEscapes: noBackslashEscapes)
            let mysql = UserSQL(mariaDB: false, noBackslashEscapes: noBackslashEscapes)
            let native = account { $0.plugin = "mysql_native_password" }
            let statements = [maria.create(account { $0.plugin = "ed25519" }, password: password), mysql.create(account(), password: password),
                              mysql.create(native, password: password)]
                + maria.alter(native, to: native, password: password) + mysql.alter(native, to: native, password: password)
            for sql in statements {
                let masked = SQLLog.mask(sql, noBackslashEscapes: noBackslashEscapes)
                #expect(masked.contains("<secret>"), "\(masked)")
                #expect(!masked.contains(password) && !masked.contains(SQLQuote.string(password, noBackslashEscapes: noBackslashEscapes)))
            }
            let text = ChangeSQL(title: "t", statements: statements + ["GRANT SELECT ON *.* TO 'bob'@'%'"], connection: UUID()).text
            #expect(!SQLLog.mask(text, noBackslashEscapes: noBackslashEscapes).contains(password), "joined, as the preview shows them")
        }
    }

    @Test func maskingHidesTheHashSHOWGRANTSQuotes() {
        for line in ["GRANT USAGE ON *.* TO `a`@`%` IDENTIFIED VIA ed25519 USING 'vRq+ROSz' REQUIRE SSL",
                     "GRANT USAGE ON *.* TO `a`@`%` IDENTIFIED BY PASSWORD '*2470C0C06DEE'"] {
            #expect(SQLLog.mask(line).contains("<secret>") && !SQLLog.mask(line).contains("vRq") && !SQLLog.mask(line).contains("2470"))
        }
    }

    @Test func aPrintedChangeShowsNoStatements() {
        let change = ChangeSQL(title: "New user", statements: ["CREATE USER a IDENTIFIED BY 'S3cret-pass'"], connection: UUID())
        #expect(!"\(change)".contains("S3cret") && !String(reflecting: change).contains("S3cret"))
    }

    @Test func aFailureNeverQuotesThePassword() {
        let syntax = ErrorMapping.map(code: 1064, message: "You have an error in your SQL near 'IDENTIFIED BY 'S3cret-p' at line 1")
        #expect(!UserSQL.errorText(syntax, hiding: "S3cret-pass").contains("S3cret"), "the server cuts its quote off anywhere")
        let other = ErrorMapping.map(code: 1819, message: "it's rejected: it\\'s and it's")
        #expect(!UserSQL.errorText(other, hiding: "it's").contains("it's"))
        #expect(UserSQL.errorText(syntax, hiding: nil) == syntax.localizedDescription, "without a password nothing goes")
    }

    @Test func anotherSessionsPasswordIsMaskedInTheProcessList() {
        let process = ServerProcess(id: 1, user: "u", host: "h", database: nil, command: "Query", time: 0, state: nil,
                                    info: "/* airsql:tools:3 */ ALTER USER 'a'@'%' IDENTIFIED BY 'S3cret-pass'", queryID: nil)
        #expect(process.shownInfo?.contains("S3cret") == false)
        #expect(process.info?.contains("S3cret") == true, "Kill compares what the server said")
    }

    @Test func theUserManagersWritesAreNeverReadOnly() {
        let new = account { $0.plugin = "ed25519" }
        let role = ServerAccount(user: "r", host: "", isRole: true)
        var granted = AccountGrants()
        granted.roles = [.init(user: "r", host: "")]
        granted.defaultRoles = ["r"]
        let statements = [maria.create(new, password: "pw"), maria.drop(new), maria.create(role, password: nil)]
            + maria.alter(new, to: account { $0.locked = true }, password: nil)
            + maria.changes(new, from: [:], to: [.global: ["SELECT"]]) + maria.changes(new, from: [.global: ["SELECT"]], to: [:])
            + maria.changes(new, from: AccountGrants(), to: granted)
        #expect(statements.count >= 8)
        for sql in statements { #expect(!AgentGate.isReadOnly(sql, noBackslashEscapes: false), "\(sql)") }
        #expect(AgentGate.isReadOnly(maria.showGrants(new), noBackslashEscapes: false))
        #expect(AgentGate.isReadOnly(UserSQL.privileges, noBackslashEscapes: false))
        #expect(AgentGate.isReadOnly(UserSQL.plugins, noBackslashEscapes: false))
    }
}

/// Every statement against real servers, the shared lab left as it was. The lab's airsql login has every privilege.
@Suite(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"), .serialized) struct UsersLabTests {
    static let servers = Lab.direct

    private func session(_ server: Lab.Server) async throws -> (DBConnection, UserSQL) {
        let session = DBConnection(options: DBLab.options(server), role: .tools, log: DBLab.log)
        try await session.connect()
        return (session, UserSQL(mariaDB: server.flavor == .mariadb, noBackslashEscapes: session.noBackslashEscapes))
    }

    private func grants(_ account: ServerAccount, _ sql: UserSQL, _ session: DBConnection, _ privileges: [ServerPrivilege]) async throws -> AccountGrants {
        AccountGrants(lines: try await session.rows(sql.showGrants(account)).compactMap { $0.first ?? nil }, privileges: privileges)
    }

    @Test(arguments: servers) func anAccountGoesThroughItsWholeLife(server: Lab.Server) async throws {
        let (session, sql) = try await session(server)
        var account = ServerAccount(user: "lane_users_life", host: "%")
        let moved = { var other = account; other.host = "localhost"; return other }()
        let role = ServerAccount(user: "lane_users_role", host: server.flavor == .mariadb ? "" : "%", isRole: true)
        for statement in [sql.drop(account), sql.drop(moved), sql.drop(role)] { _ = try? await session.query(statement) }
        let mariaDB = server.flavor == .mariadb
        func read(_ wanted: String) async throws -> ServerAccount {
            let rows = try await session.rows(UserSQL.accounts(mariaDB: mariaDB))
            let roles = mariaDB || server.version.hasPrefix("5.") ? nil : try await session.rows(UserSQL.grantedRoles)
            return try #require(UserSQL.accounts(rows, roles: roles).first { $0.user == account.user && $0.host == wanted })
        }

        // Create, with every clause, and log in with what was typed.
        let roles = mariaDB || !server.version.hasPrefix("5.")  // MySQL 5.7 has neither roles nor caching_sha2_password
        account.plugin = mariaDB ? "ed25519" : roles ? "caching_sha2_password" : "sha256_password"
        account.limits.queries = 500
        account.limits.simultaneous = 3
        account.tls.kind = .none
        let password = "it's a \\ test"
        _ = try await session.query(sql.create(account, password: password))
        var read1 = try await read("%")
        #expect(read1.plugin == account.plugin && read1.limits == account.limits && read1.hasPassword && !read1.locked && !read1.isRole)
        var options = DBLab.options(server)
        options.user = account.user
        options.password = password
        let login = DBConnection(options: options, role: .tools, log: DBLab.log)
        _ = try await login.connect()
        await login.close()

        // Alter: the same method stays with a new password, then the rest.
        var changed = read1
        changed.limits.queries = 0
        changed.limits.updates = 7
        changed.locked = true
        changed.expired = true
        changed.tls.kind = .specified
        changed.tls.cipher = "ECDHE-RSA-AES256-GCM-SHA384"
        changed.tls.subject = "/CN=o'brien"
        for statement in sql.alter(read1, to: changed, password: "second-Pass1") { _ = try await session.query(statement) }
        read1 = try await read("%")
        #expect(read1.plugin == account.plugin, "a new password doesn't move the account to another method")
        #expect(read1.limits == changed.limits && read1.locked && read1.expired)
        #expect(read1.tls == changed.tls)

        // Privileges at every level, read back as they were ticked.
        let privileges = UserSQL.privileges(try await session.rows(UserSQL.privileges))
        #expect(privileges.count > 20 && !GrantLevel.database("fixture").offered(privileges).isEmpty)
        let levels: [GrantLevel: Set<String>] = [
            .global: ["PROCESS"], .database("fixture"): ["SELECT", "CREATE VIEW", "GRANT OPTION"], .database("lane\\_users\\_%"): ["SELECT"],
            .table("fixture", "customers"): ["INSERT", "GRANT OPTION"], .column("fixture", "customers", "id"): ["SELECT", "UPDATE"],
        ]
        for statement in sql.changes(read1, from: [:], to: levels) { _ = try await session.query(statement) }
        var held = try await grants(read1, sql, session, privileges)
        #expect(held.levels == levels)
        var fewer = levels
        fewer[.global] = []
        fewer[.database("fixture")] = ["SELECT"]
        fewer[.column("fixture", "customers", "id")] = ["SELECT"]
        for statement in sql.changes(read1, from: held.levels, to: fewer) { _ = try await session.query(statement) }
        held = try await grants(read1, sql, session, privileges)
        #expect(held.levels[.global] ?? [] == [])
        #expect(held.levels[.database("fixture")] == ["SELECT"] && held.levels[.column("fixture", "customers", "id")] == ["SELECT"])

        // Roles: granted, passed on, on at login, taken away.
        if roles {
            _ = try await session.query(sql.create(role, password: nil))
            let readRole = UserSQL.accounts(try await session.rows(UserSQL.accounts(mariaDB: mariaDB)),
                                            roles: mariaDB ? nil : try await session.rows(UserSQL.grantedRoles)).first { $0.user == role.user }
            #expect(readRole?.isRole == true)
            var roleGrant = AccountGrants()
            roleGrant.roles = [.init(user: role.user, host: role.host, admin: true)]
            roleGrant.defaultRoles = [role.user]
            for statement in sql.changes(read1, from: AccountGrants(), to: roleGrant) { _ = try await session.query(statement) }
            held = try await grants(read1, sql, session, privileges)
            #expect(held.roles == roleGrant.roles)
            if !mariaDB { held.defaultRoles = Set(try await session.rows(sql.defaultRoles(read1)).compactMap { $0.first ?? nil }) }
            #expect(held.defaultRoles == [role.user])
            var noAdmin = roleGrant
            noAdmin.roles[0].admin = false
            noAdmin.defaultRoles = []
            for statement in sql.changes(read1, from: held, to: noAdmin) { _ = try await session.query(statement) }
            held = try await grants(read1, sql, session, privileges)
            #expect(held.roles == noAdmin.roles)
            for statement in sql.changes(read1, from: noAdmin, to: AccountGrants()) { _ = try await session.query(statement) }
            #expect(try await grants(read1, sql, session, privileges).roles.isEmpty)
        }

        // Renamed, and gone.
        var renamed = read1
        renamed.host = "localhost"
        for statement in sql.alter(read1, to: renamed, password: nil) { _ = try await session.query(statement) }
        #expect(try await read("localhost").locked)
        _ = try await session.query(sql.drop(renamed))
        if roles { _ = try await session.query(sql.drop(role)) }
        // Its own two by name: the app's tests make lane_users_* accounts on these servers at the same time.
        #expect(try await session.rows("SELECT COUNT(*) FROM mysql.user WHERE User IN ('lane_users_life', 'lane_users_role')").first?.first == "0")
        await session.close()
    }

    @Test(arguments: servers) func anExpiredLoginChangesItsPasswordAndNothingElseRuns(server: Lab.Server) async throws {
        let (admin, sql) = try await session(server)
        let account = ServerAccount(user: "lane_users_expired", host: "%")
        _ = try? await admin.query(sql.drop(account))
        var expired = account
        expired.expired = true
        _ = try await admin.query(sql.create(expired, password: "old-Pass1"))
        var options = DBLab.options(server)
        options.user = account.user
        options.password = "old-Pass1"
        let log = SQLLog(fileURL: URL(fileURLWithPath: NSTemporaryDirectory() + UUID().uuidString + "/SQL.log"))
        let refused = DBConnection(options: options, role: .tools, log: log)
        await #expect {
            _ = try await refused.connect()
        } throws: { error in
            let error = error as? AirSQLError
            return error?.kind == .authFailed && [1820, 1862].contains(error?.code ?? 0)
        }
        await refused.close()

        options.newPassword = "new-S3cret'1"
        let changing = DBConnection(options: options, role: .tools, log: log)
        _ = try await changing.connect()
        await changing.close()
        options.newPassword = nil
        options.password = "new-S3cret'1"
        let after = DBConnection(options: options, role: .tools, log: log)
        _ = try await after.connect()
        #expect(try await after.rows("SELECT 1").first?.first == "1", "it works as any session")
        await after.close()
        #expect(!(try String(contentsOf: log.fileURL, encoding: .utf8)).contains("S3cret"))
        _ = try await admin.query(sql.drop(account))
        await admin.close()
    }

    @Test(arguments: servers) func theAccountsListHoldsNoHash(server: Lab.Server) async throws {
        let (session, _) = try await session(server)
        let results = try await session.query(UserSQL.accounts(mariaDB: server.flavor == .mariadb))
        let store = try #require(results.first?.rows)
        for row in 0..<store.rowCount {
            for column in 0..<store.columns.count { #expect(store.string(row, column)?.hasPrefix("*") != true) }
        }
        await session.close()
    }
}

extension AppTests {
    @MainActor @Suite struct UsersAppTests {
        static let accounts: [ServerAccount] = {
            var login = ServerAccount(user: "bob", host: "%")
            login.plugin = "mysql_native_password"
            login.hasPassword = true
            login.limits.queries = 5
            return [login, ServerAccount(user: "r", host: "", isRole: true)]
        }()

        private func opened(_ change: (inout SavedConnection) -> Void = { _ in }) async -> (AppModel, MainWindowController, AgentServer, OpenConnection, UsersContent) {
            var saved = Fixtures.local
            change(&saved)
            let model = testModel([saved])
            let (main, harness) = appWindow(model)
            let open = await openReplayed(model, saved.id)
            let users = UsersContent(open)
            main.open(users, title: "Users", connection: saved.id)
            _ = await eventually(timeout: 20) { users.list.note.contains("couldn't read") }  // a replay has no server
            users.privileges = UsersCoreTests.privileges
            users.show(Self.accounts)
            return (model, main, harness, open, users)
        }

        private func select(_ users: UsersContent, _ row: Int = 0) {
            users.list.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        private func editor(_ main: MainWindowController) -> AccountEditor? { main.window?.attachedSheet?.windowController as? AccountEditor }

        @Test func theListShowsAccountsWithoutSecretsAndSaysWhyItIsEmpty() async {
            let (_, _, _, _, users) = await opened()
            #expect(users.list.rows.map { $0.cells["user"] } == ["bob", "r"])
            #expect(users.list.rows[0].cells["password"] == "Set" && users.list.rows[1].cells["kind"] == "Role")
            #expect(users.list.rows[0].cells["limits"] == "5 queries/h")
            users.copyList(nil)
            #expect(NSPasteboard.general.string(forType: .string)?.hasPrefix("Name,Host,Kind,") == true)
        }

        @Test func everyWriteIsRefusedInReadOnlyProductionAndToAgents() async throws {
            let (_, _, _, _, free) = await opened()
            select(free)
            #expect(free.newUserButton.isEnabled && free.editButton.isEnabled)
            let refusals: [(inout SavedConnection) -> Void] = [{ $0.readOnly = true }, { $0.colour = .production }, { $0.safety = .production }]
            for change in refusals {
                let (_, main, _, _, users) = await opened(change)
                select(users)
                #expect(!users.newUserButton.isEnabled && !users.newRoleButton.isEnabled && !users.editButton.isEnabled)
                #expect(users.editButton.toolTip?.contains("can't be changed") == true)
                for command in [Commands.newUser, Commands.newRole, Commands.editUser, Commands.cloneUser, Commands.dropUser] {
                    let item = command.item()
                    #expect(!users.validateMenuItem(item) && item.toolTip?.contains("can't be changed") == true)
                }
                users.dropUser(nil)
                #expect(main.window?.attachedSheet?.windowController as? AccountEditor == nil)
                #expect((main.window?.attachedSheet.flatMap { find(NSTextView.self, id: "preview.sql", in: $0.contentView!) }) == nil, "no SQL to run")
                if let sheet = main.window?.attachedSheet { main.window?.endSheet(sheet) }
            }
        }

        @Test func anAgentsPressReachesNothing() async {
            let (_, main, _, open, users) = await opened()
            select(users)
            AgentGate.$agent.withValue("Claude Code") {
                #expect(open.usersRefusal?.contains("Only the person") == true)
                let notes = AgentGuard.Notes()
                AgentGuard.$notes.withValue(notes) {
                    users.newUser(nil)
                    users.editUser(nil)
                    users.cloneUser(nil)
                    users.dropUser(nil)
                    users.modifyGrants(on: .global)
                    users.run(["DROP USER 'bob'@'%'"], title: "t", password: nil, warnings: [], on: main.window) {}
                }
                #expect(notes.refusal?.contains("Only the person") == true)
            }
            #expect(main.window?.attachedSheet == nil)
            #expect(AgentServer.showsData(users.list.table) && AgentServer.showsData(users.grantsText), "who may log in stays with read access")
        }

        @Test func aNewLoginsPasswordIsMaskedOnThePreviewAndItsCopy() async throws {
            let (_, main, harness, _, users) = await opened()
            users.newUser(nil)
            _ = await eventually(timeout: 5) { editor(main) != nil }
            let form = try #require(editor(main))
            let secret = "S3cret-pass'x"
            form.user.stringValue = "lane_users_new"
            form.password.stringValue = secret
            form.repeated.stringValue = "other"
            form.next(nil)
            #expect(find(NSTextField.self, id: "users.problem", in: form.window!.contentView!)?.stringValue == "The two passwords aren't the same")
            form.repeated.stringValue = secret
            form.next(nil)
            let sheet = try #require(form.window?.attachedSheet)
            let shown = try #require(find(NSTextView.self, id: "preview.sql", in: sheet.contentView!))
            #expect(shown.string.contains("<secret>") && !shown.string.contains("S3cret"))
            #expect(find(NSButton.self, id: "preview.saveChangeset", in: sheet.contentView!) == nil, "a changelog is a file")
            #expect(await call(harness, "press", ["id": "preview.copy"]).error == nil)
            #expect(NSPasteboard.general.string(forType: .string)?.contains("S3cret") == false)
            #expect(await call(harness, "press", ["id": "preview.cancel"]).error == nil)
            let snapshot = await call(harness, "snapshot", [:])
            #expect(!"\(snapshot.json)".contains("S3cret"), "a secure field shows dots")
        }

        @Test func generateFillsBothFieldsAndItsCopyIsConcealed() async throws {
            let (_, main, _, _, users) = await opened()
            users.newUser(nil)
            _ = await eventually(timeout: 5) { editor(main) != nil }
            let form = try #require(editor(main))
            #expect(!form.copyPassword.isEnabled)
            form.generatePassword(nil)
            #expect(form.password.stringValue.count == 20 && form.password.stringValue == form.repeated.stringValue)
            #expect(form.copyPassword.isEnabled)
            form.copyGenerated(nil)
            #expect(NSPasteboard.general.string(forType: .string) == form.password.stringValue)
            #expect(NSPasteboard.general.types?.map(\.rawValue).contains("org.nspasteboard.ConcealedType") == true)
            NSPasteboard.general.clearContents()
            AgentGate.$agent.withValue("Claude Code") { form.copyGenerated(nil) }
            #expect(NSPasteboard.general.string(forType: .string) == nil, "agents can't copy it")
        }

        @Test func anExpiredPasswordIsOnlyChangedWhereWritesAre() {
            var saved = Fixtures.local
            #expect(saved.usersRefusal == nil)
            saved.readOnly = true
            #expect(saved.usersRefusal != nil)
            let error = ErrorMapping.map(code: 1820, message: "You must SET PASSWORD before executing this statement")
            #expect(error.kind == .authFailed && error.message.hasPrefix("The password has expired"))
        }

        @Test func theTreeHasAUsersRowAndModifyGrantsFollowsTheSelection() async throws {
            let model = testModel([Fixtures.local])
            let (main, harness) = appWindow(model)
            let open = await openReplayed(model, Fixtures.local.id)
            main.sidebar.reload()
            let outline = main.sidebar.outline
            let connection = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarNode }.first { $0.connectionID == open.id }
            outline.expandItem(connection)
            let row = try #require(treeRow(main, .users(open.id)))
            main.sidebar.outline.selectRowIndexes(IndexSet(integer: row.row), byExtendingSelection: false)
            main.sidebar.showSelectedObject()
            #expect(main.selectedTab?.shown is UsersContent)
            #expect(main.sidebar.treeMenu(main.sidebar.selectedNodes).items.map(\.title) == ["Users and Roles"])
            main.showUsers(open)
            #expect(main.tabs.count == 1, "the tab it has")
            main.close(try #require(main.tabs.first))
            #expect(await call(harness, "menu", ["path": "Database > Users > Users and Roles"]).error == nil, "the menu bar reaches it")
            #expect(main.selectedTab?.shown is UsersContent)
            let database = NavigatorActions.reason(for: Commands.modifyGrants.action, objects: [], databases: ["d"], open: open, target: open, model: model)
            #expect(database == nil, "\(database ?? "")")
            let two = NavigatorActions.reason(for: Commands.modifyGrants.action, objects: [], databases: ["d", "e"], open: open, target: open, model: model)
            #expect(two == "Select one database, table or routine first")
        }
    }

    @MainActor @Suite(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh")) struct UsersAppLabTests {
        @Test func aPersonMakesChangesAndDropsALoginAndThePasswordStaysOutOfTheLog() async throws {
            let server = Lab.mariadb114
            let folder = NSTemporaryDirectory() + UUID().uuidString
            let log = SQLLog(fileURL: URL(fileURLWithPath: folder + "/SQL.log"))
            let saved = SavedConnection(name: "Lab", host: "127.0.0.1", port: server.port!, user: Lab.airsql.user)
            let model = testModel([saved])
            let (main, harness) = appWindow(model)
            let connection = Connection(options: DBLab.options(server), log: log)
            try await connection.connect()
            let open = model.attach(connection, to: saved.id) { $0 == "fixture" }
            defer { model.detach(open.id) }
            _ = await eventually(timeout: 60) { open.snapshot.server != nil && open.loading.isEmpty }
            for name in ["lane_users_ui", "lane_users_clone"] {
                _ = try? await open.run(["DROP USER IF EXISTS '\(name)'@'%'"], title: "Clean")
            }
            _ = try? await open.run(["DROP ROLE IF EXISTS lane_users_uirole"], title: "Clean")
            let users = try #require(main.showUsers(open))
            #expect(await eventually(timeout: 20) { users.list.rows.contains { $0.cells["user"] == "airsql" } })
            let secret = "Lane's-S3cret\\pw"

            func form() async throws -> AccountEditor {
                _ = await eventually(timeout: 10) { main.window?.attachedSheet?.windowController is AccountEditor }
                return try #require(main.window?.attachedSheet?.windowController as? AccountEditor)
            }
            func run(_ editor: AccountEditor) async throws {
                editor.next(nil)
                _ = await eventually(timeout: 5) { editor.window?.attachedSheet != nil }
                let preview = try #require(editor.window?.attachedSheet)
                #expect(find(NSTextView.self, id: "preview.sql", in: preview.contentView!)?.string.contains("S3cret") == false)
                #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
                #expect(await eventually(timeout: 20) { main.window?.attachedSheet == nil }, "it closes once it ran")
            }
            func select(_ name: String) async {
                _ = await eventually(timeout: 20) { users.list.rows.contains { $0.cells["user"] == name } }
                let index = users.list.rows.firstIndex { $0.cells["user"] == name } ?? 0
                users.list.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }

            // A role, then a login with a password, a privilege and the role.
            users.newRole(nil)
            let role = try await form()
            role.user.stringValue = "lane_users_uirole"
            try await run(role)
            await select("lane_users_uirole")
            users.newUser(nil)
            let new = try await form()
            new.user.stringValue = "lane_users_ui"
            new.password.stringValue = secret
            new.repeated.stringValue = secret
            new.tree.add(.database("fixture"))
            new.tree.set("SELECT", on: .database("fixture"), true)
            let row = try #require(new.roleRows.first { $0.role.user == "lane_users_uirole" })
            row.granted.state = .on
            row.isDefault.state = .on
            try await run(new)
            await select("lane_users_ui")
            #expect(await eventually(timeout: 10) { users.grantsText.string.contains("`fixture`") })
            #expect(users.grantsText.string.contains("<secret>"), "SHOW GRANTS' hash is masked: \(users.grantsText.string)")
            #expect(users.grantsText.string.contains("SET DEFAULT ROLE"))
            var options = DBLab.options(server)
            options.user = "lane_users_ui"
            options.password = secret
            let login = DBConnection(options: options, role: .tools, log: log)
            _ = try await login.connect()
            await login.close()

            // Edit: lock it, take the privilege away.
            users.editUser(nil)
            let edit = try await form()
            #expect(edit.tree.ticked[.database("fixture")] == ["SELECT"])
            edit.tree.set("SELECT", on: .database("fixture"), false)
            try await run(edit)
            await select("lane_users_ui")
            #expect(await eventually(timeout: 10) { !users.grantsText.string.isEmpty && !users.grantsText.string.contains("`fixture`") })

            // Clone: the grants come, the password doesn't.
            users.cloneUser(nil)
            let clone = try await form()
            #expect(clone.user.stringValue.isEmpty && clone.password.stringValue.isEmpty)
            clone.user.stringValue = "lane_users_clone"
            clone.generatePassword(nil)
            try await run(clone)
            await select("lane_users_clone")
            #expect(await eventually(timeout: 10) { users.grantsText.string.contains("lane_users_uirole") })

            // A failure says so without the password, and the form stays.
            users.newUser(nil)
            let duplicate = try await form()
            duplicate.user.stringValue = "lane_users_ui"
            duplicate.password.stringValue = secret
            duplicate.repeated.stringValue = secret
            duplicate.next(nil)
            _ = await eventually(timeout: 5) { duplicate.window?.attachedSheet != nil }
            #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
            _ = await eventually(timeout: 20) { (duplicate.window?.attachedSheet?.windowController as? SQLPreviewSheet) == nil && duplicate.window?.attachedSheet != nil }
            let alert = try #require(duplicate.window?.attachedSheet)
            #expect(!Self.text(in: alert.contentView!).contains("S3cret"))
            duplicate.window?.endSheet(alert)
            main.window?.endSheet(duplicate.window!)

            // Drop asks for the name.
            await select("lane_users_clone")
            users.dropUser(nil)
            #expect(await call(harness, "set", ["id": "preview.confirm", "value": "lane_users_clone@%"]).error == nil)
            #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
            #expect(await eventually(timeout: 20) { !users.list.rows.contains { $0.cells["user"] == "lane_users_clone" } })

            _ = try await open.run(["DROP USER 'lane_users_ui'@'%'", "DROP ROLE lane_users_uirole"], title: "Clean")
            users.release()
            let written = try String(contentsOf: log.fileURL, encoding: .utf8)
            #expect(written.contains("CREATE USER") && written.contains("<secret>"))
            #expect(!written.contains("S3cret"), "the SQL log masks it")
        }

        @Test func connectingWithAnExpiredPasswordAsksForANewOneAndKeepsNothing() async throws {
            let server = Lab.mariadb114
            let admin = DBConnection(options: DBLab.options(server), role: .tools, log: DBLab.log)
            try await admin.connect()
            _ = try await admin.query("DROP USER IF EXISTS 'lane_users_exp'@'%'")
            _ = try await admin.query("CREATE USER 'lane_users_exp'@'%' IDENTIFIED BY 'old-Pass1' PASSWORD EXPIRE")
            var saved = SavedConnection(name: "Expired", host: "127.0.0.1", port: server.port!, user: "lane_users_exp")
            saved.tls.mode = .off
            let model = testModel([saved])
            model.setSavedPassword(saved.id.uuidString, "old-Pass1")
            let (main, harness) = appWindow(model)
            model.connector.connect(saved.id, on: main.window)
            #expect(await eventually(timeout: 20) { main.window?.attachedSheet != nil })
            #expect(await call(harness, "set", ["id": "password.new", "value": "new-Pass1"]).error == nil)
            #expect(await call(harness, "set", ["id": "password.repeat", "value": "new-Pass1"]).error == nil)
            #expect(await call(harness, "press", ["title": "Change"]).error == nil)
            #expect(await eventually(timeout: 20) { model.connector.open[saved.id] != nil }, "the connect goes on with it")
            #expect(model.savedPassword(saved.id.uuidString) == "old-Pass1", "nothing here stores a password")
            model.connector.disconnect(saved.id)

            // Read-only says what it said, and changes nothing.
            _ = try await admin.query("ALTER USER 'lane_users_exp'@'%' PASSWORD EXPIRE")
            var locked = saved
            locked.readOnly = true
            let other = testModel([locked])
            other.setSavedPassword(locked.id.uuidString, "new-Pass1")
            let (second, _) = appWindow(other)
            other.connector.connect(locked.id, on: second.window)
            #expect(await eventually(timeout: 20) {
                if case .failed(let text)? = other.states[locked.id] { return text.contains("expired") }
                return false
            })
            #expect((second.window?.attachedSheet?.contentView).flatMap { find(NSSecureTextField.self, in: $0) } == nil, "it says so, and asks for nothing")
            _ = try await admin.query("DROP USER 'lane_users_exp'@'%'")
            await admin.close()
        }

        private static func text(in view: NSView) -> String {
            let own = (view as? NSTextField)?.stringValue ?? ""
            return view.subviews.map(text).joined(separator: " ") + " " + own
        }
    }
}
