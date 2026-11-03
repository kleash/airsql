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
                                    keyFile: "/Users/someone/keys dir/id 100%")
        connection.jumpHosts = (0..<max(0, hops - 1)).map { SSHHop(host: "jump\($0).example.com", user: "j\($0)") }
        return connection
    }

    @Test func configChainsTheHopsAndIncludesTheUsersConfigLast() {
        var jump = connection(.sshJump, hops: 3)
        jump.jumpHosts[1].login = .password
        let text = SSHConfig.text(for: jump, proxySocket: nil)
        #expect(text.contains("Host jump0.example.com\n  User j0\nHost jump1.example.com\n  User j1\n"
                              + "  PreferredAuthentications keyboard-interactive,password\n  ProxyJump jump0.example.com\n"
                              + "Host db-gw.example.com\n  Port 2222\n  User deploy\n"
                              + "  IdentityFile \"/Users/someone/keys dir/id 100%%\"\n  IdentitiesOnly yes\n"
                              + "  ProxyJump jump1.example.com\n"), "\(text)")
        #expect(text.contains("  ControlMaster no\n") && text.contains("  ExitOnForwardFailure yes\n")
                && text.contains("  StreamLocalBindUnlink yes\n") && text.contains("  LogLevel VERBOSE\n"))
        #expect(text.hasSuffix("Include " + SSHConfig.value(SSHConfig.include ?? "") + "\n") || SSHConfig.include == nil)
        // SSH + proxy: the first hop through the relay; a plain SSH tunnel ignores jump hosts left in the list.
        let proxied = SSHConfig.text(for: connection(.sshProxy, hops: 2), proxySocket: "/tmp/airsql-1/ab.proxy")
        #expect(proxied.contains("Host jump0.example.com\n  User j0\n  ProxyCommand /usr/bin/nc -U /tmp/airsql-1/ab.proxy\n"))
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
    }

    @Test func startupSQLSplitsAtSemicolonsOutsideQuotesAndComments() {
        let text = """
            SET sql_mode = 'ANSI;STRICT';  -- the mode; with a comment
            # a whole-line comment; still one
            SET @a = "x;y", @b = `odd;name`; /* block; comment */ SET time_zone = '+00:00';
            /*!50700 SET SESSION max_execution_time = 1000 */;
            SET @c = 'it\\'s; fine';
            """
        #expect(SavedConnection.statements(text) == [
            "SET sql_mode = 'ANSI;STRICT'", "SET @a = \"x;y\", @b = `odd;name`", "SET time_zone = '+00:00'",
            "/*!50700 SET SESSION max_execution_time = 1000 */", "SET @c = 'it\\'s; fine'",
        ])
        #expect(SavedConnection.statements("  ;; -- nothing\n").isEmpty)
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
        #expect(jump.secretKeys.count == 5 && jump.secretKeys[0] == jump.id.uuidString)
        #expect(Set(jump.secretKeys).count == 5 && jump.secretKeys.contains(jump.secretKey(for: jump.jumpHosts[1])))
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
