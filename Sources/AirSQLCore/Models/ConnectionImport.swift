import Foundation

/// Connections from elsewhere: a `mysql://` address, AirSQL's own export file and other apps' saved connections (Sequel
/// Ace, TablePlus, DBeaver, MySQL Workbench, HeidiSQL). Never passwords: AirSQL keeps those in the Keychain and asks at
/// the first connect, and other apps' fields for them are not read.
public enum ConnectionImport {
    /// An app whose saved connections are in a file AirSQL can read.
    public struct Source: Sendable {
        public var title: String
        /// Under the home folder.
        public var path: String
    }

    /// Where the Mac apps keep their connections. HeidiSQL has no Mac app: its exported settings file is chosen by hand.
    public static let sources = [
        Source(title: "Sequel Ace", path: "Library/Containers/com.sequel-ace.sequel-ace/Data/Library/Application Support/Sequel Ace/Data/Favorites.plist"),
        Source(title: "TablePlus", path: "Library/Application Support/com.tinyapp.TablePlus/Data/Connections.plist"),
        Source(title: "DBeaver", path: "Library/DBeaverData/workspace6/General/.dbeaver/data-sources.json"),
        Source(title: "MySQL Workbench", path: "Library/Application Support/MySQL/Workbench/connections.xml"),
    ]

    /// The MySQL and MariaDB connections in a file of AirSQL's or of any of the other apps, by what the file holds.
    public static func connections(in data: Data) -> [SavedConnection] {
        if let own = ownFile(data) { return own }
        let list = try? PropertyListSerialization.propertyList(from: data, format: nil)
        if let list = list as? [[String: Any]] { return tablePlus(list) }
        if let list = list as? [String: Any], list["Favorites Root"] != nil { return sequelAce(list) }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return dbeaver(json) }
        if let text = String(data: data, encoding: .utf8), text.contains("<|||>") { return heidiSQL(text) }
        return workbench(data)
    }

    /// A connection through an SSH host, as other apps give one: the database's host is as the SSH host reaches it.
    private static func tunnelled(_ direct: SavedConnection, ssh host: String, port: Int?, user: String) -> SavedConnection {
        var connection = direct
        connection.route = .ssh
        connection.sshHost = SSHHop(host: host, port: port, user: user)
        if connection.host.isEmpty { connection.host = "127.0.0.1" }
        connection.tls.mode = TLSOptions().mode
        return connection
    }

    /// A number as plists, JSON and text files give one, 0 and nothing being nil.
    private static func number(_ value: Any?) -> Int? {
        let number = (value as? Int) ?? (value as? String).flatMap { Int($0) }
        return number == 0 ? nil : number
    }

    // MARK: Sequel Ace

    /// Favorites.plist: a tree of groups under "Favorites Root". `type` 0 is TCP, 1 a socket, 2 SSH.
    private static func sequelAce(_ list: [String: Any]) -> [SavedConnection] {
        func walk(_ node: [String: Any]) -> [SavedConnection] {
            if let children = node["Children"] as? [[String: Any]] { return children.flatMap(walk) }
            var connection = Self.connection(name: node["name"] as? String ?? "", host: node["host"] as? String ?? "",
                                        port: number(node["port"]), user: node["user"] as? String ?? "",
                                        database: node["database"] as? String ?? "")
            switch number(node["type"]) {
            case 1?:
                connection.socket = node["socket"] as? String ?? ""
                connection.tls.mode = .off
            case 2?:
                connection = tunnelled(connection, ssh: node["sshHost"] as? String ?? "", port: number(node["sshPort"]),
                                       user: node["sshUser"] as? String ?? "")
            default: break
            }
            return [connection]
        }
        return (list["Favorites Root"] as? [String: Any]).map(walk) ?? []
    }

    // MARK: TablePlus

    /// Connections.plist: a list of every driver's connections; only MySQL's and MariaDB's are for AirSQL.
    private static func tablePlus(_ list: [[String: Any]]) -> [SavedConnection] {
        list.compactMap { entry in
            guard let driver = entry["Driver"] as? String, ["mysql", "mariadb"].contains(driver.lowercased()) else { return nil }
            let connection = Self.connection(name: entry["ConnectionName"] as? String ?? "", host: entry["DatabaseHost"] as? String ?? "",
                                        port: number(entry["DatabasePort"]), user: entry["DatabaseUser"] as? String ?? "",
                                        database: entry["DatabaseName"] as? String ?? "")
            guard entry["isOverSSH"] as? Bool == true, let host = entry["ServerAddress"] as? String else { return connection }
            return tunnelled(connection, ssh: host, port: number(entry["ServerPort"]), user: entry["ServerUser"] as? String ?? "")
        }
    }

    // MARK: DBeaver

    /// data-sources.json: every driver's connections by id; the user name is usually in DBeaver's encrypted credentials
    /// file, which stays unread, and then AirSQL asks.
    private static func dbeaver(_ json: [String: Any]) -> [SavedConnection] {
        let entries = (json["connections"] as? [String: [String: Any]] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
        return entries.compactMap { entry in
            guard let provider = entry["provider"] as? String, ["mysql", "mariadb"].contains(provider.lowercased()),
                  let settings = entry["configuration"] as? [String: Any] else { return nil }
            let url = (settings["url"] as? String).flatMap { Self.connection(fromURL: $0.replacingOccurrences(of: "jdbc:", with: "")) }
            guard let host = settings["host"] as? String ?? url?.host else { return nil }
            return Self.connection(name: entry["name"] as? String ?? host, host: host, port: number(settings["port"]) ?? url?.port,
                              user: settings["user"] as? String ?? "", database: settings["database"] as? String ?? url?.database ?? "")
        }
    }

    // MARK: MySQL Workbench

    /// connections.xml: GRT objects of struct db.mgmt.Connection; the passwords are in the Mac's Keychain, not here.
    private static func workbench(_ data: Data) -> [SavedConnection] {
        guard let document = try? XMLDocument(data: data),
              let nodes = try? document.nodes(forXPath: "//value[@struct-name='db.mgmt.Connection']") else { return [] }
        return nodes.compactMap { node in
            guard let element = node as? XMLElement else { return nil }
            func value(_ key: String) -> String {
                ((try? element.nodes(forXPath: ".//value[@key='\(key)']"))?.first?.stringValue ?? "")
            }
            var connection = Self.connection(name: value("name"), host: value("hostName"), port: number(value("port")),
                                        user: value("userName"), database: value("schema"))
            let ssh = value("sshHost")  // "bastion:22"
            if !ssh.isEmpty {
                let parts = ssh.split(separator: ":", maxSplits: 1).map(String.init)
                connection = tunnelled(connection, ssh: parts[0], port: parts.count > 1 ? Int(parts[1]) : nil, user: value("sshUserName"))
            }
            return connection
        }
    }

    // MARK: HeidiSQL

    /// HeidiSQL's exported settings: `Servers\Name\Key<|||>type<|||>value`, one setting a line. NetType 0 to 2 are MySQL's
    /// (TCP, named pipe, SSH tunnel); the rest are other servers'.
    private static func heidiSQL(_ text: String) -> [SavedConnection] {
        var servers: [(name: String, settings: [String: String])] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.components(separatedBy: "<|||>")
            let path = fields[0].components(separatedBy: "\\")
            guard fields.count == 3, path.count >= 3, path[0] == "Servers" else { continue }
            let name = path[1...(path.count - 2)].joined(separator: "/")
            if servers.last?.name != name { servers.append((name, [:])) }
            servers[servers.count - 1].settings[path[path.count - 1]] = fields[2]
        }
        return servers.compactMap { server in
            guard let host = server.settings["Host"], (number(server.settings["NetType"]) ?? 0) <= 2 else { return nil }
            var connection = Self.connection(name: server.name.components(separatedBy: "/").last ?? server.name, host: host,
                                        port: number(server.settings["Port"]), user: server.settings["User"] ?? "",
                                        database: server.settings["Databases"]?.components(separatedBy: ";").first ?? "")
            if number(server.settings["NetType"]) == 2, let ssh = server.settings["SSHtunnelHost"] {
                connection = tunnelled(connection, ssh: ssh, port: number(server.settings["SSHtunnelHostPort"]),
                                       user: server.settings["SSHtunnelUser"] ?? "")
            }
            return connection
        }
    }

    /// `mysql://user@host:3306/shop` (or `mariadb://`), nil when it isn't one. A password in it is left out.
    public static func connection(fromURL text: String) -> SavedConnection? {
        guard let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["mysql", "mariadb"].contains(url.scheme?.lowercased()),
              let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else { return nil }
        return connection(name: host, host: host, port: url.port, user: url.user ?? "",
                          database: url.path.split(separator: "/").first.map(String.init) ?? "")
    }

    /// A connection as other apps describe one. TLS is the strict default, except for a server on this Mac.
    static func connection(name: String, host: String, port: Int?, user: String, database: String) -> SavedConnection {
        var connection = SavedConnection(name: name, host: host, port: port == 3306 ? nil : port, user: user)
        connection.database = database
        if connection.isOnThisMac { connection.tls.mode = .off }
        return connection
    }

    // MARK: AirSQL's own file

    private struct File: Codable {
        var airsql = 1
        var connections: [SavedConnection]
    }

    /// `connections` as AirSQL's export file. Saved connections hold no secrets: those are in the Keychain.
    public static func export(_ connections: [SavedConnection]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(connections: connections))
    }

    /// What an export file holds, as new connections. The file may be someone else's, so what would run by itself is left
    /// out: its programs, its startup SQL and what it lets agents do.
    private static func ownFile(_ data: Data) -> [SavedConnection]? {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return file.connections.map { saved in
            var connection = saved
            connection.id = UUID()
            connection.folderID = nil
            connection.clientPath = ""
            connection.dumpPath = ""
            connection.startupSQL = ""
            connection.agentAccess = .off
            connection.agentSampleRows = false
            return connection
        }
    }
}
