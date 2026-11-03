import Darwin
import Foundation
import Testing
@testable import AirSQLCore

/// The routes for real, without Docker (as CI runs them): the proxy relay through the tests' HTTP and SOCKS5 proxies,
/// and tunnels through the tests' own sshd, with prompts answered over askpass by the debug AirSQL. The "database" at
/// the far end is the sshd itself, whose banner comes back through the route's socket.
struct TunnelTests {
    private func banner(_ socket: String) -> String {
        let fd = connectUnix(socket)
        defer { close(fd) }
        return String(decoding: receive(fd, through: "\n"), as: UTF8.self)
    }

    @Test func relayGoesThroughEveryKindOfProxy() async throws {
        try await withServer { server in
            let basic = try TestProxy(user: "u", password: "p")
            let digest = try TestProxy(user: "u", password: "p", digest: "SHA-256", staleOnce: true)
            let socks = try TestSOCKS(user: "u", password: "p")
            let open = try TestSOCKS()
            defer {
                basic.stop()
                digest.stop()
                socks.stop()
                open.stop()
            }
            let proxies = [ProxySettings(kind: .http, host: "127.0.0.1", port: basic.port, user: "u"),
                           ProxySettings(kind: .http, host: "127.0.0.1", port: digest.port, user: "u"),
                           ProxySettings(kind: .socks5, host: "127.0.0.1", port: socks.port, user: "u"),
                           ProxySettings(kind: .socks5, host: "127.0.0.1", port: open.port)]
            for proxy in proxies {
                let relay = try ProxyRelay(socket: try scratch() + "/r.sock", proxy: proxy, password: "p", host: "127.0.0.1",
                                           port: server.port)
                defer { relay.close() }
                #expect(banner(relay.socket).hasPrefix("SSH-2.0-"), "\(proxy)")
                #expect(banner(relay.socket).hasPrefix("SSH-2.0-"), "\(proxy): a second connection")
            }
            #expect(digest.logins.allSatisfy { $0.contains("Proxy-Authorization: Digest ") } && digest.logins.count >= 2)

            // A wrong password: the connection closes, and the relay says why.
            for proxy in [proxies[0], proxies[2]] {
                let relay = try ProxyRelay(socket: try scratch() + "/r.sock", proxy: proxy, password: "wrong", host: "127.0.0.1",
                                           port: server.port)
                defer { relay.close() }
                #expect(banner(relay.socket).isEmpty)
                #expect(relay.lastError?.kind == .authFailed, "\(String(describing: relay.lastError))")
            }
            var info = stat()
            let relay = try ProxyRelay(socket: try scratch() + "/r.sock", proxy: proxies[3], password: "", host: "127.0.0.1",
                                       port: server.port)
            #expect(lstat(relay.socket, &info) == 0 && info.st_mode & 0o777 == 0o600)
            relay.close()
            #expect(lstat(relay.socket, &info) != 0)
        }
    }

    /// One hop with a key, the host key trusted over askpass; then two hops (the sshd as its own jump host, by another
    /// name), progress hop by hop; then the first hop through a proxy.
    @Test func tunnelsReachTheDatabaseOverEachSSHRoute() async throws {
        _ = RouteTesting.prepared
        try await withServer { server in
            var connection = SavedConnection(name: "Tunnel", host: "127.0.0.1", port: server.port, user: "app", route: .ssh)
            connection.sshHost = SSHHop(host: "127.0.0.1", port: server.port, user: NSUserName(), login: .keyFile,
                                        keyFile: server.plainKey)
            let prompts = Recorder<String>(), steps = Recorder<String>()
            let askpass = try RouteTesting.askpass(for: connection.id, prompts: prompts)
            defer { askpass.close() }
            let tunnel = try await Tunnel.open(connection, askpass: askpass) { steps.append($0) }
            #expect(banner(tunnel.socket).hasPrefix("SSH-2.0-"))
            #expect(prompts.all.contains { $0.contains("continue connecting") }, "\(prompts.all)")
            #expect(steps.all.first == "SSH to \(NSUserName())@127.0.0.1:\(server.port) (1 of 1)")
            tunnel.close()
            #expect(await eventually(timeout: 10) { !FileManager.default.fileExists(atPath: tunnel.socket) })

            connection.route = .sshJump
            connection.jumpHosts = [connection.sshHost]
            connection.jumpHosts[0].id = UUID()
            connection.sshHost.host = "localhost"
            let chain = try await Tunnel.open(connection, askpass: askpass) { steps.append($0) }
            #expect(banner(chain.socket).hasPrefix("SSH-2.0-"))
            #expect(steps.all.contains("SSH to \(NSUserName())@localhost:\(server.port) (2 of 2)"), "\(steps.all)")
            let dropped = Recorder<AirSQLError>()
            chain.onExit = { dropped.append($0) }
            chain.close()
            try? await Task.sleep(nanoseconds: 500_000_000)
            #expect(dropped.all.isEmpty)  // closing isn't dropping

            let proxy = try TestProxy()
            defer { proxy.stop() }
            connection.route = .sshProxy
            connection.proxy = ProxySettings(kind: .http, host: "127.0.0.1", port: proxy.port)
            let relay = try ProxyRelay(socket: RouteFolder.base(for: connection.id) + ".proxy", proxy: connection.proxy,
                                       password: "", host: "127.0.0.1", port: server.port)
            defer { relay.close() }
            let proxied = try await Tunnel.open(connection, askpass: askpass, proxySocket: relay.socket) { _ in }
            #expect(banner(proxied.socket).hasPrefix("SSH-2.0-"))
            #expect(proxy.requests.all.contains { $0.hasPrefix("CONNECT 127.0.0.1:\(server.port) ") })
            proxied.close()
        }
    }

    /// A tunnel that can't log in says why; one whose ssh dies after it was up reports the drop.
    @Test func tunnelFailuresAreExplained() async throws {
        _ = RouteTesting.prepared
        try await withServer { server in
            var connection = SavedConnection(name: "Tunnel", host: "127.0.0.1", port: server.port, user: "app", route: .ssh)
            connection.sshHost = SSHHop(host: "127.0.0.1", port: server.port, user: NSUserName(), login: .keyFile,
                                        keyFile: server.encryptedKey)
            // The passphrase isn't known: askpass cancels each time, and ssh gives up.
            let askpass = try RouteTesting.askpass(for: connection.id)
            defer { askpass.close() }
            await #expect(throws: AirSQLError.self) { try await Tunnel.open(connection, askpass: askpass) { _ in } }
            do {
                _ = try await Tunnel.open(connection, askpass: askpass) { _ in }
            } catch let error as AirSQLError {
                #expect(error.kind == .authFailed, "\(error.message) \(error.details)")
            }
            // With the passphrase it logs in; then sshd goes away.
            let knowing = try RouteTesting.askpass(for: connection.id, secrets: ["passphrase": TestServer.passphrase])
            defer { knowing.close() }
            let tunnel = try await Tunnel.open(connection, askpass: knowing) { _ in }
            let dropped = Recorder<AirSQLError>()
            tunnel.onExit = { dropped.append($0) }
            await server.shutdown()
            #expect(await eventually(timeout: 60) { !dropped.all.isEmpty })
            #expect(dropped.all.first?.kind == .disconnected)
            tunnel.close()
        }
    }
}
