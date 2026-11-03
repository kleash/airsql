import AirSQLCore
import AppKit

/// Connects and disconnects saved connections (plan §2.2, §2.3): opens the route (an SSH tunnel or the proxy relay,
/// ending in a private Unix socket), logs in with the Keychain's password or the person's, trusts and pins a server
/// certificate macOS doesn't know (the Trust sheet), and keeps the sessions alive. Each step shows in the connection's
/// state and in the status bar's activity, with Cancel. A dropped route or session is reported, never re-made silently.
/// Other parts reach a connected connection's sessions through `open[id]?.connection`.
@MainActor
final class Connector {
    /// A connected connection: its sessions, what the server said at login, and the route under them.
    final class Open {
        let connection: Connection
        let server: ServerInfo
        /// The route under the sessions: its private socket (nil for Direct) is where the client tools and Terminal
        /// connect too.
        let route: OpenRoute
        fileprivate var keepAlive: Timer?

        fileprivate init(connection: Connection, server: ServerInfo, route: OpenRoute) {
            self.connection = connection
            self.server = server
            self.route = route
        }

        /// Closes the sessions, then the route.
        fileprivate func close() async {
            keepAlive?.invalidate()
            await connection.disconnect()
            route.close()
        }
    }

    /// The program ssh asks through (the AirSQL binary itself, `main.swift`); tests use the debug build's.
    static var askpassHelper = Bundle.main.executablePath ?? ""
    /// How often idle sessions are pinged.
    static let keepAliveInterval: TimeInterval = 60

    unowned let model: AppModel
    private(set) var open: [UUID: Open] = [:]
    private var connecting: [UUID: (task: Task<Void, Never>, activity: Activity)] = [:]
    private var askpass: AskpassServer?
    /// Answers the person asked to remember, saved once the connect has worked (a wrong one is never kept).
    var remembered: [UUID: [String: String]] = [:]
    /// The prompts a connect shows, closed when it is cancelled or fails.
    var sheets: [UUID: [NSWindow]] = [:]
    /// The window of the latest connect, where a dialog login's further questions show (`LoginDialog`).
    weak var promptWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
        // ssh runs in a process group of its own: it would outlive AirSQL.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.closeEverything() }
        }
        _ = LoginDialog.function
        LoginDialog.ask = { [weak self] prompt, secret in self?.askDialog(prompt, secret: secret) }
    }

    func isConnecting(_ id: UUID) -> Bool { connecting[id] != nil }

    /// Connects `id` unless it is connected or connecting; prompts and the Trust sheet show on `window`.
    func connect(_ id: UUID, on window: NSWindow?) {
        guard let saved = model.connection(id), open[id] == nil, connecting[id] == nil else { return }
        let activity = model.activity.start("Connecting to \(saved.displayName)", connection: id) { [weak self] in
            self?.cancel(id)
        }
        model.states[id] = .connecting(step: "Starting")
        promptWindow = window
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(saved, on: window, activity: activity)
        }
        connecting[id] = (task, activity)
    }

    /// Stops a connect under way: ssh ends, prompts close, the state goes back to idle.
    func cancel(_ id: UUID) {
        guard let pending = connecting.removeValue(forKey: id) else { return }
        pending.task.cancel()
        pending.activity.end()
        askpass?.cancelPending(for: id.uuidString)
        closePrompts(id)
        remembered[id] = nil
        model.states[id] = nil
    }

    /// Stops the prompts of a Test Connection under way (its task is the editor's to cancel).
    func cancelTest(_ id: UUID) {
        askpass?.cancelPending(for: id.uuidString)
        closePrompts(id)
    }

    /// Closes the connection's sessions and its route; asking about open work is the caller's.
    func disconnect(_ id: UUID) {
        cancel(id)
        model.states[id] = nil
        guard let connected = open.removeValue(forKey: id) else { return }
        Task { await connected.close() }
    }

    /// Quitting: every route and session goes, now.
    private func closeEverything() {
        for id in Array(connecting.keys) { cancel(id) }
        for connected in open.values { connected.route.close() }
        open = [:]
        askpass?.close()
    }

    // MARK: Connecting

    private func run(_ start: SavedConnection, on window: NSWindow?, activity: Activity) async {
        let id = start.id
        var saved = start
        func step(_ text: String) {
            guard connecting[id]?.activity === activity else { return }
            activity.detail = text
            model.states[id] = .connecting(step: text)
        }
        do {
            let (connection, server, route) = try await establish(&saved, on: window, step: step)
            guard connecting[id]?.activity === activity else {
                await connection.disconnect()
                route.close()
                return
            }
            connecting[id] = nil
            activity.end()
            sheets[id] = nil
            let connected = Open(connection: connection, server: server, route: route)
            open[id] = connected
            model.states[id] = .connected(server: Self.serverName(server))
            saveRemembered(id)
            watch(connected, id: id)
        } catch {
            guard connecting[id]?.activity === activity else { return }  // cancelled: nothing to say
            connecting[id] = nil
            activity.end()
            remembered[id] = nil
            closePrompts(id)
            let failure = error as? AirSQLError ?? AirSQLError(.other, error.localizedDescription)
            if failure.kind == .cancelled {
                model.states[id] = nil
            } else {
                model.states[id] = .failed(failure.message)
                showConnectError(failure, connection: saved.displayName, on: window)
            }
        }
    }

    /// "MariaDB 11.8.3": the server's name and version as the sidebar and status bar show it.
    static func serverName(_ server: ServerInfo) -> String {
        (server.flavor == .mariadb ? "MariaDB " : "MySQL ") + (server.version.components(separatedBy: "-").first ?? server.version)
    }

    /// Opens the route and logs in for `saved` (its prompts on `window`), telling each step: what Connect and the
    /// editor's Test Connection both do. `password` and `proxyPassword`: typed in the editor (nil: the Keychain's, or
    /// asked). A pinned certificate and the user name typed at a prompt end up in `saved`.
    func establish(_ saved: inout SavedConnection, password: String? = nil, proxyPassword: String? = nil, on window: NSWindow?,
                   step: @escaping (String) -> Void) async throws -> (Connection, ServerInfo, OpenRoute) {
        let usesProxy = saved.route == .proxy || saved.route == .sshProxy
        let proxy = usesProxy ? try await self.proxyPassword(saved, typed: proxyPassword, on: window) : ""
        let id = saved.id.uuidString
        var server: AskpassServer?
        if !saved.sshHops.isEmpty {
            if askpass == nil { askpass = try AskpassServer(helperPath: Self.askpassHelper) }
            server = askpass
            server?.setHandler(sshPrompts(for: saved, on: window), for: id)
        }
        defer { server?.setHandler(nil, for: id) }
        let route = try await OpenRoute.open(saved, proxyPassword: proxy, askpass: { [server] in
            guard let server else { throw AirSQLError(.other, "No askpass for this route.") }
            return server
        }, progress: { text in DispatchQueue.main.async { step(text) } })
        do {
            try Task.checkCancellation()
            step("Logging in to \(saved.host.isEmpty ? saved.socket : saved.host)")
            let (connection, server) = try await logIn(&saved, password: password, routeSocket: route.socket, on: window)
            return (connection, server, route)
        } catch {
            route.close()
            throw route.relay?.lastError ?? error  // the proxy's reason: the driver only saw the connection close
        }
    }

    /// Test Connection: connects `draft` as the editor has it, then disconnects. The server's description, and the
    /// draft with what the connect learnt (a certificate the person trusted).
    func test(_ draft: SavedConnection, password: String?, proxyPassword: String?, on window: NSWindow?,
              step: @escaping (String) -> Void) async throws -> (summary: String, draft: SavedConnection) {
        var tested = draft
        promptWindow = window
        defer {
            remembered[draft.id] = nil
            closePrompts(draft.id)
        }
        let (connection, server, route) = try await establish(&tested, password: password, proxyPassword: proxyPassword,
                                                             on: window, step: step)
        await connection.disconnect()
        route.close()
        return (Self.serverName(server) + (server.tls.map { ", " + $0 } ?? ", no TLS"), tested)
    }

    /// Logs in through `routeSocket` (or directly): asks for the password when the server refuses the one it has, and
    /// pins a certificate the person trusts (saved with the connection).
    private func logIn(_ saved: inout SavedConnection, password typed: String?, routeSocket: String?,
                       on window: NSWindow?) async throws -> (Connection, ServerInfo) {
        var password: String
        if let typed { password = typed } else { password = try await databasePassword(&saved, on: window, retry: false) }
        while true {
            let connection = Connection(options: saved.connectOptions(password: password, routeSocket: routeSocket))
            do {
                return (connection, try await connection.connect())
            } catch let error as AirSQLError {
                await connection.disconnect()
                try Task.checkCancellation()
                switch error.kind {
                case .untrustedCertificate(let certificate), .certificateChanged(let certificate):
                    var changed = false
                    if case .certificateChanged = error.kind { changed = true }
                    guard let window, await askTrust(certificate, server: saved, changed: changed, on: window) else {
                        throw AirSQLError(.cancelled, "Not trusted.")
                    }
                    saved.tls.pinnedFingerprint = certificate.fingerprint
                    if var stored = model.connection(saved.id) {
                        stored.tls.pinnedFingerprint = certificate.fingerprint
                        model.save(stored)
                    }
                case .authFailed:
                    password = try await databasePassword(&saved, on: window, retry: true)
                default:
                    throw error
                }
            }
        }
    }

    // MARK: Connected

    /// Pings idle sessions (except one whose transaction has been open too long), and reports a dropped route or
    /// session: the person reconnects with Connect.
    private func watch(_ connected: Open, id: UUID) {
        let token = ObjectIdentifier(connected)
        connected.route.tunnel?.onExit = { [weak self] error in
            DispatchQueue.main.async { self?.dropped(id, token, error.message) }
        }
        connected.keepAlive = Timer.scheduledTimer(withTimeInterval: Self.keepAliveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let saved = self.model.connection(id), let connection = self.open[id]?.connection else { return }
                let limit = TimeInterval(self.model.data.safety(for: saved).openTransactionMinutes * 60)
                Task { [weak self] in
                    await connection.keepAlive(transactionLimit: limit)
                    if let main = try? await connection.session(.main), !main.isConnected {
                        self?.dropped(id, token, AirSQLError.disconnected.message)
                    }
                }
            }
        }
    }

    /// The connection `token` stands for dropped (if it is still the one open): it is reported, and its sessions and
    /// route close.
    private func dropped(_ id: UUID, _ token: ObjectIdentifier, _ message: String) {
        guard let connected = open[id], ObjectIdentifier(connected) == token else { return }
        open[id] = nil
        model.states[id] = .failed(message)
        Task { await connected.close() }
    }
}
