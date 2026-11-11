import AirSQLCore
import AppKit

/// A MongoDB server's host page (mongo-plan, Phase 2 "host"), laid out as the MySQL one (`HostContent`): its figures
/// from serverStatus with counters' rates between two reads, the replica set's members (state, health, lag behind the
/// primary, ping) and the operations running, with Kill (`MongoOperations.swift`). It reads on a session of its own,
/// every few seconds while it shows and never while it is hidden, each command with a time limit.
@MainActor
final class MongoHostContent: NSViewController, TabContent, NSMenuItemValidation {
    enum Pane: Int, CaseIterable {
        case server, members, operations

        var title: String { ["Server", "Members", "Operations"][rawValue] }
        var tip: String {
            ["Show the server's version, uptime, connections, operations per second, memory and network",
             "List the replica set's members with their state, health, lag behind the primary and ping",
             "List the operations running on the server, with Kill"][rawValue]
        }
    }

    /// Seconds between reads while the page shows.
    static let interval: UInt64 = 5

    let open: OpenMongoConnection
    private(set) var pane: Pane
    private let heading = label("", font: .systemFont(ofSize: 15, weight: .semibold), truncates: true)
    let properties = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    private let spinner = NSProgressIndicator()
    private let holder = NSView()
    let tabs = NSSegmentedControl()
    private lazy var diskUsage = button("Disk Usage", id: "mongoHost.diskUsage", tip: Commands.mongoDiskUsage.tip, target: self,
                                        action: #selector(showDiskUsage(_:))).onBar("internaldrive")
    private(set) lazy var figures = HostList(
        name: "Mongo Server",
        columns: [
            .init(id: "name", title: "Figure", width: 200, tip: "What serverStatus says"),
            .init(id: "value", title: "Value", width: 220, numeric: true, tip: "What it stands at"),
            .init(id: "second", title: "Per Second", width: 120, numeric: true, tip: "Its rate between the last two reads"),
        ])
    private(set) lazy var members = HostList(
        name: "Mongo Members",
        columns: [
            .init(id: "name", title: "Member", width: 200, tip: "The member, as the replica set names it"),
            .init(id: "state", title: "State", width: 110, tip: "PRIMARY takes writes; SECONDARY copies them"),
            .init(id: "health", title: "Health", width: 70, tip: "Whether the member answering hears from it"),
            .init(id: "lag", title: "Behind Primary", width: 110, numeric: true, tip: "How far its last write is behind the primary's"),
            .init(id: "ping", title: "Ping", width: 70, numeric: true, tip: "The round trip from the member that answered"),
            .init(id: "uptime", title: "Uptime", width: 110, numeric: true, tip: "How long it has been running"),
            .init(id: "message", title: "Last Heartbeat", width: 240, tip: "What its last heartbeat said, if anything"),
        ])
    lazy var allOperations = checkbox("All Operations", id: "mongoHost.allOperations",
                                      tip: "List every login's operations, not only this login's", on: false,
                                      target: self, action: #selector(refresh(_:)))
    private(set) lazy var kill = button("Kill Operation…", id: "mongoHost.kill", tip: Commands.killOperation.tip, target: self,
                                        action: #selector(killOperation(_:))).onBar("xmark.octagon")
    private(set) lazy var operations = HostList(
        name: "Mongo Operations",
        columns: [
            .init(id: "opid", title: "Op Id", width: 70, numeric: true, tip: "The server's number for the operation, which Kill uses"),
            .init(id: "op", title: "Op", width: 64, tip: "What kind: query, getmore, insert, update, remove, command"),
            .init(id: "ns", title: "Namespace", width: 130, tip: "The database and collection it works on"),
            .init(id: "running", title: "Running For", width: 84, numeric: true, tip: "How long it has been running"),
            .init(id: "client", title: "Client", width: 160, tip: "Where it comes from, and the app it says it is"),
            .init(id: "description", title: "Description", width: 180, tip: "Its comment, or what the server calls it"),
            .init(id: "plan", title: "Plan", width: 120, tip: "How it reads: COLLSCAN reads every document, IXSCAN an index"),
        ],
        sort: NSSortDescriptor(key: "running", ascending: false), accessories: [kill, allOperations, Self.gap()])

    /// Room between the checkbox and the list's caption.
    private static func gap() -> NSView {
        let gap = NSView()
        gap.widthAnchor.constraint(equalToConstant: Spacing.unit).isActive = true
        return gap
    }

    /// What the last read found.
    private(set) var operationsFound: [MongoHost.Operation] = []
    /// Whether this login may list everyone's operations: nil until tried; the reason when it may not.
    var allRefusal: String??
    /// How many reads have finished: tests count them to see the timer stop.
    private(set) var reads = 0
    private var previous: BSONDocument?
    private var session: MongoSession?
    let slot = "host-" + UUID().uuidString
    private var reading: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    init(_ open: OpenMongoConnection, pane: Pane = .server) {
        self.open = open
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.content)
        root.setAccessibilityIdentifier("mongoHost")
        heading.stringValue = open.saved.displayName
        heading.toolTip = heading.stringValue
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        properties.setAccessibilityIdentifier("mongoHost.properties")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Reading")
        tabs.segmentCount = Pane.allCases.count
        tabs.trackingMode = .selectOne
        tabs.selectedSegmentBezelColor = .selectedSegment
        for page in Pane.allCases {
            tabs.setLabel(page.title, forSegment: page.rawValue)
            tabs.setToolTip(page.tip, forSegment: page.rawValue)
        }
        tabs.target = self
        tabs.action = #selector(paneChosen)
        tabs.setAccessibilityIdentifier("mongoHost.panes")
        let top = NSStackView(views: [heading, spinner, NSView(), diskUsage])
        top.spacing = Spacing.unit
        let texts = NSStackView(views: [top, properties, tabs])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = Spacing.half
        texts.setCustomSpacing(Spacing.unit, after: properties)
        texts.translatesAutoresizingMaskIntoConstraints = false
        holder.translatesAutoresizingMaskIntoConstraints = false
        [texts, holder].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalTo: texts.widthAnchor),
            properties.widthAnchor.constraint(lessThanOrEqualTo: texts.widthAnchor),
            texts.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            texts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            texts.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double),
            holder.topAnchor.constraint(equalTo: texts.bottomAnchor, constant: Spacing.unit),
            holder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            holder.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        for list in [figures, members, operations] {
            addChild(list)
            list.onMenu = { [weak self] in self?.contextMenu() }
        }
        operations.onSelect = { [weak self] in self?.updateButtons() }
        operations.onOpen = { [weak self] _ in self?.killOperation(nil) }
        figures.note = "reading…"
        properties.stringValue = open.server.summary
        show(pane)
    }

    /// The pane's list in the holder, with the focus.
    func show(_ pane: Pane) {
        self.pane = pane
        guard isViewLoaded else { return }
        tabs.selectedSegment = pane.rawValue
        holder.subviews.forEach { $0.removeFromSuperview() }
        let list = [figures, members, operations][pane.rawValue]
        holder.addSubview(list.view)
        list.view.pin(to: holder)
        view.window?.makeFirstResponder(list.table)
        updateButtons()
    }

    @objc private func paneChosen() { Pane(rawValue: tabs.selectedSegment).map(show) }

    // MARK: Reading, only while it shows

    override func viewWillAppear() {
        super.viewWillAppear()
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let seconds = self?.tick() else { return }
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        timer?.cancel()
        timer = nil
    }

    /// A read, and the seconds to the next: a second read soon after the first gives the rates, then every few seconds.
    private func tick() -> UInt64 {
        refresh(nil)
        return reads < 1 ? 1 : Self.interval
    }

    /// Whether it reads on its timer now: only while the page shows.
    var isPolling: Bool { timer != nil }

    var isReading: Bool { reading != nil }

    func hostSession() async throws -> MongoSession {
        if let session { return session }
        let opened = try await open.connection.session(.data, slot: slot)
        session = opened
        return opened
    }

    /// Reads the figures, the members and the operations (a read under way is not doubled).
    @objc func refresh(_ sender: Any?) {
        guard reading == nil else { return }
        spinner.startAnimation(nil)
        let wantsAll = allOperations.state == .on
        reading = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await hostSession()
                var status: BSONDocument?, statusProblem: String?
                do { status = try await session.serverStatus() } catch { statusProblem = Self.words(error, "the server's figures") }
                var set: BSONDocument?, setProblem: String?
                if open.server.setName == nil {
                    setProblem = open.server.isMongos ? "A sharded cluster's router has no members of its own"
                        : "A standalone server: it has no replica set members"
                } else {
                    do { set = try await session.replicaSetStatus() } catch { setProblem = Self.words(error, "the replica set's members") }
                }
                let (ops, opsProblem) = await readOperations(session, all: wantsAll)
                show(status: status, statusProblem, members: set, setProblem, operations: ops, opsProblem)
            } catch {
                properties.stringValue = "Couldn't read the server: " + error.localizedDescription
                properties.toolTip = properties.stringValue
            }
            spinner.stopAnimation(nil)
            reading = nil
            reads += 1
        }
    }

    /// Why a read was refused, in words: a missing privilege says which role gives it.
    private static func words(_ error: Error, _ what: String) -> String {
        if (error as? AirSQLError)?.kind == .accessDenied {
            return "This login may not read \(what): it needs the clusterMonitor role"
        }
        return "Couldn't read \(what): " + error.localizedDescription
    }

    private func show(status: BSONDocument?, _ statusProblem: String?, members set: BSONDocument?, _ setProblem: String?,
                      operations ops: [MongoHost.Operation]?, _ opsProblem: String?) {
        func rate(_ figure: MongoHost.Figure) -> String {
            guard let value = figure.perSecond else { return "" }
            if figure.bytes { return DiskUsage.size(Int(value)) + "/s" }
            return value.formatted(.number.precision(.fractionLength(0...(value < 10 ? 1 : 0))))
        }
        let found = status.map { MongoHost.figures($0, previous: previous) } ?? []
        if let status { previous = status }
        figures.show(found.map { figure in
            var numbers: [String: Double] = [:]
            numbers["value"] = figure.number
            numbers["second"] = figure.perSecond
            return HostList.Row(key: figure.name, cells: ["name": figure.name, "value": figure.value, "second": rate(figure)], numbers: numbers)
        })
        figures.note = statusProblem ?? (found.contains { $0.perSecond != nil } ? "rates between the last two reads"
                                                                                : "rates show after the next read")
        let memberRows = set.map(MongoHost.members) ?? []
        members.show(memberRows.map { member in
            var numbers: [String: Double] = [:]
            numbers["lag"] = member.lag.map(Double.init)
            numbers["ping"] = member.ping.map(Double.init)
            numbers["uptime"] = member.uptime
            return HostList.Row(key: member.name, cells: [
                "name": member.name + (member.isSelf ? " (answered)" : ""), "state": member.state, "health": member.healthy ? "Up" : "Down",
                "lag": member.lag.map { "\($0) s" } ?? "", "ping": member.isSelf ? "" : member.ping.map { "\($0) ms" } ?? "",
                "uptime": member.uptime.map { MongoHost.duration($0) } ?? "", "message": member.message ?? "",
            ], numbers: numbers)
        })
        members.note = setProblem ?? "as \(memberRows.first { $0.isSelf }?.name ?? "the primary") sees them"
        if let ops { operationsFound = ops }
        operations.show(operationsFound.map { op in
            var numbers: [String: Double] = [:]
            numbers["opid"] = op.opid.integer.map(Double.init)
            numbers["running"] = op.microseconds.map(Double.init)
            return HostList.Row(key: op.id, cells: [
                "opid": op.id, "op": op.op, "ns": op.namespace,
                "running": op.microseconds.map { MongoHost.duration(Double($0) / 1_000_000) } ?? "",
                "client": op.client ?? "the server itself", "description": op.description, "plan": op.plan,
            ], numbers: numbers)
        })
        operations.note = opsProblem ?? operationsNote
        var parts = [open.server.summary]
        if let status {
            if let host = MongoHost.string(status, "host") { parts.append(host) }
            if let engine = MongoHost.string(status, "storageEngine.name") { parts.append(engine) }
            if let uptime = MongoHost.number(status, "uptime") { parts.append("up " + MongoHost.duration(uptime)) }
        }
        parts.append("read every \(Self.interval) s while shown")
        properties.stringValue = parts.joined(separator: " · ")
        properties.toolTip = properties.stringValue
        updateButtons()
    }

    // MARK: Commands

    @objc func showDiskUsage(_ sender: Any?) {
        (view.window?.windowController as? MainWindowController)?.showMongoDiskUsage(open, database: nil)
    }

    private var currentList: HostList { [figures, members, operations][pane.rawValue] }

    @objc func copyList(_ sender: Any?) { currentList.copyList(sender) }
    @objc func exportList(_ sender: Any?) { currentList.exportList(sender) }

    func contextMenu() -> NSMenu? {
        let menu = NSMenu(title: "Server")
        if pane == .operations { menu.add([Commands.killOperation, nil]) }
        menu.add([Commands.copy, Commands.copyList, Commands.exportList, nil, Commands.refresh])
        return menu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let reason = reason(item.action)
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    /// The tab closes, or the preview shows something else: its session goes, and the timer stops.
    func release() {
        timer?.cancel()
        timer = nil
        session = nil
        let (connection, slot) = (open.connection, slot)
        Task { await connection.closeSession(.data, slot: slot) }
    }

    override func removeFromParent() {
        release()
        super.removeFromParent()
    }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        release()
        answer(true)
    }
}

extension MainWindowController {
    /// Shows `pane` on the MongoDB connection's host page: in the tab that has it, else in the preview tab.
    func showMongoHost(_ open: OpenMongoConnection, pane: MongoHostContent.Pane? = nil) {
        if let tab = model.allTabs.first(where: { ($0.shown as? MongoHostContent)?.open === open }), let host = tab.shown as? MongoHostContent {
            show(tab)
            if let pane { host.show(pane) }
        } else {
            preview(MongoHostContent(open, pane: pane ?? .server), title: open.saved.displayName, connection: open.saved.id)
        }
    }
}
