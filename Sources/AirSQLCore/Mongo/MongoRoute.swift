import Foundation

/// A MongoDB connection's route (plan decision 3): the driver finds a replica set's members by their own names and must
/// reach each one, so every server it asks for gets a private Unix socket of its own, opened when it is first asked for.
/// SSH routes: one ssh (no shared master) with a `-L` per server, started again with every server known when the driver
/// asks for one it doesn't forward yet; `MongoConnection.connect` first finds the members through the seeds, so that is
/// one login when the connection string lists every member and two when it doesn't (Phase 0 measured one ssh per member
/// too: a login per member, always). Proxy only: a `ProxyRelay` per server. Direct has none: the driver's socket goes to
/// the server itself. The driver's calls into this block on the session's thread.
public final class MongoRoute: @unchecked Sendable {
    private let saved: SavedConnection
    private let proxyPassword: String
    private let askpass: AskpassServer?
    private let base: String
    private let lock = NSLock()
    /// "host:port" of every server asked for, in order: a server's place here names its socket.
    private var servers: [String] = []
    private var targets: [(host: String, port: Int)] = []
    /// The servers the connection string names, forwarded from the first ssh on.
    private var seeds: [(host: String, port: Int)] = []
    private var sockets: [String: String] = [:]
    private var tunnel: Tunnel?
    private var relays: [ProxyRelay] = []
    private var firstHop: ProxyRelay?
    private var pending: Task<Void, Never>?
    private var closed = false
    private var discovering = false
    private var _logins = 0

    /// ssh starts so far: each logs in to every SSH host of the route (a one-time code is asked each time).
    public var logins: Int { lock.locked { _logins } }
    /// "host:port" of each server the driver asked for, in order.
    public var requested: [String] { lock.locked { servers } }

    /// `askpass`: where ssh's prompts go (SSH routes only); `proxyPassword`: the proxy's ("" without a user).
    public init(_ saved: SavedConnection, proxyPassword: String = "", askpass: AskpassServer? = nil) {
        self.saved = saved
        self.proxyPassword = proxyPassword
        self.askpass = askpass
        base = RouteFolder.base(for: saved.id)
    }

    deinit { close() }

    /// The servers the connection string names.
    func seed(_ hosts: [(host: String, port: Int)]) {
        lock.locked { seeds = hosts }
    }

    /// The socket that reaches host:port, opening its forward first; nil for Direct.
    func socket(host: String, port: Int) throws -> String? {
        guard saved.route != .direct else { return nil }
        let key = "\(host):\(port)"
        let (known, index): (String?, Int) = try lock.locked {
            guard !closed else { throw AirSQLError(.cancelled, "Connecting was cancelled.") }
            if let socket = sockets[key] { return (socket, 0) }
            if !servers.contains(key) {
                servers.append(key)
                targets.append((host, port))
            }
            return (nil, servers.firstIndex(of: key)!)
        }
        if let known { return known }

        if saved.route == .proxy {
            if saved.proxy.host.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AirSQLError(.other, "Type the proxy's address in the SSH and Proxy tab.")
            }
            let relay = try ProxyRelay(socket: base + "-p\(index).sock", proxy: saved.proxy, password: proxyPassword,
                                       host: host, port: port)
            let kept = lock.locked { () -> Bool in
                guard !closed else { return false }
                relays.append(relay)
                sockets[key] = relay.socket
                return true
            }
            guard kept else {
                relay.close()
                throw AirSQLError(.cancelled, "Connecting was cancelled.")
            }
            return relay.socket
        }

        guard let askpass else { throw AirSQLError(.other, "This route's SSH needs somewhere to ask for passwords.") }
        if saved.route == .sshProxy, lock.locked({ firstHop == nil }), let first = saved.sshHops.first {
            let relay = try ProxyRelay(socket: base + ".proxy", proxy: saved.proxy, password: proxyPassword,
                                       host: first.host, port: first.port ?? 22)
            lock.locked { firstHop = relay }
        }
        if lock.locked({ discovering && tunnel != nil }) {
            // Found while finding the members: forwarded with the others once that is done (`findMembers`).
            throw AirSQLError(.noRoute, "\(key) isn't forwarded yet.")
        }
        try restart(askpass: askpass, proxySocket: lock.locked { firstHop?.socket })
        guard let socket = lock.locked({ sockets[key] }) else { throw AirSQLError(.cancelled, "Connecting was cancelled.") }
        return socket
    }

    /// Whether `MongoConnection.connect` first asks the seeds for the members (`findMembers`): SSH routes, so that ssh
    /// starts once more at most.
    var findsMembersFirst: Bool { !saved.sshHops.isEmpty }

    /// Runs `body`, a first look at the replica set through the seeds' forwards alone, which returns every server it
    /// found; then forwards those too, with one more ssh when there are any.
    func findMembers(_ body: () throws -> [(host: String, port: Int)]) throws {
        lock.locked { discovering = true }
        defer { lock.locked { discovering = false } }
        let found = try body()
        let missing = lock.locked { () -> Bool in
            for server in found where !servers.contains("\(server.host):\(server.port)") {
                servers.append("\(server.host):\(server.port)")
                targets.append(server)
            }
            return servers.contains { sockets[$0] == nil }
        }
        guard missing, let askpass else { return }
        try restart(askpass: askpass, proxySocket: lock.locked { firstHop?.socket })
    }

    /// (Re)starts the one ssh with a forward for every server asked for so far and every seed, in a stable order: a
    /// server keeps its socket's name.
    private func restart(askpass: AskpassServer, proxySocket: String?) throws {
        let all: [(host: String, port: Int)] = lock.locked {
            for seed in seeds where !servers.contains("\(seed.host):\(seed.port)") {
                servers.append("\(seed.host):\(seed.port)")
                targets.append(seed)
            }
            return targets
        }
        let generation = lock.locked { _logins }
        lock.locked { () -> Tunnel? in
            defer { tunnel = nil }
            return tunnel
        }?.close()
        let tunnel = try wait { [saved] in
            // A name of its own each time: the ssh ending may still remove its files after the next one started.
            try await Tunnel.open(saved, askpass: askpass, proxySocket: proxySocket, forwards: all, name: "-s\(generation)") { _ in }
        }
        let kept = lock.locked { () -> Bool in
            guard !closed else { return false }
            self.tunnel = tunnel
            _logins += 1
            sockets = Dictionary(zip(all, tunnel.sockets).map { ("\($0.host):\($0.port)", $1) }, uniquingKeysWith: { $1 })
            return true
        }
        if !kept {
            tunnel.close()
            throw AirSQLError(.cancelled, "Connecting was cancelled.")
        }
    }

    /// Runs `body` (Tunnel.open) to the end on this thread; `close` cancels it.
    private func wait(_ body: @escaping @Sendable () async throws -> Tunnel) throws -> Tunnel {
        final class Box: @unchecked Sendable { var result: Result<Tunnel, Error>? }
        let done = DispatchSemaphore(value: 0), box = Box()
        let task = Task {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            done.signal()
        }
        let cancelled = lock.locked { () -> Bool in
            pending = task
            return closed
        }
        if cancelled { task.cancel() }
        done.wait()
        lock.locked { pending = nil }
        return try box.result!.get()
    }

    /// Ends every forward and relay, and an ssh still starting: Cancel while connecting, or Disconnect.
    public func close() {
        let (tunnel, relays, firstHop, pending) = lock.locked {
            closed = true
            defer {
                self.tunnel = nil
                self.relays = []
                self.firstHop = nil
                sockets = [:]
            }
            return (self.tunnel, self.relays, self.firstHop, self.pending)
        }
        pending?.cancel()
        tunnel?.close()
        relays.forEach { $0.close() }
        firstHop?.close()
    }
}
