// AirSQL's Docker test lab (testenv/, Compose project airsql-lab) for the tests that run with AIRSQL_LAB=1: its
// servers, hops, logins and files. testenv/AGENT.md describes the same lab for people and agents.
import Foundation
@testable import AirSQLCore

/// The lab as testenv/docker-compose.yml and testenv/seed set it up; with AIRSQL_LAB=1, test.sh in the main checkout
/// starts it (testenv/up.sh) unless it runs. Everything published listens on 127.0.0.1. Lab tests only read the shared
/// databases (`fixture` and `many_tables`): they write in databases of their own, named lane_<x>_*.
enum Lab {
    /// AIRSQL_LAB=1: the lab tests run.
    static let enabled = ProcessInfo.processInfo.environment["AIRSQL_LAB"] == "1"

    enum Flavor: Sendable { case mysql, mariadb }

    /// A database login: a user and its throwaway password.
    struct Login: Sendable, CustomStringConvertible {
        let user: String
        let password: String
        var description: String { user }
    }

    /// On every server: root (for the lab's own setup), airsql (every privilege: what tests use unless they test a login
    /// method) and reader (SELECT and SHOW VIEW on `fixture` only).
    static let root = Login(user: "root", password: "airsql-root")
    static let airsql = Login(user: "airsql", password: "airsql-pass")
    static let reader = Login(user: "reader", password: "reader-pass")
    /// One per login method, on the servers that have it (`Server.logins`), each allowed to read `fixture`.
    static let native = Login(user: "native", password: "native-pass")
    static let sha2 = Login(user: "sha2", password: "sha2-pass")
    static let sha256 = Login(user: "sha256", password: "sha256-pass")
    static let ed25519 = Login(user: "ed25519", password: "ed25519-pass")
    /// MariaDB's PAM plugin, which asks through the client's dialog plugin (cleartext: only over verified TLS).
    static let pam = Login(user: "pam", password: "pam-pass")
    /// REQUIRE X509: the password and the client certificate (`clientCertificate`, `clientKey`).
    static let x509 = Login(user: "x509", password: "x509-pass")

    /// A database server: its Compose service, which is also its host name inside the lab (where it listens on 3306);
    /// what VERSION() starts with; its port on 127.0.0.1, or nil for one only reachable through the bastion, the jump
    /// host or a proxy; and the login-method accounts it has besides root, airsql and reader.
    struct Server: Sendable, CustomStringConvertible {
        let name: String
        let flavor: Flavor
        let version: String
        let port: Int?
        let logins: [Login]
        var description: String { name }
    }

    static let mysql57 = Server(name: "mysql57", flavor: .mysql, version: "5.7.44", port: 44357, logins: [native, sha256])
    static let mysql80 = Server(name: "mysql80", flavor: .mysql, version: "8.0.46", port: 44380, logins: [native, sha2, sha256])
    /// performance_schema on here only (the others save the memory).
    static let mysql84 = Server(name: "mysql84", flavor: .mysql, version: "8.4.13", port: 44384, logins: [native, sha2, sha256])
    static let mysql97 = Server(name: "mysql97", flavor: .mysql, version: "9.7.4", port: 44397, logins: [sha2, sha256])
    static let mariadb105 = Server(name: "mariadb105", flavor: .mariadb, version: "10.5.29", port: 44305, logins: [native, ed25519])
    static let mariadb106 = Server(name: "mariadb106", flavor: .mariadb, version: "10.6.28", port: 44306, logins: [native, ed25519])
    static let mariadb1011 = Server(name: "mariadb1011", flavor: .mariadb, version: "10.11.19", port: 44311,
                                    logins: [native, ed25519])
    static let mariadb114 = Server(name: "mariadb114", flavor: .mariadb, version: "11.4.13", port: 44314, logins: [native, ed25519])
    static let mariadb118 = Server(name: "mariadb118", flavor: .mariadb, version: "11.8.9", port: 44318, logins: [native, ed25519])
    /// The servers on their own ports: every version AirSQL supports.
    static let direct = [mysql57, mysql80, mysql84, mysql97, mariadb105, mariadb106, mariadb1011, mariadb114, mariadb118]

    /// MariaDB 11.4 with the fixture and `many_tables`, a database of `manyTables` tables (t0001…t5000).
    static let many = Server(name: "many", flavor: .mariadb, version: "11.4.13", port: 44350, logins: [native, ed25519])
    static let manyTables = 5_000
    /// mysql84 again, through a relay whose every packet waits 50 ms (tc netem): about 100 ms more per round trip.
    static let slow = Server(name: "slow", flavor: .mysql, version: "8.4.13", port: 44340, logins: mysql84.logins)
    /// mariadb114 again, through ProxySQL: its greeting carries ProxySQL's version, VERSION() the server's. Only airsql
    /// logs in there.
    static let proxySQL = Server(name: "proxysql", flavor: .mariadb, version: "11.4.13", port: 44333, logins: [])

    /// Inside the lab only, reached through the bastion or a proxy. TLS with the lab CA's certificate for the name
    /// "secure" (and no other: checking it against 127.0.0.1 or localhost fails); the PAM and x509 logins.
    static let secure = Server(name: "secure", flavor: .mariadb, version: "11.4.13", port: nil,
                               logins: [native, ed25519, pam, x509])
    /// Inside the lab only, like `secure`, with a certificate from the lab CA for another name (elsewhere.invalid):
    /// checking it as "wrongname" must fail.
    static let wrongName = Server(name: "wrongname", flavor: .mysql, version: "8.4.13", port: nil,
                                  logins: [native, sha2, sha256, x509])
    /// Behind the jump host: the bastion and the proxies can't reach it.
    static let deep = Server(name: "deep", flavor: .mariadb, version: "11.4.13", port: nil, logins: [native, ed25519])

    /// An SSH host: the bastion from the Mac, the jump host from the bastion. Both forward TCP and also take `key`.
    struct SSHHost: Sendable {
        let host: String
        let port: Int
        let user: String
        let password: String
    }

    static let bastion = SSHHost(host: "127.0.0.1", port: 44322, user: "bastion", password: "airsql-bastion")
    static let jump = SSHHost(host: "jump", port: 22, user: "jump", password: "airsql-jump")

    /// A proxy on 127.0.0.1 into the inner network (the bastion, the jump host, secure and wrongname), for ports 22 and
    /// 3306 only.
    struct Proxy: Sendable {
        enum Kind: Sendable { case httpBasic, httpDigest, socks5 }
        let kind: Kind
        let port: Int
        var user: String { "airsql" }
        var password: String { "airsql-proxy" }
    }

    static let httpProxy = Proxy(kind: .httpBasic, port: 44328)
    static let digestProxy = Proxy(kind: .httpDigest, port: 44329)
    static let socksProxy = Proxy(kind: .socks5, port: 44310)

    /// The shared database on every server, and the number of rows in its table `big`.
    static let fixture = "fixture"
    static let bigRows = 1_000_000

    /// The main checkout's testenv/, where up.sh keeps the lab key and the certificates: one lab serves every checkout,
    /// and a worktree's .git is a file naming its folder in the main checkout's .git/worktrees.
    static let testenv: String = {
        var checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let git = (try? String(contentsOf: checkout.appendingPathComponent(".git"), encoding: .utf8)) ?? ""
        if git.hasPrefix("gitdir: ") {  // <main checkout>/.git/worktrees/<name>
            checkout = URL(fileURLWithPath: git.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: checkout)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        return checkout.appendingPathComponent("testenv").path
    }()
    static var key: String { testenv + "/.keys/id_lab" }
    static var caFile: String { testenv + "/.certs/ca.pem" }
    static var clientCertificate: String { testenv + "/.certs/client.pem" }
    static var clientKey: String { testenv + "/.certs/client-key.pem" }

    /// An ssh_config for plain ssh to the lab: `ssh -F Lab.sshConfig lab-bastion`, or `lab-jump` through it. The lab
    /// key, a known_hosts of the tests' own, no agent and no questions: nothing from ~/.ssh.
    static let sshConfig: String = {
        _ = TestEnvironment.isolated
        let path = TestEnvironment.root + "/lab_ssh_config"
        try? """
            Host lab-bastion
              HostName \(bastion.host)
              Port \(bastion.port)
              User \(bastion.user)
            Host lab-jump
              HostName \(jump.host)
              Port \(jump.port)
              User \(jump.user)
              ProxyJump lab-bastion
            Host lab-*
              IdentityFile "\(key)"
              IdentitiesOnly yes
              IdentityAgent none
              UserKnownHostsFile "\(TestEnvironment.root)/lab_known_hosts"
              StrictHostKeyChecking accept-new
              BatchMode yes
              ConnectTimeout 15

            """.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }()

    /// A forward to `server` port 3306 through the bastion (and then the jump host with `throughJump`), ending in a unix
    /// socket: AirSQL's own SSH tunnel (`Tunnel`), logging in with the lab key, its host keys trusted over askpass.
    /// Close it when done. A server the hop can't reach still gets a socket, but each connection to it closes at once.
    static func forward(to server: Server, throughJump: Bool = false) async throws -> Forward {
        var connection = SavedConnection(name: "Lab \(server.name)", host: server.name, port: 3306,
                                         route: throughJump ? .sshJump : .ssh)
        let first = SSHHop(host: bastion.host, port: bastion.port, user: bastion.user, login: .keyFile, keyFile: key)
        if throughJump {
            connection.jumpHosts = [first]
            connection.sshHost = SSHHop(host: jump.host, port: jump.port, user: jump.user, login: .keyFile, keyFile: key)
        } else {
            connection.sshHost = first
        }
        let askpass = try RouteTesting.askpass(for: connection.id)
        do {
            return Forward(tunnel: try await Tunnel.open(connection, askpass: askpass) { _ in }, askpass: askpass)
        } catch {
            askpass.close()
            throw SupportError("the tunnel to \(server.name) didn't start: \(error)")
        }
    }

    /// A running tunnel (Lab.forward).
    final class Forward {
        let socket: String
        private let tunnel: Tunnel
        private let askpass: AskpassServer

        init(tunnel: Tunnel, askpass: AskpassServer) {
            socket = tunnel.socket
            self.tunnel = tunnel
            self.askpass = askpass
        }

        deinit { close() }

        func close() {
            tunnel.close()
            askpass.close()
        }
    }
}
