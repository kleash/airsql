import CryptoKit
import Darwin
import Foundation

/// One SSH server on a connection's route: the SSH host, or a jump host before it. Its password or key passphrase, when
/// remembered, is in the Keychain (`SavedConnection.secretKey(for:)`).
public struct SSHHop: Codable, Hashable, Identifiable {
    /// How ssh logs in. Codes a server asks for besides (2FA) are asked for whichever this is.
    public enum Login: String, Codable, CaseIterable {
        /// What ssh does by itself: ssh-agent's keys, then ~/.ssh's keys and ~/.ssh/config's IdentityFile.
        case agent
        /// This key file only (its passphrase is asked for).
        case keyFile
        /// A password (or keyboard-interactive).
        case password
    }

    public var id = UUID()
    /// A host name or address, or a Host of ~/.ssh/config (whose settings then apply).
    public var host = ""
    /// nil: 22, or what ~/.ssh/config says.
    public var port: Int?
    /// Empty: what ~/.ssh/config says, else this Mac's user name.
    public var user = ""
    public var login = Login.agent
    public var keyFile = ""

    public init(host: String = "", port: Int? = nil, user: String = "", login: Login = .agent, keyFile: String = "") {
        self.host = host
        self.port = port
        self.user = user
        self.login = login
        self.keyFile = keyFile
    }

    /// "deploy@bastion.example.com:2222", for prompts and progress.
    public var displayName: String {
        (user.isEmpty ? "" : user + "@") + host + (port.map { ":\($0)" } ?? "")
    }
}

/// The HTTP CONNECT or SOCKS5 proxy of a route. Its password, when it has a user, is in the Keychain
/// (`SavedConnection.proxySecretKey`).
public struct ProxySettings: Codable, Hashable {
    public enum Kind: String, Codable, CaseIterable {
        case http, socks5

        public var title: String { self == .http ? "HTTP CONNECT" : "SOCKS5" }
        public var defaultPort: Int { self == .http ? 3128 : 1080 }
    }

    public var kind = Kind.socks5
    public var host = ""
    /// nil: the kind's usual port.
    public var port: Int?
    /// Empty: the proxy takes no login.
    public var user = ""

    public init(kind: Kind = .socks5, host: String = "", port: Int? = nil, user: String = "") {
        self.kind = kind
        self.host = host
        self.port = port
        self.user = user
    }
}

extension SavedConnection {
    /// The SSH servers in the order the route reaches them: the jump hosts (SSH through jump hosts or a proxy), then the
    /// SSH host. Empty for Direct and Proxy only.
    public var sshHops: [SSHHop] {
        switch route {
        case .direct, .proxy: return []
        case .ssh: return [sshHost]
        case .sshJump, .sshProxy: return jumpHosts + [sshHost]
        }
    }

    /// The Keychain key of an SSH hop's password or passphrase.
    public func secretKey(for hop: SSHHop) -> String { id.uuidString + " ssh " + hop.id.uuidString }

    /// The Keychain key of the proxy's password.
    public var proxySecretKey: String { id.uuidString + " proxy" }

    /// Every Keychain key this connection may have used (Duplicate copies them, Delete removes them): the database
    /// password's (the id), each hop's and the proxy's.
    public var secretKeys: [String] {
        [id.uuidString] + (jumpHosts + [sshHost]).map(secretKey(for:)) + [proxySecretKey]
    }

    /// Whether the database filter lets `name` show; patterns compare without case.
    public func showsDatabase(_ name: String) -> Bool {
        let patterns = databaseFilter.split { $0 == "," || $0 == ";" || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return patterns.isEmpty || patterns.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
    }

    /// What the driver needs to connect: through the route's socket when there is one (`routeSocket`), else TCP or the
    /// server's own socket (which never leaves this Mac, so without TLS).
    public func connectOptions(password: String, routeSocket: String?) -> ConnectOptions {
        var endpoint = ConnectOptions.Endpoint.tcp, tls = self.tls, host = self.host
        if let routeSocket {
            endpoint = .route(routeSocket)
        } else if !socket.isEmpty {
            endpoint = .socket(socket)
            tls.mode = .off
            if host.isEmpty { host = "localhost" }
        }
        return ConnectOptions(name: displayName, host: host, port: port ?? 3306, endpoint: endpoint, user: user,
                              password: password, database: database.isEmpty ? nil : database, tls: tls,
                              cleartextLogin: cleartextLogin, compress: compress,
                              startupSQL: Self.statements(startupSQL), readOnly: readOnly)
    }

    /// The statements of `text`: split at semicolons outside quotes and comments, comments left out.
    /// shortcut: the console's SQLSplitter (P0-4) replaces this once it is on main.
    static func statements(_ text: String) -> [String] {
        var statements: [String] = [], current = "", quote: Character?
        let characters = Array(text)
        var index = 0
        func flush() {
            let statement = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !statement.isEmpty { statements.append(statement) }
            current = ""
        }
        while index < characters.count {
            let character = characters[index], next = index + 1 < characters.count ? characters[index + 1] : nil
            if let open = quote {
                current.append(character)
                if character == "\\", open != "`", let next {
                    current.append(next)
                    index += 1
                } else if character == open {
                    quote = nil
                }
            } else if character == "'" || character == "\"" || character == "`" {
                quote = character
                current.append(character)
            } else if character == "#" || (character == "-" && next == "-") {
                while index < characters.count, !characters[index].isNewline { index += 1 }
                current.append("\n")
            } else if character == "/", next == "*", index + 2 >= characters.count || characters[index + 2] != "!" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
                index += 1
                current.append(" ")
            } else if character == ";" {
                flush()
            } else {
                current.append(character)
            }
            index += 1
        }
        flush()
        return statements
    }
}

/// Where routes keep their sockets and generated ssh_config files: /tmp/airsql-<uid>, a folder only this user can open
/// (0700, checked). Not Application Support: a Unix socket's whole path must fit in 104 bytes.
public enum RouteFolder {
    public static var path = "/tmp/airsql-\(getuid())"

    /// Makes the folder, or checks that the one there is this user's own and closed to everyone else.
    public static func prepare() throws {
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw AirSQLError(.other, "Can't create \(path): \(String(cString: strerror(errno)))")
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0
        else {
            throw AirSQLError(.other, "\(path) must be a folder only you can open. Remove it, then connect again.")
        }
    }

    /// The start of a connection's file names: short, and different for two AirSQLs with settings folders of their own
    /// (a test run, a copy), so neither takes over the other's socket.
    public static func base(for id: UUID) -> String {
        let digest = SHA256.hash(data: Data((Store.directory.path + "\n" + id.uuidString).utf8))
        return path + "/" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
