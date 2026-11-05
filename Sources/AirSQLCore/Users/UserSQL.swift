import Foundation

/// The user manager's statements (scope "server"). A new password is an argument of the functions that need it, and exists
/// only in the statements they return: nothing here keeps it. Those statements are masked wherever they show (`SQLLog.mask`).
public struct UserSQL {
    public var mariaDB: Bool
    public var noBackslashEscapes: Bool

    public init(mariaDB: Bool, noBackslashEscapes: Bool) {
        self.mariaDB = mariaDB
        self.noBackslashEscapes = noBackslashEscapes
    }

    // MARK: Reading

    /// Every account with what the list shows; a password only as whether there is one. Locked is in MariaDB's JSON.
    public static func accounts(mariaDB: Bool) -> String {
        let limits = "u.max_questions, u.max_updates, u.max_connections, u.max_user_connections, u.ssl_type, u.ssl_cipher, u.x509_issuer, u.x509_subject"
        return mariaDB
            ? "SELECT u.User, u.Host, u.plugin, u.is_role, JSON_VALUE(g.Priv, '$.account_locked'), u.password_expired, "
                + "u.authentication_string <> '', \(limits) FROM mysql.user u "
                + "LEFT JOIN mysql.global_priv g ON g.Host = u.Host AND g.User = u.User ORDER BY u.User, u.Host"
            : "SELECT u.User, u.Host, u.plugin, 'N', u.account_locked, u.password_expired, u.authentication_string <> '', "
                + "\(limits) FROM mysql.user u ORDER BY u.User, u.Host"
    }

    /// MySQL has no mark for a role: those granted to someone, by their user and host.
    public static let grantedRoles = "SELECT DISTINCT FROM_USER, FROM_HOST FROM mysql.role_edges"
    public static let privileges = "SHOW PRIVILEGES"
    public static let plugins = "SELECT PLUGIN_NAME FROM information_schema.PLUGINS WHERE PLUGIN_TYPE = 'AUTHENTICATION' "
        + "AND PLUGIN_STATUS = 'ACTIVE' ORDER BY PLUGIN_NAME"

    /// Reads `accounts`' rows. On MySQL 8 `roles` holds `grantedRoles`' rows: a role is one of those, or a login that is
    /// locked, expired and has no password, which is how CREATE ROLE leaves it. nil: the server marks its roles, or has none.
    public static func accounts(_ rows: [[String?]], roles: [[String?]]? = nil) -> [ServerAccount] {
        func yes(_ text: String?) -> Bool { ["Y", "1"].contains(text ?? "") }
        func number(_ text: String?) -> Int { text.flatMap { Int($0) } ?? 0 }
        let granted = Set((roles ?? []).compactMap { row in row.count >= 2 ? (row[0] ?? "") + "\u{0}" + (row[1] ?? "") : nil })
        return rows.compactMap { row in
            guard row.count >= 15 else { return nil }
            var account = ServerAccount(user: row[0] ?? "", host: row[1] ?? "")
            account.plugin = row[2] ?? ""
            account.locked = yes(row[4])
            account.expired = yes(row[5])
            account.hasPassword = yes(row[6])
            account.isRole = yes(row[3]) || granted.contains(account.key)
                || (roles != nil && account.locked && account.expired && !account.hasPassword)
            account.limits.queries = number(row[7])
            account.limits.updates = number(row[8])
            account.limits.connections = number(row[9])
            account.limits.simultaneous = number(row[10])
            account.tls.kind = ServerAccount.TLS.Kind(rawValue: (row[11] ?? "").uppercased()) ?? .none
            account.tls.cipher = row[12] ?? ""
            account.tls.issuer = row[13] ?? ""
            account.tls.subject = row[14] ?? ""
            return account
        }
    }

    /// Reads SHOW PRIVILEGES' rows, the names as GRANT writes them.
    public static func privileges(_ rows: [[String?]]) -> [ServerPrivilege] {
        rows.compactMap { row in
            guard row.count >= 3, let name = row[0] else { return nil }
            return ServerPrivilege(name: name.uppercased(), context: row[1] ?? "", comment: row[2] ?? "")
        }
    }

    public func showGrants(_ account: ServerAccount) -> String { "SHOW GRANTS FOR " + quoted(account) }

    /// MySQL keeps default roles in a table of their own; MariaDB's are in SHOW GRANTS.
    public func defaultRoles(_ account: ServerAccount) -> String {
        "SELECT DEFAULT_ROLE_USER FROM mysql.default_roles WHERE USER = " + text(account.user) + " AND HOST = " + text(account.host)
    }

    // MARK: Names

    private func text(_ value: String) -> String { SQLQuote.string(value, noBackslashEscapes: noBackslashEscapes) }

    /// 'user'@'host'; a MariaDB role has only its name.
    public func quoted(_ account: ServerAccount) -> String {
        if mariaDB && account.isRole { return SQLQuote.identifier(account.user) }
        return text(account.user) + "@" + text(account.host)
    }

    private func quoted(_ role: AccountGrants.Role) -> String {
        var account = ServerAccount(user: role.user, host: role.host, isRole: true)
        if !mariaDB && role.host.isEmpty { account.host = "%" }
        return quoted(account)
    }

    // MARK: Accounts

    /// The login's method and password. A password goes through the method named, as a bare IDENTIFIED BY would move a
    /// MariaDB account to the native method; nil: none is being set.
    private func identified(_ account: ServerAccount, password: String?) -> String? {
        let plugin = SQLQuote.identifier(account.plugin)
        guard let password, !password.isEmpty, account.takesPassword else {
            if account.plugin.isEmpty || account.takesPassword { return nil }
            return "IDENTIFIED \(mariaDB ? "VIA" : "WITH") \(plugin)"
        }
        if account.plugin.isEmpty { return "IDENTIFIED BY " + text(password) }
        return mariaDB ? "IDENTIFIED VIA \(plugin) USING PASSWORD(\(text(password)))" : "IDENTIFIED WITH \(plugin) BY \(text(password))"
    }

    private func require(_ tls: ServerAccount.TLS) -> String {
        switch tls.kind {
        case .none: return "REQUIRE NONE"
        case .any: return "REQUIRE SSL"
        case .x509: return "REQUIRE X509"
        case .specified:
            let parts = [("CIPHER", tls.cipher), ("ISSUER", tls.issuer), ("SUBJECT", tls.subject)].filter { !$0.1.isEmpty }
            return parts.isEmpty ? "REQUIRE X509" : "REQUIRE " + parts.map { $0.0 + " " + text($0.1) }.joined(separator: " AND ")
        }
    }

    private func with(_ limits: ServerAccount.Limits, from old: ServerAccount.Limits) -> String? {
        let parts = [("MAX_QUERIES_PER_HOUR", limits.queries, old.queries), ("MAX_UPDATES_PER_HOUR", limits.updates, old.updates),
                     ("MAX_CONNECTIONS_PER_HOUR", limits.connections, old.connections),
                     ("MAX_USER_CONNECTIONS", limits.simultaneous, old.simultaneous)]
            .filter { $0.1 != $0.2 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? nil : "WITH " + parts.joined(separator: " ")
    }

    public func create(_ account: ServerAccount, password: String?) -> String {
        if account.isRole { return "CREATE ROLE " + quoted(account) }
        var parts = ["CREATE USER " + quoted(account)]
        if let identified = identified(account, password: password) { parts.append(identified) }
        if account.tls != ServerAccount.TLS() { parts.append(require(account.tls)) }
        if let with = with(account.limits, from: ServerAccount.Limits()) { parts.append(with) }
        if account.locked { parts.append("ACCOUNT LOCK") }
        if account.expired { parts.append("PASSWORD EXPIRE") }
        return parts.joined(separator: " ")
    }

    /// RENAME USER when the name or host changed, then one ALTER USER of what changed. Clearing Expired takes a new
    /// password, which is what clears it.
    public func alter(_ old: ServerAccount, to new: ServerAccount, password: String?) -> [String] {
        guard !new.isRole else { return [] }
        var statements: [String] = []
        if old.user != new.user || old.host != new.host { statements.append("RENAME USER \(quoted(old)) TO \(quoted(new))") }
        var parts: [String] = []
        let setsPassword = !(password ?? "").isEmpty
        if setsPassword || old.plugin != new.plugin, let identified = identified(new, password: password) { parts.append(identified) }
        if old.tls != new.tls { parts.append(require(new.tls)) }
        if let with = with(new.limits, from: old.limits) { parts.append(with) }
        if old.locked != new.locked { parts.append(new.locked ? "ACCOUNT LOCK" : "ACCOUNT UNLOCK") }
        if new.expired && !old.expired { parts.append("PASSWORD EXPIRE") }
        if !parts.isEmpty { statements.append("ALTER USER \(quoted(new)) " + parts.joined(separator: " ")) }
        return statements
    }

    public func drop(_ account: ServerAccount) -> String { (account.isRole ? "DROP ROLE " : "DROP USER ") + quoted(account) }

    /// What the person typed that can't go to the server, in words; nil when it can.
    public static func problem(_ old: ServerAccount?, _ new: ServerAccount, password: String, repeated: String) -> String? {
        if new.user.isEmpty { return new.isRole ? "Type the role's name" : "Type the user's name" }
        if new.isRole { return nil }
        if new.host.isEmpty { return "Type the host it logs in from, or % for any" }
        if password != repeated { return "The two passwords aren't the same" }
        if password.contains("\u{0}") { return "A password can't hold a NUL character" }
        guard let old, password.isEmpty else { return nil }
        // MySQL's ALTER USER … IDENTIFIED WITH with no password empties the password.
        if old.plugin != new.plugin && new.takesPassword { return "Type a new password to change the login method" }
        if old.expired && !new.expired { return "Type a new password: only that clears an expired one" }
        return nil
    }

    /// A password with every kind of character a server's policy may ask for, none of which needs escaping.
    public static func generatedPassword(length: Int = 20) -> String {
        let sets = ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnpqrstuvwxyz", "23456789", "-_=+.:!#%"].map(Array.init)
        var generator = SystemRandomNumberGenerator()
        var characters = sets.map { $0.randomElement(using: &generator)! }
        let all = sets.flatMap { $0 }
        while characters.count < length { characters.append(all.randomElement(using: &generator)!) }
        return String(characters.shuffled(using: &generator))
    }

    /// `error`'s text for the person, with `password` out of it. A syntax error quotes the statement, cut off anywhere, so
    /// nothing of its text stays.
    public static func errorText(_ error: Error, hiding password: String?) -> String {
        guard let password, !password.isEmpty else { return error.localizedDescription }
        if let error = error as? AirSQLError, error.kind == .syntax {
            return "\(error.message) The server's words are left out, as they quote the statement and its password."
        }
        let escaped = String(SQLQuote.string(password).dropFirst().dropLast())
        return error.localizedDescription.replacingOccurrences(of: escaped, with: "<secret>").replacingOccurrences(of: password, with: "<secret>")
    }

    // MARK: Grants

    /// What takes the account's grants from `old` to `new`: REVOKE first, then GRANT, one statement a level.
    public func changes(_ account: ServerAccount, from old: [GrantLevel: Set<String>], to new: [GrantLevel: Set<String>]) -> [String] {
        func list(_ level: GrantLevel, _ privileges: Set<String>) -> String {
            let names = privileges.sorted()
            guard case .column(_, _, let column) = level else { return names.joined(separator: ", ") }
            return names.map { "\($0) (\(SQLQuote.identifier(column)))" }.joined(separator: ", ")
        }
        var revokes: [String] = [], grants: [String] = []
        for level in Set(old.keys).union(new.keys).sorted() {
            let before = old[level] ?? [], after = new[level] ?? []
            let gone = before.subtracting(after), added = after.subtracting(before)
            if !gone.isEmpty { revokes.append("REVOKE \(list(level, gone)) ON \(level.on) FROM \(quoted(account))") }
            if !added.isEmpty { grants.append("GRANT \(list(level, added)) ON \(level.on) TO \(quoted(account))") }
        }
        return revokes + grants
    }

    /// What takes the account's roles from `old` to `new`, its default roles last: a role must be granted to be default.
    public func changes(_ account: ServerAccount, from old: AccountGrants, to new: AccountGrants) -> [String] {
        var statements: [String] = []
        func key(_ role: AccountGrants.Role) -> String { role.user + "\u{0}" + role.host }
        let before = Dictionary(old.roles.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.roles.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        for role in old.roles where after[key(role)] == nil { statements.append("REVOKE \(quoted(role)) FROM \(quoted(account))") }
        for role in new.roles {
            let was = before[key(role)]
            if was == nil || (role.admin && was?.admin == false) {
                statements.append("GRANT \(quoted(role)) TO \(quoted(account))" + (role.admin ? " WITH ADMIN OPTION" : ""))
            } else if !role.admin && was?.admin == true {
                statements.append("REVOKE ADMIN OPTION FOR \(quoted(role)) FROM \(quoted(account))")
            }
        }
        if old.defaultRoles != new.defaultRoles, !account.isRole {
            let roles = new.roles.filter { new.defaultRoles.contains($0.user) }
            if mariaDB {
                statements.append("SET DEFAULT ROLE \(roles.first.map(quoted) ?? "NONE") FOR \(quoted(account))")
            } else {
                statements.append("SET DEFAULT ROLE \(roles.isEmpty ? "NONE" : roles.map(quoted).joined(separator: ", ")) TO \(quoted(account))")
            }
        }
        return statements
    }
}
