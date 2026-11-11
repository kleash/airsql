import Darwin
import Foundation
import Testing
@testable import AirSQLCore

/// Routes without the lab (plan §2.3): the generated ssh_config, startup SQL, the database filter, prompts and ssh's
/// errors; and the real thing through the tests' own sshd and proxies, as CI runs it.
struct RoutesTests {
    private func connection(_ route: Route, hops: Int = 1) -> SavedConnection {
        var connection = SavedConnection(name: "Shop", host: "db.internal", port: 3307, user: "app", route: route)
        connection.sshHost = SSHHop(host: "db-gw.example.com", port: 2222, user: "deploy", login: .keyFile,
                                    keyFile: "~/keys dir/id 100%")
        connection.jumpHosts = (0..<max(0, hops - 1)).map { SSHHop(host: "jump\($0).example.com", user: "j\($0)") }
        return connection
    }

    @Test func configChainsTheHopsAndIncludesTheUsersConfigLast() {
        _ = RouteTesting.prepared  // the include the tunnel tests set, once: it can't change between the two reads below
        var jump = connection(.sshJump, hops: 3)
        jump.jumpHosts[1].login = .password
        let text = SSHConfig.text(for: jump, proxySocket: nil)
        // Only the first hop, reached directly, has a connect timeout: the others' would run while the first one asks.
        #expect(text.contains("Host jump0.example.com\n  User j0\n  ConnectTimeout 15\nHost jump1.example.com\n  User j1\n"
                              + "  PreferredAuthentications keyboard-interactive,password\n  ProxyJump jump0.example.com\n"
                              + "Host db-gw.example.com\n  Port 2222\n  User deploy\n"
                              + "  IdentityFile \"~/keys dir/id 100%%\"\n  IdentitiesOnly yes\n"
                              + "  ProxyJump jump1.example.com\n"), "\(text)")
        #expect(text.contains("  ControlMaster no\n") && text.contains("  ExitOnForwardFailure yes\n")
                && text.contains("  StreamLocalBindUnlink yes\n") && text.contains("  LogLevel VERBOSE\n"))
        #expect(text.hasSuffix("Include " + SSHConfig.value(SSHConfig.include ?? "") + "\n") || SSHConfig.include == nil)
        // SSH + proxy: the first hop through the relay; a plain SSH tunnel ignores jump hosts left in the list.
        let proxied = SSHConfig.text(for: connection(.sshProxy, hops: 2), proxySocket: "/tmp/airsql-1/ab.proxy")
        #expect(proxied.contains("Host jump0.example.com\n  User j0\n  ProxyCommand /usr/bin/nc -U /tmp/airsql-1/ab.proxy\n"))
        #expect(text.components(separatedBy: "ConnectTimeout").count == 2 && !proxied.contains("ConnectTimeout"))
        let plain = SSHConfig.text(for: connection(.ssh, hops: 2), proxySocket: nil)
        #expect(!plain.contains("jump0") && !plain.contains("ProxyJump"))
    }

    @Test func configRefusesWhatSSHWouldMisread() {
        var bad = connection(.ssh)
        #expect(SSHConfig.problem(with: bad) == nil)
        for host in ["", "-oProxyCommand=evil", "two words", "a,b", "quote\"d"] {
            bad.sshHost.host = host
            #expect(SSHConfig.problem(with: bad) != nil, "\(host)")
        }
        #expect(SSHConfig.problem(with: connection(.sshJump, hops: 1)) != nil)  // no jump host
        var twice = connection(.sshJump, hops: 2)
        twice.jumpHosts[0].host = twice.sshHost.host
        #expect(SSHConfig.problem(with: twice) != nil)
        var noKey = connection(.ssh)
        noKey.sshHost.keyFile = ""
        #expect(SSHConfig.problem(with: noKey) != nil)
        // A key path with a quote, newline or control character would inject ssh_config lines; a path with spaces is fine.
        for key in ["~/keys/id\nIdentityFile /etc/evil", "~/keys/id\r", "a\"b", "~/keys/id\u{0}"] {
            var badKey = connection(.ssh)
            badKey.sshHost.keyFile = key
            #expect(SSHConfig.problem(with: badKey) != nil, "\(key.debugDescription)")
        }
    }

    @Test func startupSQLIsSentAStatementAtATime() {
        var connection = SavedConnection(host: "db", user: "app")
        connection.startupSQL = "SET sql_mode = 'ANSI;STRICT';  -- the mode; with a comment\n# another; still one\n"
            + "SET time_zone = '+00:00'"
        #expect(connection.connectOptions(password: "", routeSocket: nil).startupSQL
                == ["SET sql_mode = 'ANSI;STRICT'", "SET time_zone = '+00:00'"])
    }

    @Test func databaseFilterTakesNamesAndPatterns() {
        var connection = SavedConnection()
        #expect(connection.showsDatabase("anything"))
        connection.databaseFilter = "shop, reports_*; Archive?"
        #expect(connection.showsDatabase("shop") && connection.showsDatabase("SHOP") && connection.showsDatabase("reports_2026"))
        #expect(connection.showsDatabase("archive1") && !connection.showsDatabase("archive10") && !connection.showsDatabase("mysql"))
    }

    @Test func connectOptionsUseTheRouteSocketOrTheServersOwn() {
        var local = SavedConnection(name: "Local", user: "root")
        local.socket = "/tmp/mysql.sock"
        local.startupSQL = "SET @a = 1; SET @b = 2"
        let direct = local.connectOptions(password: "p", routeSocket: nil)
        #expect(direct.endpoint == .socket("/tmp/mysql.sock") && direct.tls.mode == .off && direct.host == "localhost")
        #expect(direct.startupSQL == ["SET @a = 1", "SET @b = 2"] && direct.port == 3306 && direct.database == nil)
        let tunnelled = connection(.ssh).connectOptions(password: "p", routeSocket: "/tmp/airsql-1/ab.sock")
        #expect(tunnelled.endpoint == .route("/tmp/airsql-1/ab.sock") && tunnelled.host == "db.internal" && tunnelled.port == 3307)
        #expect(tunnelled.tls.mode == .verifyIdentity)
    }

    @Test func secretKeysCoverEveryHopAndTheProxy() {
        let jump = connection(.sshJump, hops: 3)
        #expect(jump.secretKeys.count == 6 && jump.secretKeys[0] == jump.id.uuidString)
        #expect(Set(jump.secretKeys).count == 6 && jump.secretKeys.contains(jump.secretKey(for: jump.jumpHosts[1])))
    }

    @Test func promptsAreClassified() {
        #expect(Askpass.classify("deploy@db-gw.example.com's password: ") == .password(user: "deploy", host: "db-gw.example.com"))
        #expect(Askpass.classify("(j0@jump0) Password: ") == .password(user: "j0", host: "jump0"))
        #expect(Askpass.classify("Enter passphrase for key '/k/id': ") == .passphrase)
        #expect(Askpass.classify("Verification code: ") == .other)
        let hostKey = Askpass.classify("The authenticity of host '[127.0.0.1]:2222 ([127.0.0.1]:2222)' can't be established.\n"
                                       + "ED25519 key fingerprint is SHA256:abc/def.\nAre you sure you want to continue "
                                       + "connecting (yes/no/[fingerprint])? ")
        #expect(hostKey == .hostKey(host: "[127.0.0.1]:2222", fingerprint: "SHA256:abc/def"))
    }

    @Test func sshErrorsInPlainWords() {
        #expect(ErrorMapping.ssh("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nThe ECDSA host key for "
                                 + "bastion has changed", status: 255).kind == .hostKeyChanged)
        #expect(ErrorMapping.ssh("ssh: Could not resolve hostname nowhere.invalid: nodename nor servname provided",
                                 status: 255).kind == .unknownHost)
        #expect(ErrorMapping.ssh("ssh: connect to host 127.0.0.1 port 1: Connection refused", status: 255).kind == .refused)
        let denied = ErrorMapping.ssh("Authenticated to jump0 ([10.0.0.1]:22) using \"publickey\".\n"
                                      + "deploy@db-gw: Permission denied (publickey,password).", status: 255)
        #expect(denied.kind == .authFailed && denied.message.contains("publickey, password"))
        #expect(!denied.details.contains("Authenticated to"))
        #expect(ErrorMapping.ssh("", status: 255).kind == .other)
    }
}

extension RoutesTests {
    @Test func sshConfigImportListsNamedHostsOnly() {
        let text = """
            # Work
            Host bastion bastion-alias
              HostName bastion.example.com
              User deploy
              Port 2222
            Host db-gw
              HostName=10.20.0.5
              ProxyJump bastion
            Host *.internal !secret
              User nobody
            Match host foo
              User ignored
            Host *
              ServerAliveInterval 30
            Host "quoted"
              hostname quoted.example.com
            """
        let hosts = SSHConfigImport.hosts(in: text)
        #expect(hosts.map(\.alias) == ["bastion", "bastion-alias", "db-gw", "quoted"])
        #expect(hosts[0] == SSHConfigImport.Host(alias: "bastion", hostName: "bastion.example.com", user: "deploy", port: 2222))
        #expect(hosts[2].summary == "10.20.0.5 via bastion" && hosts[3].hostName == "quoted.example.com")
        let made = SSHConfigImport.connection(for: hosts[2], folder: nil)
        #expect(made.route == .ssh && made.sshHost.host == "db-gw" && made.host == "127.0.0.1" && SSHConfig.problem(with: made) == nil)
    }
}

struct LocalServerTests {
    @Test func findsOnlyARealSocket() throws {
        let path = NSTemporaryDirectory() + "as-\(getpid()).sock", plain = path + ".txt"
        FileManager.default.createFile(atPath: plain, contents: Data())
        defer { unlink(path); unlink(plain) }
        #expect(LocalServer.socket(in: ["/nothing/here", plain]) == nil)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { path.utf8CString.withUnsafeBytes($0.copyMemory) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        #expect(LocalServer.socket(in: [plain, path]) == path)
    }
}
