import Foundation

/// The hosts of an ssh_config file the person picked (File ▸ Import from SSH Config…), for making connections that
/// tunnel through them. Only named hosts count: patterns (`*`, `?`, `!`) and Match blocks are settings, not hosts.
public enum SSHConfigImport {
    /// A Host of the file and what it says about itself, for the import list.
    public struct Host: Equatable {
        public var alias: String
        public var hostName: String?
        public var user: String?
        public var port: Int?
        public var proxyJump: String?

        /// "deploy@bastion.example.com:2222 via jump": what the list shows under the name.
        public var summary: String {
            var text = (user.map { $0 + "@" } ?? "") + (hostName ?? alias) + (port.map { ":\($0)" } ?? "")
            if let proxyJump { text += " via " + proxyJump }
            return text
        }
    }

    public static func hosts(in text: String) -> [Host] {
        var hosts: [Host] = [], current: [Int] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // "Keyword value", "Keyword=value" or "Keyword = value".
            let keyEnd = line.firstIndex { $0 == " " || $0 == "\t" || $0 == "=" } ?? line.endIndex
            let keyword = line[..<keyEnd].lowercased()
            var value = line[keyEnd...].drop { $0 == " " || $0 == "\t" || $0 == "=" }.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            switch keyword {
            case "host":
                current = []
                for alias in value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                where !alias.contains(where: { "*?!".contains($0) }) && !hosts.contains(where: { $0.alias == alias }) {
                    hosts.append(Host(alias: alias))
                    current.append(hosts.count - 1)
                }
            case "match":
                current = []
            case "hostname":
                for index in current where hosts[index].hostName == nil { hosts[index].hostName = value }
            case "user":
                for index in current where hosts[index].user == nil { hosts[index].user = value }
            case "port":
                for index in current where hosts[index].port == nil { hosts[index].port = Int(value) }
            case "proxyjump":
                for index in current where hosts[index].proxyJump == nil && value.lowercased() != "none" {
                    hosts[index].proxyJump = value
                }
            default:
                break
            }
        }
        return hosts
    }

    /// A connection that tunnels through `host` by its name, so the file's own settings for it apply (AirSQL's ssh
    /// includes ~/.ssh/config), to a database on the host's own 127.0.0.1:3306.
    public static func connection(for host: Host, folder: UUID?) -> SavedConnection {
        var connection = SavedConnection(name: host.alias, host: "127.0.0.1", route: .ssh)
        connection.folderID = folder
        connection.sshHost = SSHHop(host: host.alias)
        return connection
    }
}
