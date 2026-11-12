import Foundation

/// A connection's route, open (plan §2.3): its private socket, and what keeps it there: ssh (SSH routes), the proxy
/// relay (Proxy only), or both (SSH + proxy, where ssh reaches its first hop through the relay). Direct has none.
public struct OpenRoute {
    public let tunnel: Tunnel?
    public let relay: ProxyRelay?

    /// Where the driver, the client tools and Terminal connect; nil for Direct.
    public var socket: String? { tunnel?.socket ?? relay?.socket }

    public func close() {
        tunnel?.close()
        relay?.close()
    }

    /// Opens `saved`'s route. `proxyPassword`: the proxy's ("" without a user); `askpass`: where ssh's prompts go
    /// (SSH routes only). `progress` gets each step ("Proxy …", "SSH to … (1 of 2)"). A proxy's failure is reported in
    /// its own words: ssh only sees the connection close.
    public static func open(_ saved: SavedConnection, proxyPassword: String, askpass: () throws -> AskpassServer,
                            progress: @escaping (String) -> Void) async throws -> OpenRoute {
        guard saved.route != .direct else { return OpenRoute(tunnel: nil, relay: nil) }
        if saved.route == .proxy || saved.route == .sshProxy, saved.proxy.host.trimmingCharacters(in: .whitespaces).isEmpty {
            throw AirSQLError(.other, "Type the proxy's address in the SSH and Proxy tab.")
        }
        let base = RouteFolder.base(for: saved.id)
        if saved.route == .proxy {
            progress("Proxy \(saved.proxy.host)")
            return OpenRoute(tunnel: nil, relay: try ProxyRelay(socket: base + ".sock", proxy: saved.proxy, password: proxyPassword,
                                                                host: saved.host, port: saved.port ?? saved.engine.defaultPort))
        }
        if let problem = SSHConfig.problem(with: saved) { throw AirSQLError(.other, problem) }
        var relay: ProxyRelay?
        if saved.route == .sshProxy, let first = saved.sshHops.first {
            progress("Proxy \(saved.proxy.host)")
            relay = try ProxyRelay(socket: base + ".proxy", proxy: saved.proxy, password: proxyPassword, host: first.host,
                                   port: first.port ?? 22)
        }
        do {
            let tunnel = try await Tunnel.open(saved, askpass: try askpass(), proxySocket: relay?.socket, progress: progress)
            return OpenRoute(tunnel: tunnel, relay: relay)
        } catch {
            relay?.close()
            throw relay?.lastError ?? error
        }
    }
}
