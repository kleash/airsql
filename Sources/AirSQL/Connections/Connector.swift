import AirSQLCore
import AppKit

/// Connects and disconnects saved connections (plan §2.2, §2.3): opens the route (an SSH tunnel or the proxy relay,
/// ending in a private Unix socket), logs in with the Keychain's password or the person's, trusts and pins a server
/// certificate macOS doesn't know (the Trust sheet), and keeps the sessions alive. Each step shows in the connection's
/// state and in the status bar's activity, with Cancel. A dropped route or session is reported, never re-made silently.
/// Other parts reach a connected connection's sessions through `open[id]?.connection`; once connected, its schema
/// cache is `AppModel.open[id]` (`attach`), emptied again at Disconnect or a drop.
@MainActor
final class Connector {
    /// A connected connection: its sessions, what the server said at login, and the route under them.
    @MainActor final class Open {
        let connection: Connection
        let server: ServerInfo
        /// The route under the sessions: its private socket (nil for Direct) is where the client tools and Terminal
        /// connect too.
        let route: OpenRoute
        fileprivate var keepAlive: Timer?
        /// Keep-alive ticks so far: minutes, at `keepAliveInterval`.
        fileprivate var ticks = 0

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
    /// Connections that dropped, kept so the next Connect can reconnect through the same route and clear the thread the
    /// server may still have (plan §2.2, R8). Closed on Disconnect, on a reconnect, or when the app quits.
    private var droppedOpens: [UUID: Open] = [:]
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

    /// Connects `id` unless it is connected or connecting; prompts and the Trust sheet show on `window`.
    func connect(_ id: UUID, on window: NSWindow?) {
        guard let saved = model.connection(id), open[id] == nil, model.openMongo[id] == nil, connecting[id] == nil else { return }
        let activity = model.activity.start("Connecting to \(saved.displayName)", connection: id) { [weak self] in
            self?.cancel(id)
        }
        model.states[id] = .connecting(step: "Starting")
        promptWindow = window
        let dropped = droppedOpens.removeValue(forKey: id)
        let task = Task { [weak self] in
            guard let self else { return }
            if let dropped {
                await self.reconnect(saved, dropped: dropped, on: window, activity: activity)
            } else {
                await self.run(saved, on: window, activity: activity)
            }
        }
        connecting[id] = (task, activity)
    }

    /// Connects what the person chose to have connected when AirSQL opens, never a Production connection, and the one
    /// `--connect <name>` asks for by its name (`open -a AirSQL --args --connect Staging`).
    func connectAtLaunch(on window: NSWindow?, arguments: [String] = CommandLine.arguments) {
        for saved in model.data.connections where saved.connectsAtLaunch { connect(saved.id, on: window) }
        guard let flag = arguments.firstIndex(of: "--connect"), arguments.indices.contains(flag + 1) else { return }
        let name = arguments[flag + 1]
        guard let asked = model.data.connections.first(where: { $0.displayName == name }) else {
            return showError("There is no saved connection named “\(name)”.", title: "AirSQL couldn't connect", on: window)
        }
        connect(asked.id, on: window)
    }

    /// The connection's sessions, for another window (the compare window): connects it first, its prompts on `window`,
    /// unless it is connected, and waits for the connect to end. Throws why it didn't connect (shown on `window` too).
    func connection(_ id: UUID, on window: NSWindow?) async throws -> Connection {
        if let connected = open[id] { return connected.connection }
        connect(id, on: window)
        for await states in model.$states.values {
            if case .connected? = states[id], let connected = open[id] { return connected.connection }
            if case .failed(let message)? = states[id] { throw AirSQLError(.other, message) }
            if states[id] == nil { throw AirSQLError(.cancelled, "Not connected.") }
        }
        throw AirSQLError.disconnected
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
        model.detach(id)
        if let dropped = droppedOpens.removeValue(forKey: id) { Task { await dropped.close() } }
        guard let connected = open.removeValue(forKey: id) else { return }
        Task { await connected.close() }
    }

    /// Quitting: every route and session goes, now.
    private func closeEverything() {
        for id in Array(connecting.keys) { cancel(id) }
        for dropped in droppedOpens.values { dropped.route.close() }
        droppedOpens = [:]
        for connected in open.values { connected.route.close() }
        open = [:]
        for mongo in model.openMongo.values { mongo.connection.route.close() }
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
            if saved.engine == .mongodb {
                let (connection, server) = try await establishMongo(&saved, on: window, step: step)
                guard connecting[id]?.activity === activity else { return await connection.close() }
                connecting[id] = nil
                activity.end()
                sheets[id] = nil
                model.states[id] = .connected(server: server.summary)
                model.attach(mongo: OpenMongoConnection(saved: saved, connection: connection, server: server), to: id)
                saveRemembered(id)
                return
            }
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
            model.attach(connection, to: id, includes: saved.showsDatabase)
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
                showConnectError(failure, connection: saved, on: window)
            }
        }
    }

    /// Reconnects a connection that dropped, through the same route (plan §2.2, R8): the kept session is set up again
    /// and the thread the server may still have is killed, freeing its locks. If the route is gone too, the kept one is
    /// thrown away and a fresh connect runs. When a transaction was open at the drop, the person is told it's gone.
    private func reconnect(_ saved: SavedConnection, dropped: Open, on window: NSWindow?, activity: Activity) async {
        let id = saved.id
        do {
            activity.detail = "Reconnecting"
            model.states[id] = .connecting(step: "Reconnecting")
            let report = try await dropped.connection.reconnect()
            guard connecting[id]?.activity === activity else { await dropped.close(); return }  // cancelled meanwhile
            connecting[id] = nil
            activity.end()
            let connected = Open(connection: dropped.connection, server: report.server, route: dropped.route)
            open[id] = connected
            model.states[id] = .connected(server: Self.serverName(report.server))
            model.attach(dropped.connection, to: id, includes: saved.showsDatabase)
            watch(connected, id: id)
            if report.rolledBack { reportRolledBack(id) }
        } catch {
            // The route dropped too (the tunnel or relay is gone): throw the kept one away and connect from scratch.
            await dropped.close()
            guard connecting[id]?.activity === activity else { return }
            await run(saved, on: window, activity: activity)
        }
    }

    /// Tells the person, in the connection's console tabs, that the transaction open when it dropped is now rolled back.
    private func reportRolledBack(_ id: UUID) {
        let text = "The connection dropped and was reconnected, so the transaction that was open is rolled back."
        for tab in model.allTabs where tab.connectionID == id {
            (tab.content as? ConsoleViewController)?.note(.warning, text)
        }
    }

    /// "MariaDB 11.8.3": the server's name and version as the sidebar and status bar show it.
    static func serverName(_ server: ServerInfo) -> String {
        server.flavor.title + " " + (server.version.components(separatedBy: "-").first ?? server.version)
    }

    /// Opens the route and logs in for `saved` (its prompts on `window`), telling each step: what Connect and the
    /// editor's Test Connection both do. `password` and `proxyPassword`: typed in the editor (nil: the Keychain's, or
    /// asked). A pinned certificate and the user name typed at a prompt end up in `saved`.
    func establish(_ saved: inout SavedConnection, password: String? = nil, proxyPassword: String? = nil, on window: NSWindow?,
                   step: @escaping (String) -> Void) async throws -> (Connection, ServerInfo, OpenRoute) {
        try await withRoutePrompts(saved, proxyPassword: proxyPassword, on: window) { proxy, server in
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
    }

    /// `establish` for MongoDB: its route opens a forward or relay per server as the driver asks for each
    /// (`logInMongo`).
    func establishMongo(_ saved: inout SavedConnection, password: String? = nil, proxyPassword: String? = nil,
                        on window: NSWindow?, step: @escaping (String) -> Void) async throws -> (MongoConnection, MongoServerInfo) {
        try await withRoutePrompts(saved, proxyPassword: proxyPassword, on: window) { proxy, server in
            step("Logging in to \(saved.host)")
            return try await logInMongo(&saved, password: password, proxyPassword: proxy, askpass: server, on: window)
        }
    }

    /// Runs `body` with the proxy's password and, on an SSH route, the askpass server that shows ssh's prompts on
    /// `window`.
    private func withRoutePrompts<T>(_ saved: SavedConnection, proxyPassword: String?, on window: NSWindow?,
                                     _ body: (_ proxy: String, _ askpass: AskpassServer?) async throws -> T) async throws -> T {
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
        return try await body(proxy, server)
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
        if draft.engine == .mongodb {
            let (connection, server) = try await establishMongo(&tested, password: password, proxyPassword: proxyPassword,
                                                                on: window, step: step)
            await connection.close()
            return (server.summary + (tested.tls.mode == .off ? ", no TLS" : ", TLS"), tested)
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
                case .authFailed where [1820, 1862].contains(error.code):
                    // Only at Connect: Test Connection's typed password would stay in the editor, to be saved, and no longer work.
                    guard typed == nil else { throw error }
                    password = try await changeExpiredPassword(saved, password, routeSocket: routeSocket, on: window, error)
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
        connected.route.tunnel?.onExit = { [weak self, weak connected] error in
            DispatchQueue.main.async { self?.dropped(id, connected, error.message) }
        }
        connected.keepAlive = Timer.scheduledTimer(withTimeInterval: Self.keepAliveInterval, repeats: true) {
            [weak self, weak connected] _ in
            MainActor.assumeIsolated {
                guard let self, let connected, let saved = self.model.connection(id) else { return }
                let limit = TimeInterval(self.model.data.safety(for: saved).openTransactionMinutes * 60)
                connected.ticks += 1
                let refresh = self.model.data.settings.schemaRefreshMinutes
                if refresh > 0, connected.ticks % refresh == 0, let schema = self.model.openConnection(id), !schema.loading.contains(.schema) {
                    schema.load()
                }
                Task { [weak self] in
                    await connected.connection.keepAlive(transactionLimit: limit)
                    if let main = try? await connected.connection.session(.main), !main.isConnected {
                        self?.dropped(id, connected, AirSQLError.disconnected.message)
                    }
                    await self?.closeIfIdle(id, connected, now: Date())
                }
            }
        }
    }

    /// Disconnects a connection idle for its `idleDisconnectMinutes`, never with work open: a statement running, a
    /// transaction, edits not applied, results waiting or a client tool at work.
    func closeIfIdle(_ id: UUID, _ connected: Open, now: Date) async {
        guard let minutes = model.connection(id)?.idleDisconnectMinutes, minutes > 0,
              let since = await connected.connection.idleSince(), now.timeIntervalSince(since) >= TimeInterval(minutes * 60),
              open[id] === connected, ToolSheet.running(on: [id]).isEmpty,
              !NSApplication.shared.windows.contains(where: { ($0.windowController as? MainWindowController)?.busyTabs([id]).isEmpty == false })
        else { return }
        SQLLog.shared.note("disconnected after \(minutes) idle minutes", context: connected.connection.options.name)
        disconnect(id)
    }

    /// `connected` dropped (if it is still the one open): it is reported, and kept so the next Connect can reconnect it
    /// through the same route and clear the thread the server may still have (plan §2.2, R8). Its keep-alive stops.
    func dropped(_ id: UUID, _ connected: Open?, _ message: String) {
        guard let connected, open[id] === connected else { return }
        open[id] = nil
        model.detach(id, closingSessions: false)
        connected.connection.dropped()
        model.states[id] = .failed(message)
        connected.keepAlive?.invalidate()
        if let previous = droppedOpens.updateValue(connected, forKey: id) { Task { await previous.close() } }
    }
}
