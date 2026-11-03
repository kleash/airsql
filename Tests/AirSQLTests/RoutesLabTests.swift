import Foundation
import Testing
@testable import AirSQLCore

/// Every route in the lab (AIRSQL_LAB=1; testenv/AGENT.md): an SSH tunnel through the bastion with its password, the jump
/// chain to `deep`, SSH through each proxy, each proxy alone, ProxySQL and the slow path; TLS checked against the real
/// host name at the far end of each, and refused for the wrong name.
@Suite(.enabled(if: Lab.enabled)) struct RoutesLabTests {
    /// A connection to `server` (its name inside the lab) through `route`, the bastion as the SSH host.
    private func connection(to server: Lab.Server, route: Route, login: Lab.Login = Lab.airsql,
                            tls: TLSOptions = TLSOptions(mode: .verifyIdentity, caFile: Lab.caFile)) -> SavedConnection {
        var connection = SavedConnection(name: "Lab", host: server.name, port: 3306, user: login.user, route: route)
        connection.tls = tls
        connection.sshHost = SSHHop(host: Lab.bastion.host, port: Lab.bastion.port, user: Lab.bastion.user, login: .keyFile,
                                    keyFile: Lab.key)
        return connection
    }

    private func proxySettings(_ proxy: Lab.Proxy) -> ProxySettings {
        ProxySettings(kind: proxy.kind == .socks5 ? .socks5 : .http, host: "127.0.0.1", port: proxy.port, user: proxy.user)
    }

    /// Opens `connection`'s route and logs in: what Connect does, without its prompts (`secrets` answer ssh's).
    private func connect(_ connection: SavedConnection, password: String = Lab.airsql.password, proxyPassword: String = "",
                         secrets: [String: String] = [:], steps: Recorder<String>? = nil)
        async throws -> (route: OpenRoute, connection: Connection, server: ServerInfo) {
        let askpass = try RouteTesting.askpass(for: connection.id, secrets: secrets)
        defer { askpass.close() }
        let route = try await OpenRoute.open(connection, proxyPassword: proxyPassword, askpass: { askpass }) { steps?.append($0) }
        let session = Connection(options: connection.connectOptions(password: password, routeSocket: route.socket))
        do {
            return (route, session, try await session.connect())
        } catch {
            route.close()
            throw route.relay?.lastError ?? error
        }
    }

    private func value(_ connection: Connection, _ sql: String) async throws -> String? {
        try await connection.session(.main).query(sql).first?.rows?.string(0, 0)
    }

    @Test func sshTunnelThroughTheBastionLogsInWithItsPassword() async throws {
        var tunnel = connection(to: Lab.secure, route: .ssh)
        tunnel.sshHost.login = .password
        let (route, session, server) = try await connect(tunnel, secrets: [Lab.bastion.host: Lab.bastion.password])
        #expect(server.flavor == .mariadb && server.version.hasPrefix(Lab.secure.version) && server.tls != nil)
        #expect(try await value(session, "SELECT @@hostname") != nil)
        await session.disconnect()
        route.close()
        #expect(!FileManager.default.fileExists(atPath: route.socket ?? ""))
    }

    @Test func jumpChainReachesTheServerBehindTheJumpHost() async throws {
        var chain = connection(to: Lab.deep, route: .sshJump, tls: TLSOptions(mode: .off))
        chain.jumpHosts = [chain.sshHost]
        chain.sshHost = SSHHop(host: Lab.jump.host, port: Lab.jump.port, user: Lab.jump.user, login: .password)
        let steps = Recorder<String>()
        let (route, session, server) = try await connect(chain, secrets: [Lab.jump.host: Lab.jump.password], steps: steps)
        #expect(server.version.hasPrefix(Lab.deep.version))
        #expect(steps.all.contains("SSH to \(Lab.jump.user)@\(Lab.jump.host):22 (2 of 2)"), "\(steps.all)")
        await session.disconnect()
        route.close()
    }

    @Test(arguments: [Lab.httpProxy, Lab.digestProxy, Lab.socksProxy])
    func sshThroughEachProxy(_ proxy: Lab.Proxy) async throws {
        var proxied = connection(to: Lab.secure, route: .sshProxy)
        proxied.sshHost.host = "bastion"  // as the proxy reaches it
        proxied.sshHost.port = 22
        proxied.proxy = proxySettings(proxy)
        let (route, session, server) = try await connect(proxied, proxyPassword: proxy.password)
        #expect(server.version.hasPrefix(Lab.secure.version) && server.tls != nil)
        await session.disconnect()
        route.close()
    }

    @Test(arguments: [Lab.httpProxy, Lab.digestProxy, Lab.socksProxy])
    func eachProxyAloneReachesTheDatabase(_ proxy: Lab.Proxy) async throws {
        var proxied = connection(to: Lab.secure, route: .proxy)
        proxied.proxy = proxySettings(proxy)
        let (route, session, server) = try await connect(proxied, proxyPassword: proxy.password)
        #expect(server.version.hasPrefix(Lab.secure.version) && server.tls != nil)
        await session.disconnect()
        route.close()
        // A wrong proxy password is reported as the proxy's.
        do {
            _ = try await connect(proxied, proxyPassword: "wrong")
            Issue.record("logged in through \(proxy.kind) with a wrong proxy password")
        } catch let error as AirSQLError {
            #expect(error.kind == .authFailed && error.message.contains("proxy"), "\(error.message)")
        }
    }

    /// A PAM account logs in with the dialog plugin, its password in plain text: only over TLS that proves the server.
    @Test func pamLogsInOnlyOverVerifiedTLS() async throws {
        var pam = connection(to: Lab.secure, route: .ssh, login: Lab.pam)
        pam.cleartextLogin = true
        let (route, session, _) = try await connect(pam, password: Lab.pam.password)
        #expect(try await value(session, "SELECT CURRENT_USER()")?.hasPrefix("pam@") == true)
        await session.disconnect()
        route.close()
        pam.tls = TLSOptions(mode: .required)
        do {
            _ = try await connect(pam, password: Lab.pam.password)
            Issue.record("a PAM login went over TLS that doesn't prove the server")
        } catch let error as AirSQLError {
            #expect(error.kind == .loginMethodNotAllowed, "\(error.message)")
        }
    }

    /// wrongname's certificate is for another name: refused through the tunnel and through a proxy, as it would be
    /// directly.
    @Test func theWrongNameIsRefusedOnEveryRoute() async throws {
        var proxied = connection(to: Lab.wrongName, route: .proxy)
        proxied.proxy = proxySettings(Lab.socksProxy)
        for wrong in [connection(to: Lab.wrongName, route: .ssh), proxied] {
            do {
                _ = try await connect(wrong, proxyPassword: Lab.socksProxy.password)
                Issue.record("\(wrong.route) to wrongname logged in")
            } catch let error as AirSQLError {
                guard case .untrustedCertificate = error.kind else {
                    Issue.record("\(wrong.route): \(error.kind) \(error.message)")
                    continue
                }
            }
        }
    }

    /// A tunnel that drops takes the session with it, reported and never re-made silently; once the route is open again
    /// (the same socket), Reconnect logs in anew and says the open transaction was rolled back.
    @Test func reconnectWorksThroughANewTunnelAfterADrop() async throws {
        let tunnelled = connection(to: Lab.secure, route: .ssh)
        let askpass = try RouteTesting.askpass(for: tunnelled.id)
        defer { askpass.close() }
        let route = try await OpenRoute.open(tunnelled, proxyPassword: "", askpass: { askpass }) { _ in }
        let session = DBConnection(options: tunnelled.connectOptions(password: Lab.airsql.password, routeSocket: route.socket),
                                   role: .main)
        let old = try await session.connect().threadID
        _ = try await session.query("START TRANSACTION")
        route.close()
        func failure() async -> AirSQLError.Kind? {
            do {
                _ = try await session.query("SELECT 1")
                return nil
            } catch {
                return (error as? AirSQLError)?.kind
            }
        }
        #expect(await failure() == .disconnected)
        #expect(await failure() == .disconnected, "no silent reconnect")
        let again = try await OpenRoute.open(tunnelled, proxyPassword: "", askpass: { askpass }) { _ in }
        #expect(again.socket == route.socket)
        let report = try await session.reconnect()
        #expect(report.rolledBack && report.server.threadID != old && !session.inTransaction)
        await session.close()
        again.close()
    }

    /// ProxySQL answers for mariadb114; the slow path stretches every round trip, and the query timeout stops a long
    /// statement there.
    @Test func proxySQLAndTheSlowPath() async throws {
        let viaProxySQL = SavedConnection(name: "ProxySQL", host: "127.0.0.1", port: Lab.proxySQL.port, user: Lab.airsql.user)
        var plain = viaProxySQL
        plain.tls.mode = .off
        let (route, session, server) = try await connect(plain)
        #expect(try await value(session, "SELECT VERSION()")?.hasPrefix(Lab.proxySQL.version) == true, "\(server.version)")
        await session.disconnect()
        route.close()

        var slow = SavedConnection(name: "Slow", host: "127.0.0.1", port: Lab.slow.port, user: Lab.airsql.user)
        slow.tls.mode = .required
        let (slowRoute, slowSession, _) = try await connect(slow)
        let main = try await slowSession.session(.main)
        let started = Date()
        do {
            _ = try await main.query("SELECT SLEEP(5)", timeout: 1)
            Issue.record("SLEEP(5) wasn't stopped by a 1 s query timeout")
        } catch let error as AirSQLError {
            #expect(error.kind == .cancelled && error.message.contains("query timeout"), "\(error.message)")
        }
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(try await value(slowSession, "SELECT 1") == "1")
        await slowSession.keepAlive(transactionLimit: 60)
        #expect(main.isConnected)
        await slowSession.disconnect()
        slowRoute.close()
    }
}
