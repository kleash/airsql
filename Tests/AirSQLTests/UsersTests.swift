import Foundation
import Testing
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
