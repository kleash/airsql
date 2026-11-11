import Foundation

/// A MongoDB user or custom role, as usersInfo or rolesInfo gives it (mongo-plan, Phase 4 "users"). Credentials never
/// come with it: showCredentials is never sent.
public struct MongoAccount: Sendable, Equatable {
    public var name: String
    public var database: String
    public var isRole = false
    /// The roles it holds (a user) or inherits (a role).
    public var roles: [MongoRoleName] = []
    /// How a user logs in: SCRAM-SHA-1, SCRAM-SHA-256.
    public var mechanisms: [String] = []
    /// A role's own privileges (resource and actions).
    public var privileges = 0
    /// The server's whole answer about it, for the details under the list.
    public var info = BSONDocument()

    public init(name: String, database: String, isRole: Bool = false) {
        self.name = name
        self.database = database
        self.isRole = isRole
    }

    public var key: String { (isRole ? "role:" : "user:") + database + "." + name }
}

/// A role as a grant names it: its name and the database it is defined in.
public struct MongoRoleName: Sendable, Hashable {
    public var role: String
    public var db: String

    public init(role: String, db: String) {
        self.role = role
        self.db = db
    }

    /// "readWrite on shop".
    public var text: String { role + " on " + db }

    var document: BSONValue { .document(BSONDocument([("role", .string(role)), ("db", .string(db))])) }
}

/// The users commands: create, drop, change a password, grant and revoke roles, drop a custom role. Each comes out as a
/// `MongoAdminCommand`, whose preview shows `pwd` as the command log does (`MongoLog`), and runs only through the
/// person's Run.
public enum MongoUsers {
    public typealias Problem = MongoQueryText.Problem

    /// The built-in roles a grant offers: per database first, then those that only exist in admin.
    public static let builtinRoles = ["read", "readWrite", "dbAdmin", "dbOwner", "userAdmin", "clusterMonitor", "clusterManager",
                                      "clusterAdmin", "hostManager", "backup", "restore", "readAnyDatabase", "readWriteAnyDatabase",
                                      "userAdminAnyDatabase", "dbAdminAnyDatabase", "root"]

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }

    /// The database a user or role is defined in: MongoDB's rules for names (admin is allowed here).
    static func database(_ text: String, field: String = "Database") throws -> String {
        let db = trimmed(text)
        if db.isEmpty || db.utf8.count >= 64 || db.contains(where: { "/\\. \"$*<>:|?\0".contains($0) }) {
            throw Problem(field: field, message: "Type a database name under 64 bytes without spaces or any of / \\ . \" $ * < > : | ?")
        }
        return db
    }

    static func password(_ password: String, _ repeated: String) throws -> String {
        if password.isEmpty { throw Problem(field: "Password", message: "Type a password") }
        if password != repeated { throw Problem(field: "Repeat", message: "The two passwords differ: type the same one twice") }
        return password
    }

    /// createUser in `database`, with one role to start with when `role` is given (on `roleDatabase`, else the user's).
    public static func createUser(database: String, name: String, password: String, repeated: String, role: String = "",
                                  roleDatabase: String = "") throws -> MongoAdminCommand {
        let db = try self.database(database)
        let user = trimmed(name)
        if user.isEmpty || user.contains("\0") { throw Problem(field: "Name", message: "Type the user's name") }
        let pwd = try self.password(password, repeated)
        var roles: [BSONValue] = []
        if !trimmed(role).isEmpty {
            let on = trimmed(roleDatabase).isEmpty ? db : try self.database(roleDatabase, field: "On Database")
            roles.append(MongoRoleName(role: trimmed(role), db: on).document)
        }
        return MongoAdminCommand(command: BSONDocument([("createUser", .string(user)), ("pwd", .string(pwd)), ("roles", .array(roles))]),
                                 database: db)
    }

    /// updateUser with a new password.
    public static func changePassword(_ user: MongoAccount, password: String, repeated: String) throws -> MongoAdminCommand {
        MongoAdminCommand(command: BSONDocument([("updateUser", .string(user.name)), ("pwd", .string(try self.password(password, repeated)))]),
                          database: user.database)
    }

    /// grantRolesToUser: `role` as defined in `database` (empty: the user's).
    public static func grant(_ role: String, on database: String, to user: MongoAccount) throws -> MongoAdminCommand {
        let name = trimmed(role)
        if name.isEmpty { throw Problem(field: "Role", message: "Choose or type the role to grant") }
        let db = trimmed(database).isEmpty ? user.database : try self.database(database, field: "On Database")
        return MongoAdminCommand(command: BSONDocument([("grantRolesToUser", .string(user.name)),
                                                        ("roles", .array([MongoRoleName(role: name, db: db).document]))]),
                                 database: user.database)
    }

    public static func revoke(_ role: MongoRoleName, from user: MongoAccount) -> MongoAdminCommand {
        MongoAdminCommand(command: BSONDocument([("revokeRolesFromUser", .string(user.name)), ("roles", .array([role.document]))]),
                          database: user.database)
    }

    /// dropUser, or dropRole for a custom role.
    public static func drop(_ account: MongoAccount) -> MongoAdminCommand {
        MongoAdminCommand(command: BSONDocument([(account.isRole ? "dropRole" : "dropUser", .string(account.name))]), database: account.database)
    }

    /// What went wrong, in plain words, with `password` (a new one the command carried) never in them.
    public static func failure(_ error: Error, hiding password: String? = nil) -> String {
        guard let error = error as? AirSQLError else { return error.localizedDescription }
        switch error.code {
        case 8000:
            return "MongoDB Atlas doesn't let a database command change users or roles: change them in Atlas's Database "
                + "Access page, or with the Atlas CLI."
        case 13:
            return "This login may not change users or roles there: that takes the userAdmin role on the user's database "
                + "(or userAdminAnyDatabase)."
        case 51003: return "A user of that name already exists in that database."
        case 11: return "That user doesn't exist any more: Refresh to read the list again."
        case 31: return "No role of that name is defined in that database: check the role and its database."
        default:
            // The server's own text, which might echo the command.
            let words = error.localizedDescription
            guard let password, !password.isEmpty else { return words }
            return words.replacingOccurrences(of: password, with: "<secret>")
        }
    }

    // MARK: Reading

    static func accounts(_ reply: BSONDocument, roles: Bool) -> [MongoAccount] {
        guard case .array(let entries)? = reply[roles ? "roles" : "users"] else { return [] }
        return entries.compactMap { entry in
            guard case .document(let info) = entry, case .string(let name)? = info[roles ? "role" : "user"],
                  case .string(let db)? = info["db"] else { return nil }
            var account = MongoAccount(name: name, database: db, isRole: roles)
            if case .array(let held)? = info["roles"] {
                account.roles = held.compactMap { value in
                    guard case .document(let role) = value, case .string(let name)? = role["role"], case .string(let db)? = role["db"]
                    else { return nil }
                    return MongoRoleName(role: name, db: db)
                }
            }
            if case .array(let mechanisms)? = info["mechanisms"] {
                account.mechanisms = mechanisms.compactMap { if case .string(let name) = $0 { return name } else { return nil } }
            }
            if case .array(let privileges)? = info["privileges"] { account.privileges = privileges.count }
            account.info = info
            return account
        }
    }

    /// The users connectionStatus says this session is logged in as.
    static func authenticated(_ reply: BSONDocument) -> [(user: String, db: String)] {
        guard case .document(let auth)? = reply["authInfo"], case .array(let users)? = auth["authenticatedUsers"] else { return [] }
        return users.compactMap { value in
            guard case .document(let user) = value, case .string(let name)? = user["user"], case .string(let db)? = user["db"] else { return nil }
            return (name, db)
        }
    }
}

extension MongoSession {
    /// The server's users and custom roles, and what couldn't be read. usersInfo for every database needs viewUser
    /// everywhere; without it each database is asked on its own, and the login's own user (always visible) is added.
    /// rolesInfo has no such switch, so it goes database by database.
    public func usersAndRoles() async throws -> (accounts: [MongoAccount], problems: [String]) {
        func denied(_ error: Error) -> Bool { (error as? AirSQLError)?.kind == .accessDenied }
        // shortcut: a database without collections isn't listed, so its users (in the fallback) and roles don't show; a
        // listing of admin.system.roles would find them, given the privilege.
        let listed = try await listDatabases().compactMap { if case .string(let name)? = $0["name"] { return name } else { return nil } }
        let databases = ["admin"] + listed.filter { $0 != "admin" && $0 != "local" }
        var users: [MongoAccount] = [], problems: [String] = []
        do {
            users = MongoUsers.accounts(try await command(BSONDocument([("usersInfo", .document(BSONDocument([("forAllDBs", .bool(true))])))]),
                                                          database: "admin"), roles: false)
        } catch where denied(error) {
            var hidden: [String] = []
            for db in databases {
                do { users += MongoUsers.accounts(try await command(BSONDocument([("usersInfo", .int32(1))]), database: db), roles: false) }
                catch where denied(error) { hidden.append(db) }
            }
            let status = try await command(BSONDocument([("connectionStatus", .int32(1))]), database: "admin")
            for me in MongoUsers.authenticated(status) where !users.contains(where: { $0.name == me.user && $0.database == me.db }) {
                let mine = BSONDocument([("user", .string(me.user)), ("db", .string(me.db))])
                users += MongoUsers.accounts(try await command(BSONDocument([("usersInfo", .document(mine))]), database: me.db), roles: false)
            }
            if !hidden.isEmpty {
                problems.append("other users of \(hidden.joined(separator: ", ")) are hidden: seeing them takes viewUser there (the userAdmin role)")
            }
        }
        var roles: [MongoAccount] = [], hidden: [String] = []
        for db in databases {
            do {
                roles += MongoUsers.accounts(try await command(BSONDocument([("rolesInfo", .int32(1)), ("showPrivileges", .bool(true))]),
                                                               database: db), roles: true)
            } catch where denied(error) { hidden.append(db) }
        }
        if !hidden.isEmpty {
            problems.append("custom roles of \(hidden.joined(separator: ", ")) are hidden: seeing them takes viewRole there")
        }
        return (users + roles, problems)
    }
}
