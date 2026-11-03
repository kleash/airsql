import AirSQLCore
import AppKit
import Combine

/// One thing an agent asked, as the activity list shows it.
struct AgentEvent {
    let time: Date
    let client: String
    let summary: String
    /// nil while it runs.
    var outcome: String?
    var failed = false
}

/// Agents (plan §2.8): the agent socket while Settings ▸ Agents allows agents, and the answers to their tools. State
/// comes from the model and the main window on the main actor; database work runs through `AgentTarget`, off it. Every
/// call is listed in the activity list (the status bar's agent chip) and, while it reads a database, in Activity with
/// Cancel. Access levels are read here and never written: agents can't change them.
@MainActor
final class AgentService {
    let model: AppModel
    weak var main: MainWindowController?
    private let directory: URL
    private var listener: AgentListener?
    private(set) var events: [AgentEvent] = []
    /// Why the socket couldn't start, for Settings ▸ Agents.
    private(set) var problem: String?
    private var observers: [AnyCancellable] = []
    private var running: [Activity] = []
    static let eventLimit = 200

    /// What lanes not yet in this build give agents: the open connection and its schema cache (connections, L1), and
    /// the console (L4). Until then a connection counts as not connected.
    var openConnection: (UUID) -> Connection? = { _ in nil }
    var schemaCache: (UUID) -> SchemaCache? = { _ in nil }
    var consoles: AgentConsoles?
    /// Carries out the UI tools on the person's windows.
    lazy var harness = AgentServer(main: main, model: model)

    init(model: AppModel, main: MainWindowController?, directory: URL = AgentSocket.directory) {
        self.model = model
        self.main = main
        self.directory = directory
        observers.append(model.$data.map(\.settings.agentsAllowed).removeDuplicates().sink { [weak self] allowed in
            DispatchQueue.main.async { self?.update(allowed: allowed) }
        })
        main?.statusBar.agent.popover = { [weak self] in self.map { AgentActivityPopover(service: $0) } }
    }

    /// Opens or closes the socket as the setting says; turning agents off also stops their calls under way.
    func update(allowed: Bool) {
        if allowed, listener == nil {
            do {
                listener = try AgentListener(directory: directory) { [weak self] tool, arguments, client, progress in
                    guard let self else { return AgentBridge.failure("AirSQL is closing.") }
                    return await self.handle(tool, arguments, client: client, progress: progress)
                }
                problem = nil
                // A statement an agent's request sends on the person's sessions waits for them here.
                AgentGate.approve = { [weak self] request in
                    guard let self else { throw AirSQLError(.readOnly, AgentGate.declined) }
                    try await self.approve(request)
                }
            } catch {
                problem = error.localizedDescription
                log.error("agents: \(error.localizedDescription, privacy: .public)")
            }
        } else if !allowed {
            listener?.close()
            listener = nil
            AgentGate.approve = nil
            running.forEach { $0.cancel() }
        }
        updateStatus()
    }

    /// Closes the socket (Quit).
    func close() {
        listener?.close()
        listener = nil
        AgentGate.approve = nil
    }

    var isListening: Bool { listener != nil }

    // MARK: Calls

    func handle(_ tool: String, _ arguments: [String: Any], client: String,
                progress: @escaping AgentProgress = { _, _, _ in }) async -> [String: Any] {
        guard model.data.settings.agentsAllowed else {  // a call that came in as agents were turned off
            return tool.hasPrefix("resources/") ? ["error": AgentBridge.offMessage] : AgentBridge.failure(AgentBridge.offMessage)
        }
        if tool == "resources/list" { return ["resources": resources()] }
        let index = record(client, summary(tool, arguments))
        do {
            let structured: [String: Any]
            switch tool {
            case "context": structured = context()
            case "get_schema", "describe", "run_queries", "profile", "explain":
                structured = try await reading(tool, try target(arguments), progress: progress) { target, progress in
                    switch tool {
                    case "get_schema": return try await target.getSchema(arguments, progress: progress)
                    case "describe": return try await target.describe(arguments)
                    case "run_queries": return try await target.runQueries(arguments, progress: progress)
                    case "profile": return try await target.profile(arguments, progress: progress)
                    default: return try await target.explain(arguments)
                    }
                }
            case "open_in_console": structured = try openInConsole(arguments)
            case "read_console": structured = try readConsole(arguments)
            case _ where Self.uiTools.contains(tool):
                let reply = await drive(tool, arguments, client: client)
                let failure = reply["isError"] as? Bool == true
                let text = ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                finish(index, failure ? String(text.prefix(80)) : "done", failed: failure)
                return reply
            case "resources/read":
                let text = try await resource(arguments["uri"] as? String ?? "")
                finish(index, "read")
                return ["contents": [["uri": arguments["uri"] ?? "", "mimeType": "text/plain", "text": text]]]
            default: throw AirSQLError(.other, "AirSQL has no tool “\(tool)”.")
            }
            finish(index, Self.outcome(tool, structured))
            return await Self.reply(structured)
        } catch {
            finish(index, AgentReply.message(error), failed: true)
            return tool == "resources/read" ? ["error": AgentReply.message(error)] : AgentReply.failure(error)
        }
    }

    /// The result with its JSON text, made off the main thread (a big result takes a while).
    nonisolated private static func reply(_ structured: [String: Any]) async -> [String: Any] {
        AgentReply.success(structured)
    }

    /// Runs database work for a call, listed in Activity with Cancel (which stops the agent session's statement).
    private func reading(_ tool: String, _ target: AgentTarget, progress: @escaping AgentProgress,
                         _ work: @escaping (AgentTarget, @escaping AgentProgress) async throws -> [String: Any])
        async throws -> [String: Any] {
        let reporting: AgentProgress = { [weak self] done, total, message in
            progress(done, total, message)
            Task { @MainActor in self?.report(target.saved.id, done, total, message) }
        }
        let task = Task { try await work(target, reporting) }
        let activity = model.activity.start("Agent: \(tool) on \(target.saved.displayName)", connection: target.saved.id) {
            task.cancel()
            Task { _ = try? await target.connection?.session(.agent).cancel() }
        }
        running.append(activity)
        defer {
            activity.end()
            running.removeAll { $0 === activity }
        }
        return try await task.value
    }

    private func report(_ connection: UUID, _ done: Double, _ total: Double?, _ message: String?) {
        guard let activity = running.last(where: { $0.connection == connection }) else { return }
        activity.progress = total.map { $0 > 0 ? min(1, done / $0) : 0 }
        activity.detail = message
    }

    /// The connection a call names (its name or id), when agents may use it.
    func target(_ arguments: [String: Any]) throws -> AgentTarget {
        let name = (arguments["connection"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let visible = model.data.connections.filter { $0.agentAccess != .off }
        let byID = visible.filter { $0.id.uuidString.caseInsensitiveCompare(name) == .orderedSame }
        let matches = byID.isEmpty ? visible.filter { $0.displayName == name } : byID
        guard let saved = matches.first else {
            throw AirSQLError(.notFound, name.isEmpty ? "Name a connection: context lists those agents may use."
                              : "No connection “\(name)” is open to agents: context lists those that are.")
        }
        guard matches.count == 1 else {
            throw AirSQLError(.other, "Several connections are named “\(name)”: use the id context gives.")
        }
        return target(saved)
    }

    func target(_ saved: SavedConnection) -> AgentTarget {
        let connected: Bool
        if case .connected? = model.states[saved.id] { connected = true } else { connected = false }
        return AgentTarget(saved: saved, safety: model.data.safety(for: saved),
                           connection: connected ? openConnection(saved.id) : nil,
                           schema: connected ? schemaCache(saved.id) : nil, database: database(of: saved))
    }

    /// The database a connection's statements run in: the active console tab's, else the connection's own.
    func database(of saved: SavedConnection) -> String? {
        if let tab = main?.selectedTab, tab.connectionID == saved.id, let database = (tab.content as? AgentConsole)?.agentDatabase {
            return database
        }
        return saved.database.isEmpty ? nil : saved.database
    }

    // MARK: The activity list

    func record(_ client: String, _ summary: String) -> Int {
        events.append(AgentEvent(time: Date(), client: client, summary: summary))
        if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
        updateStatus()
        return events.count - 1
    }

    func finish(_ index: Int, _ outcome: String, failed: Bool = false) {
        guard events.indices.contains(index) else { return }
        events[index].outcome = outcome
        events[index].failed = failed
        updateStatus()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    static let didChange = Notification.Name("AirSQLAgentActivityDidChange")

    /// The status bar's chip: what agents do now or did last; "Agents on" before the first call.
    private func updateStatus() {
        let allowed = model.data.settings.agentsAllowed
        if let last = events.last {
            let what = last.client + " · " + last.summary.prefix(40) + (last.outcome == nil ? "…" : "")
            model.agentStatus = allowed ? what : "Agents off"
        } else {
            model.agentStatus = allowed ? "Agents on" : nil
        }
    }
}
