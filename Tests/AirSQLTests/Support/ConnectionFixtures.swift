// A connection with every route setting filled in, for the editor's screens.
import Foundation
@testable import AirSQLCore

extension Fixtures {
    /// Production through a SOCKS5 proxy, a jump host and an SSH host, with TLS pinned and every option set; with
    /// `long`, names as long as people make them.
    static func routed(long: Bool = false) -> SavedConnection {
        let stretch = long ? "-primary-analytics-warehouse-0001" : ""
        var connection = Fixtures.production
        connection.route = .sshProxy
        connection.host = "10.20.0.15" + (long ? ".internal-reporting-network.example.com" : "")
        connection.port = 3306
        connection.database = "shop" + stretch
        connection.comment = long ? String(repeating: "Ask the data team before changing anything. ", count: 5) : "Orders and customers"
        connection.proxy = ProxySettings(kind: .socks5, host: "proxy.example.com" + (long ? ".corp-office-network" : ""),
                                         port: 1080, user: "office")
        connection.jumpHosts = [SSHHop(host: "bastion" + stretch + ".example.com", user: "deploy", login: .agent)]
        connection.sshHost = SSHHop(host: "db-gw" + stretch + ".internal.example", port: 22, user: "deploy", login: .keyFile,
                                    keyFile: "~/.ssh/id_ed25519" + (long ? "_for_the_production_database_gateway" : ""))
        connection.tls = TLSOptions(mode: .verifyIdentity, caFile: "~/certs/example-ca.pem",
                                    pinnedFingerprint: "9F:2C:41:7A:0B:E3:55:D8:6C:11:AF:30:72:9E:C4:5B:08:DD:3A:61:F7:24:9C:B0:13:6E:85:C2:4F:70:A9:1D")
        connection.startupSQL = "SET time_zone = '+00:00';\nSET SESSION sql_mode = 'STRICT_ALL_TABLES';"
        connection.databaseFilter = "shop, reports_*"
        connection.queryTimeout = 600
        connection.compress = true
        connection.safety = .production
        return connection
    }
}
