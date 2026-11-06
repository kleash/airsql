import Foundation

/// A login or role on the server, as the user manager shows and edits it. It never holds a password or its hash: the list
/// reads only whether the account has one.
public struct ServerAccount: Hashable, Sendable {
    /// The per-hour limits and simultaneous connections; 0 is no limit.
    public struct Limits: Hashable, Sendable {
        public var queries = 0, updates = 0, connections = 0, simultaneous = 0
        public init() {}
    }

    /// What the login must show of TLS (REQUIRE).
    public struct TLS: Hashable, Sendable {
        public enum Kind: String, CaseIterable, Sendable {
            case none = "", any = "ANY", x509 = "X509", specified = "SPECIFIED"
        }

        public var kind = Kind.none
        public var cipher = "", issuer = "", subject = ""
        public init() {}
    }

    public var user: String
    /// Empty for a MariaDB role.
    public var host: String
    public var isRole = false
    /// The login method; empty leaves it to the server.
    public var plugin = ""
    public var locked = false
    public var expired = false
    public var hasPassword = false
    public var limits = Limits()
    public var tls = TLS()

    public init(user: String, host: String, isRole: Bool = false) {
        self.user = user
        self.host = host
        self.isRole = isRole
    }

    /// user@host as people write it; a MariaDB role by its name.
    public var name: String { host.isEmpty && isRole ? user : "\(user)@\(host)" }
    /// What the list's selection follows.
    public var key: String { user + "\u{0}" + host }

    /// The login methods that take a password. Any other (unix_socket, pam, …) proves who it is some other way.
    static let passwordPlugins: Set = ["", "mysql_native_password", "caching_sha2_password", "sha256_password", "ed25519", "parsec"]
    public var takesPassword: Bool { !isRole && Self.passwordPlugins.contains(plugin) }
}

/// A privilege the server offers, from SHOW PRIVILEGES, so a version's new ones need nothing here.
public struct ServerPrivilege: Hashable, Sendable {
    /// As GRANT writes it: CREATE ROUTINE.
    public var name: String
    /// Where the server says it applies: "Databases,Tables".
    public var context: String
    /// What it allows, in the server's words.
    public var comment: String

    public init(name: String, context: String, comment: String) {
        self.name = name
        self.context = context
        self.comment = comment
    }

    /// How much it can do, for the tree's colours.
    public enum Reach: String, Sendable { case read, write, admin }

    public static func reach(_ name: String) -> Reach {
        if readers.contains(name) { return .read }
        return writers.contains(name) ? .write : .admin
    }

    private static let readers: Set = ["SELECT", "SHOW VIEW", "SHOW DATABASES", "SHOW CREATE ROUTINE", "EXECUTE"]
    private static let writers: Set = ["INSERT", "UPDATE", "DELETE", "DELETE HISTORY", "CREATE", "ALTER", "DROP", "INDEX", "REFERENCES",
                                       "TRIGGER", "EVENT", "CREATE VIEW", "CREATE ROUTINE", "ALTER ROUTINE", "CREATE TEMPORARY TABLES",
                                       "LOCK TABLES"]
}

/// What privileges can be granted on: a level of the privilege tree.
public enum GrantLevel: Hashable, Sendable, Comparable {
    case global
    /// A name as the server keeps it: it may hold wildcards, shop\_%.
    case database(String)
    case table(String, String)
    case column(String, String, String)
    case routine(String, String, isFunction: Bool)

    /// In the tree: *.*, shop.*, shop.orders, shop.orders.id, PROCEDURE shop.total.
    public var title: String {
        switch self {
        case .global: return "Whole server"
        case .database(let database): return "\(database).*"
        case .table(let database, let table): return "\(database).\(table)"
        case .column(let database, let table, let column): return "\(database).\(table).\(column)"
        case .routine(let database, let name, let isFunction): return "\(isFunction ? "FUNCTION" : "PROCEDURE") \(database).\(name)"
        }
    }

    /// What follows ON in GRANT and REVOKE.
    var on: String {
        switch self {
        case .global: return "*.*"
        case .database(let database): return SQLQuote.identifier(database) + ".*"
        case .table(let database, let table), .column(let database, let table, _): return SQLQuote.identifier(database, table)
        case .routine(let database, let name, let isFunction):
            return (isFunction ? "FUNCTION " : "PROCEDURE ") + SQLQuote.identifier(database, name)
        }
    }

    private var rank: Int {
        switch self {
        case .global: return 0
        case .database: return 1
        case .table: return 2
        case .column: return 3
        case .routine: return 4
        }
    }

    public static func < (first: GrantLevel, second: GrantLevel) -> Bool {
        first.rank == second.rank ? first.title < second.title : first.rank < second.rank
    }

    /// What can be granted here, of what the server offers. MySQL and MariaDB file EVENT under the server, but it is a
    /// database's. PROXY and USAGE aren't ticks: one needs a user to act as, the other is no privilege.
    public func offered(_ privileges: [ServerPrivilege]) -> [String] {
        func has(_ privilege: ServerPrivilege, _ words: String...) -> Bool {
            words.contains { privilege.context.localizedCaseInsensitiveContains($0) }
        }
        let names = privileges.filter { privilege in
            guard !["USAGE", "PROXY"].contains(privilege.name) else { return false }
            switch self {
            case .global: return true
            case .database: return privilege.name == "EVENT" || has(privilege, "Databases", "Tables", "Indexes", "Functions")
            case .table: return has(privilege, "Tables", "Indexes")
            case .routine: return has(privilege, "Functions")
            case .column: return ["SELECT", "INSERT", "UPDATE", "REFERENCES"].contains(privilege.name)
            }
        }.map(\.name)
        return names.sorted()
    }
}

/// What an account holds, read from SHOW GRANTS: the one form every version and flavour has, with every level in it.
public struct AccountGrants: Hashable, Sendable {
    public struct Role: Hashable, Sendable {
        public var user: String
        public var host: String
        public var admin: Bool
        public init(user: String, host: String, admin: Bool = false) {
            self.user = user
            self.host = host
            self.admin = admin
        }
    }

    /// Each level with its privileges; GRANT OPTION counts as one of them, as REVOKE treats it.
    public var levels: [GrantLevel: Set<String>] = [:]
    public var roles: [Role] = []
    /// The roles a login starts with, by name.
    public var defaultRoles: Set<String> = []

    public init() {}
}

extension AccountGrants {
    /// Reads SHOW GRANTS' lines. `privileges` says what ALL PRIVILEGES means at each level. What has no tick (PROXY, the
    /// REVOKE lines of MySQL's partial revokes) is skipped: the text under the list still shows it, and nothing here
    /// touches it.
    public init(lines: [String], privileges: [ServerPrivilege], noBackslashEscapes: Bool = false) {
        for line in lines {
            var lexer = SQLLexer(line, noBackslashEscapes: noBackslashEscapes)
            var tokens: [(kind: SQLToken.Kind, text: String)] = []
            var inBrackets = false  // MySQL 5.7 writes a column's name bare there, in its own case
            while let token = lexer.next() {
                let text = lexer.string(token.range)
                if text == "(" || text == ")" { inBrackets = text == "(" }
                tokens.append((token.kind, token.kind == .word && !inBrackets ? lexer.upper(token.range) : text))
            }
            let words = tokens.map(\.text)
            if words.starts(with: ["SET", "DEFAULT", "ROLE"]) {
                defaultRoles.formUnion(tokens.dropFirst(3).prefix { $0.text != "FOR" }.filter { $0.kind != .symbol && $0.kind != .variable }
                    .map { Self.name($0.text) })
            } else if words.first == "GRANT", let to = words.firstIndex(of: "TO") {
                let tail = words[to...]
                if let on = words[..<to].firstIndex(of: "ON") {
                    add(tokens, on: on, to: to, option: tail.containsSequence(["WITH", "GRANT", "OPTION"]), privileges: privileges)
                } else {
                    addRoles(tokens[1..<to].map { $0 }, admin: tail.containsSequence(["WITH", "ADMIN", "OPTION"]))
                }
            }
        }
    }

    private static func name(_ text: String) -> String {
        if text.hasPrefix("'") && text.hasSuffix("'") && text.count >= 2 { return String(text.dropFirst().dropLast()) }
        return SQLQuote.unquoted(text)
    }

    private mutating func addRoles(_ tokens: [(kind: SQLToken.Kind, text: String)], admin: Bool) {
        // `r`, `r`@`%`: the lexer reads @`%` as one variable.
        for part in tokens.split(whereSeparator: { $0.text == "," }) {
            guard let first = part.first else { continue }
            let host = part.dropFirst().first.map { Self.name(String($0.text.drop { $0 == "@" })) } ?? ""
            roles.append(Role(user: Self.name(first.text), host: host, admin: admin))
        }
    }

    private mutating func add(_ tokens: [(kind: SQLToken.Kind, text: String)], on: Int, to: Int, option: Bool, privileges: [ServerPrivilege]) {
        var object = tokens[(on + 1)..<to].map { $0 }
        guard !object.contains(where: { $0.kind == .variable }) else { return }  // PROXY ON ''@'%'
        var routine: Bool?
        if ["PROCEDURE", "FUNCTION"].contains(object.first?.text) { routine = object.removeFirst().text == "FUNCTION" } else
        if object.first?.text == "TABLE" { object.removeFirst() }
        let parts = object.filter { $0.text != "." }.map { Self.name($0.text) }
        let level: GrantLevel
        switch (parts.count, routine) {
        case (2, let routine?): level = .routine(parts[0], parts[1], isFunction: routine)
        case (2, nil) where parts[0] == "*": level = .global
        case (2, nil) where parts[1] == "*": level = .database(parts[0])
        case (2, nil): level = .table(parts[0], parts[1])
        default: return  // what a later version may add
        }
        // SELECT, INSERT (`a`, `b`), SHOW VIEW
        var name: [String] = [], columns: [String]?, inBrackets = false
        func finish(_ grants: inout AccountGrants) {
            let privilege = name.joined(separator: " ")
            name = []
            defer { columns = nil }
            guard !privilege.isEmpty, privilege != "USAGE" else { return }
            if privilege == "ALL" || privilege == "ALL PRIVILEGES" {
                grants.levels[level, default: []].formUnion(level.offered(privileges).filter { $0 != "GRANT OPTION" })
            } else if let columns, case .table(let database, let table) = level {
                for column in columns { grants.levels[.column(database, table, column), default: []].insert(privilege) }
            } else {
                grants.levels[level, default: []].insert(privilege)
            }
        }
        for token in tokens[1..<on] {
            switch token.text {
            case "(": (columns, inBrackets) = ([], true)
            case ")": inBrackets = false
            case "," where !inBrackets: finish(&self)
            case ",": break
            default:
                if inBrackets { columns?.append(Self.name(token.text)) } else { name.append(token.text) }
            }
        }
        finish(&self)
        if option { levels[level, default: []].insert("GRANT OPTION") }
    }
}

private extension ArraySlice where Element == String {
    func containsSequence(_ words: [String]) -> Bool {
        guard count >= words.count else { return false }
        return indices.dropLast(words.count - 1).contains { Array(self[$0..<($0 + words.count)]) == words }
    }
}
