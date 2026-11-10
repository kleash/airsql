import Foundation

/// A MongoDB connection string (mongodb:// or mongodb+srv://) taken apart and put back together: what the editor's
/// Paste URI reads into a saved connection, and what `MongoConnection` connects with. User and password are percent
/// decoded here; the password never goes into a `SavedConnection` (the Keychain keeps it).
public struct MongoURI: Sendable {
    public var srv = false
    /// "host", "host:port", "[::1]:27017": as the string writes them.
    public var hosts: [String] = []
    public var user: String?
    public var password: String?
    public var database = ""
    /// The options in order, values decoded; the driver reads keys in any case.
    public var options: [(key: String, value: String)] = []

    public init() {}

    public init(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest: Substring
        if text.lowercased().hasPrefix("mongodb://") {
            rest = text.dropFirst(10)
        } else if text.lowercased().hasPrefix("mongodb+srv://") {
            srv = true
            rest = text.dropFirst(14)
        } else {
            throw Self.error("A MongoDB connection string starts with mongodb:// or mongodb+srv://.")
        }
        var query: Substring = ""
        if let mark = rest.firstIndex(of: "?") {
            query = rest[rest.index(after: mark)...]
            rest = rest[..<mark]
        }
        if let slash = rest.firstIndex(of: "/") {
            database = try Self.decode(rest[rest.index(after: slash)...])
            rest = rest[..<slash]
        }
        // The last @: a password may hold one its writer didn't encode.
        if let at = rest.lastIndex(of: "@") {
            let login = rest[..<at].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            user = try Self.decode(login[0])
            if login.count == 2 { password = try Self.decode(login[1]) }
            rest = rest[rest.index(after: at)...]
        }
        hosts = rest.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        for host in hosts where Self.split(host) == nil {
            throw Self.error(host.isEmpty ? "The connection string names no server." : "“\(host)” isn't a server and port.")
        }
        if srv, hosts.count != 1 || Self.split(hosts[0])?.port != nil {
            throw Self.error("A mongodb+srv:// string names one host name, without a port.")
        }
        for pair in query.split(whereSeparator: { $0 == "&" || $0 == ";" }) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { throw Self.error("The option “\(pair)” has no value.") }
            options.append((try Self.decode(parts[0]), try Self.decode(parts[1])))
        }
    }

    /// The string, user and password percent encoded.
    public var string: String {
        var text = srv ? "mongodb+srv://" : "mongodb://"
        if let user { text += Self.encode(user) + (password.map { ":" + Self.encode($0) } ?? "") + "@" }
        text += hosts.joined(separator: ",") + "/" + Self.encode(database)
        if !options.isEmpty { text += "?" + Self.query(options) }
        return text
    }

    /// Options as a connection string writes them after its "?".
    static func query(_ options: [(key: String, value: String)]) -> String {
        options.map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&")
    }

    /// The last value of an option, whatever the case of its key.
    public func option(_ key: String) -> String? {
        options.last { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// Sets an option (nil removes it), replacing it in any case.
    public mutating func setOption(_ key: String, _ value: String?) {
        options.removeAll { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        if let value { options.append((key, value)) }
    }

    /// "host:port" as host and port; an IPv6 address in brackets loses them. nil: not a host.
    public static func split(_ server: String) -> (host: String, port: Int?)? {
        var host = Substring(server), port: Substring?
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let after = host[host.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                port = after.dropFirst()
            }
            host = host[host.index(after: host.startIndex)..<close]
        } else if let colon = host.lastIndex(of: ":") {
            port = host[host.index(after: colon)...]
            host = host[..<colon]
        }
        guard !host.isEmpty, !host.contains("/") else { return nil }
        guard let port else { return (String(host), nil) }
        guard let number = Int(port), (1...65535).contains(number) else { return nil }
        return (String(host), number)
    }

    /// host:port as a connection string writes it: an IPv6 address in brackets.
    public static func join(_ host: String, _ port: Int?) -> String {
        (host.contains(":") ? "[\(host)]" : host) + (port.map { ":\($0)" } ?? "")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text }

    private static func decode(_ text: Substring) throws -> String {
        guard let decoded = String(text).removingPercentEncoding else { throw error("“\(text)” has a bad % code.") }
        return decoded
    }

    private static func error(_ message: String) -> AirSQLError { AirSQLError(.other, message) }
}

extension SavedConnection {
    /// Fills the server's fields from a connection string (the editor's Paste URI): servers, user, database, TLS and
    /// the options; returns its password, for the Keychain (never kept here).
    public mutating func apply(_ uri: MongoURI) -> String? {
        let first = uri.hosts.first.flatMap(MongoURI.split)
        host = first?.host ?? ""
        port = first?.port
        mongoHosts = Array(uri.hosts.dropFirst())
        mongoSRV = uri.srv
        user = uri.user ?? ""
        database = uri.database
        authSource = ""
        replicaSet = ""
        directConnection = false
        mongoX509 = false
        var useTLS = uri.srv, invalidCertificates = false, invalidHostnames = false, caFile: String?, certFile: String?
        var rest: [(key: String, value: String)] = []
        for (key, value) in uri.options {
            let on = value.lowercased() == "true"
            switch key.lowercased() {
            case "authsource": authSource = value
            case "replicaset": replicaSet = value
            case "directconnection": directConnection = on
            case "tls", "ssl": useTLS = on
            case "tlsinsecure", "tlsallowinvalidcertificates": invalidCertificates = on
            case "tlsallowinvalidhostnames": invalidHostnames = on
            case "tlscafile": caFile = value
            case "tlscertificatekeyfile": certFile = value
            case "authmechanism" where value.uppercased() == "MONGODB-X509": mongoX509 = true
            default: rest.append((key, value))
            }
        }
        tls = TLSOptions(mode: !useTLS ? .off : invalidCertificates ? .required : invalidHostnames ? .verifyCA : .verifyIdentity,
                         caFile: caFile, certFile: certFile)
        mongoOptions = MongoURI.query(rest)
        return uri.password
    }

    /// The connection string AirSQL connects with, without user or password (`MongoConnection` adds them in memory).
    /// TLS is only switched on here: `TLSCheck` checks each server's certificate.
    public var mongoURI: MongoURI {
        var uri = MongoURI()
        uri.srv = mongoSRV
        uri.hosts = [MongoURI.join(host, mongoSRV ? nil : port)] + mongoHosts
        uri.database = database
        if tls.mode != .off || mongoSRV { uri.options.append(("tls", tls.mode != .off ? "true" : "false")) }
        if mongoX509 { uri.options.append(("authMechanism", "MONGODB-X509")) }
        if !authSource.isEmpty && !mongoX509 { uri.options.append(("authSource", authSource)) }  // X.509's is $external
        if !replicaSet.isEmpty { uri.options.append(("replicaSet", replicaSet)) }
        if directConnection { uri.options.append(("directConnection", "true")) }
        uri.options += (try? MongoURI("mongodb://x/?" + mongoOptions))?.options ?? []
        // A dead member costs this on each scan of the servers (mongo-plan, Phase 0): the driver's 10 s is long.
        if uri.option("connectTimeoutMS") == nil { uri.options.append(("connectTimeoutMS", "5000")) }
        return uri
    }
}
