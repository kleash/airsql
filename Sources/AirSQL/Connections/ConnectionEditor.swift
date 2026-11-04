import AirSQLCore
import AppKit

/// The connection editor (plan §2.3, mockup screen 5): a sheet with the tabs General, TLS, SSH and Proxy, Options, Safety
/// and Agents over a copy of the connection, Test Connection (each hop reported), and Save or Save and Connect. Passwords
/// typed here go to the Keychain on Save, never into airsql.json.
@MainActor
final class ConnectionEditor: NSWindowController, NSWindowDelegate {
    enum Tab: Int, CaseIterable {
        case general, tls, route, options, safety, agents

        var title: String { ["General", "TLS", "SSH and Proxy", "Options", "Safety", "Agents"][rawValue] }
        var tip: String {
            ["Show the server's address, the login and where the connection sits in the sidebar",
             "Show how the connection is encrypted and how the server proves who it is",
             "Show the route: directly, through SSH hosts, or through a proxy",
             "Show read-only, startup SQL, the databases shown, timeouts and this connection's client tools",
             "Show what asks first on this connection and the limits agents work within",
             "Show what AI agents may do with this connection"][rawValue]
        }
    }

    /// The connection as edited (saved on Save).
    var draft: SavedConnection {
        didSet {
            routePathLabel?.stringValue = routePath
            if draft.tls != oldValue.tls { tlsFollowsHost = false } else if tlsFollowsHost { draft.tls.mode = Self.tlsMode(for: draft) }
        }
    }
    /// A new connection's TLS until the person sets it: local servers rarely offer TLS, so off for one on this Mac, where
    /// nothing crosses a network, and the strict check as soon as the host or the route says it is elsewhere.
    private var tlsFollowsHost: Bool
    private static func tlsMode(for connection: SavedConnection) -> TLSOptions.Mode {
        connection.isOnThisMac ? .off : TLSOptions().mode
    }
    /// The SSH and Proxy tab's Path line, which follows the draft as it is edited.
    weak var routePathLabel: NSTextField?
    let isNew: Bool
    let model: AppModel
    /// Typed in the General and SSH and Proxy tabs; empty: keep what the Keychain has.
    var password = "", proxyPassword = ""
    private(set) var tab = Tab.general
    let tabs = NSSegmentedControl()
    private let holder = NSView()
    let status = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, wraps: true)
    private(set) var testButton: NSButton!
    private var testTask: Task<Void, Never>?
    private let done: (SavedConnection, Bool) -> Void
    /// What the current tab's controls need kept: their targets (`bind`), the startup SQL's delegate.
    var bindings: [NSObject] = []
    private var retainUntilClosed: ConnectionEditor?
    static let width: CGFloat = 720
    /// Room around a tab inside its scroll view, which clips: a field's focus ring and borders draw outside the field.
    static let ringRoom: CGFloat = 4

    /// Shows the editor on `window`; `done` gets the saved connection and whether to connect now.
    @discardableResult
    static func show(_ connection: SavedConnection, isNew: Bool, model: AppModel, on window: NSWindow,
                     done: @escaping (SavedConnection, Bool) -> Void) -> ConnectionEditor {
        let editor = ConnectionEditor(connection, isNew: isNew, model: model, done: done)
        editor.retainUntilClosed = editor
        window.beginSheet(editor.window!)
        return editor
    }

    private init(_ connection: SavedConnection, isNew: Bool, model: AppModel, done: @escaping (SavedConnection, Bool) -> Void) {
        draft = connection
        if isNew { draft.tls.mode = Self.tlsMode(for: connection) }
        tlsFollowsHost = isNew
        self.isNew = isNew
        self.model = model
        self.done = done
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.title = isNew ? "New Connection" : "Edit “\(connection.displayName)”"
        window.autorecalculatesKeyViewLoop = true  // Tab goes through the fields of whichever tab is shown
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        show(.general)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent() -> NSView {
        tabs.segmentCount = Tab.allCases.count
        for tab in Tab.allCases {
            tabs.setLabel(tab.title, forSegment: tab.rawValue)
            tabs.setToolTip(tab.tip, forSegment: tab.rawValue)
        }
        tabs.trackingMode = .selectOne
        tabs.selectedSegmentBezelColor = .selectedSegment
        tabs.target = self
        tabs.action = #selector(tabChosen(_:))
        tabs.toolTip = "Choose which settings of the connection to show"
        tabs.setAccessibilityIdentifier("editor.tabs")
        tabs.translatesAutoresizingMaskIntoConstraints = false
        holder.translatesAutoresizingMaskIntoConstraints = false
        status.setAccessibilityIdentifier("editor.status")
        status.isSelectable = true  // a failed test's words, to copy
        status.preferredMaxLayoutWidth = Self.width - 40
        let buttons = buttonRow()
        let root = SurfaceView(.ground)
        [tabs, holder, status, buttons].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            holder.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: Spacing.double),
            holder.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20 - Self.ringRoom),
            holder.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20 + Self.ringRoom),
            status.topAnchor.constraint(equalTo: holder.bottomAnchor, constant: Spacing.double),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: status.bottomAnchor, constant: Spacing.double),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.double),
        ])
        return root
    }

    private func buttonRow() -> NSView {
        testButton = button("Test Connection", id: "editor.test", tip: "Connect with these settings, report each hop, then "
                            + "disconnect; nothing is saved", target: self, action: #selector(test(_:)))
        let cancel = button("Cancel", id: "editor.cancel", tip: "Close without saving: nothing changes", target: self,
                            action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = button("Save", id: "editor.save", tip: "Save the connection without connecting", target: self,
                          action: #selector(save(_:)))
        let connect = button("Save and Connect", id: "editor.saveAndConnect", tip: "Save the connection and connect to it",
                             target: self, action: #selector(saveAndConnect(_:)), primary: true)
        connect.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [helpButton(.connections), testButton, spacer, cancel, save, connect])
        row.spacing = Spacing.unit
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: Tabs

    @objc private func tabChosen(_ sender: NSSegmentedControl) {
        guard let chosen = Tab(rawValue: sender.selectedSegment) else { return }
        show(chosen)
    }

    /// Shows `tab`, its controls made afresh from the draft.
    func show(_ tab: Tab) {
        window?.makeFirstResponder(nil)  // a field being typed in keeps its text
        self.tab = tab
        tabs.selectedSegment = tab.rawValue
        bindings = []
        holder.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        switch tab {
        case .general: content = generalTab()
        case .tls: content = tlsTab()
        case .route: content = routeTab()
        case .options: content = optionsTab()
        case .safety: content = safetyTab()
        case .agents: content = agentsTab()
        }
        // In a scroll view: a tab can be taller than a small screen leaves room for (Options, with the connection's own
        // safety checks).
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        content.pin(to: document, insets: .all(Self.ringRoom))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        holder.addSubview(scroll)
        scroll.pin(to: holder)
        let height = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), height,
        ])
        tabContent = content
        tabHeight = height
        fitWindow()
    }

    /// What the tab shows, and its height: all of it, or `tabLimit` of the screen.
    private weak var tabContent: NSView?
    private(set) var tabHeight: NSLayoutConstraint?

    /// The most of a screen `height` points high (under the menu bar) a tab may take: its window's toolbar and the
    /// sheet's own rows take about 280 pt, so the sheet fits an 800 pt high screen.
    static func tabLimit(screen height: CGFloat) -> CGFloat { max(300, height - 280) }

    /// The sheet as tall as what the tab shows now.
    func fitWindow() {
        guard let window, let root = window.contentView else { return }
        if let tabContent, let tabHeight {
            let screen = (window.sheetParent?.screen ?? NSScreen.main)?.visibleFrame.height ?? 775
            tabHeight.constant = min(tabContent.fittingSize.height + 2 * Self.ringRoom, Self.tabLimit(screen: screen))
        }
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize
        var frame = window.frame
        frame.origin.y += frame.height - window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).height
        frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        window.setFrame(frame, display: true)
    }

    /// Shows the current tab again (after a choice that changes what it shows, such as the route).
    func refreshTab() { show(tab) }

    /// The socket of a server on this Mac, in the Socket field; a stat of each usual path, so off the main thread.
    @objc func findSocket(_ sender: Any?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = LocalServer.socket()
            DispatchQueue.main.async {
                guard let self else { return }
                if let found {
                    self.draft.socket = found
                    self.refreshTab()
                } else {
                    self.status.textColor = .secondaryLabelColor
                    self.status.stringValue = "No server's socket is in the usual places: use the host and port, or type its path."
                }
            }
        }
    }

    // MARK: Saving

    /// What keeps the draft from being saved, in words; nil when it can be.
    var problem: String? {
        if draft.route == .direct && draft.socket.isEmpty && draft.host.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Type the server's host name or address in the General tab, or its socket."
        }
        if draft.route != .direct && draft.host.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Type the database's host in the General tab, as the SSH host or proxy reaches it."
        }
        if draft.route == .proxy || draft.route == .sshProxy, draft.proxy.host.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Type the proxy's address in the SSH and Proxy tab."
        }
        return [.ssh, .sshJump, .sshProxy].contains(draft.route) ? SSHConfig.problem(with: draft) : nil
    }

    @objc private func save(_ sender: Any?) { finish(connect: false) }
    @objc private func saveAndConnect(_ sender: Any?) { finish(connect: true) }

    @objc private func cancel(_ sender: Any?) {
        testTask?.cancel()
        model.connector.cancelTest(draft.id)
        close(saved: nil, connect: false)
    }

    private func finish(connect: Bool) {
        window?.makeFirstResponder(nil)
        if let problem {
            status.textColor = .statusBad
            status.stringValue = problem
            return
        }
        // The gate (plan §2.8): an agent's Save keeps no password, and nothing the person alone may change.
        guard password.isEmpty && proxyPassword.isEmpty || !AgentGuard.refuses("Only the person at the Mac can save a "
                                                                                + "password: nothing was saved.") else { return }
        testTask?.cancel()
        model.connector.cancelTest(draft.id)
        model.save(draft)
        guard model.connection(draft.id) == draft else { return }  // refused (AgentGuard): the editor stays open
        let write = model.setSavedPassword, keys = (draft.id.uuidString, draft.proxySecretKey)
        let typed = (password, proxyPassword)
        // An existing password stays unless a new one was typed; the Keychain may wait for the person: not here.
        DispatchQueue.global(qos: .userInitiated).async {
            if !typed.0.isEmpty { write(keys.0, typed.0) }
            if !typed.1.isEmpty { write(keys.1, typed.1) }
        }
        close(saved: draft, connect: connect)
    }

    private func close(saved: SavedConnection?, connect: Bool) {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        retainUntilClosed = nil
        if let saved { done(saved, connect) }
    }

    // MARK: Test Connection

    @objc private func test(_ sender: Any?) {
        if testTask != nil {
            testTask?.cancel()
            model.connector.cancelTest(draft.id)
            return finishTest(nil, error: nil)
        }
        window?.makeFirstResponder(nil)
        if let problem {
            status.textColor = .statusBad
            status.stringValue = problem
            return
        }
        testButton.title = "Stop Test"
        testButton.toolTip = "Stop testing the connection"
        status.textColor = .secondaryLabelColor
        var done: [String] = [], current = "Starting", started = Date()
        func show() { status.stringValue = (done + [current + "…"]).joined(separator: " · ") }
        show()
        let draft = self.draft, password = password.isEmpty ? nil : password, proxy = proxyPassword.isEmpty ? nil : proxyPassword
        testTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.model.connector.test(draft, password: password, proxyPassword: proxy,
                                                                 on: self.window) { step in
                    done.append("✓ " + current + " \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                    (current, started) = (step, Date())
                    show()
                }
                guard !Task.isCancelled else { return }
                self.draft.tls.pinnedFingerprint = result.draft.tls.pinnedFingerprint
                self.finishTest((done + ["✓ " + result.summary]).joined(separator: " · "), error: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self.finishTest((done + ["✗ " + current]).joined(separator: " · "), error: error)
            }
        }
    }

    private func finishTest(_ report: String?, error: Error?) {
        testTask = nil
        testButton.title = "Test Connection"
        testButton.toolTip = "Connect with these settings, report each hop, then disconnect; nothing is saved"
        guard let report else { return status.stringValue = "" }
        let failure = error as? AirSQLError
        if failure?.kind == .cancelled { return status.stringValue = "" }
        status.textColor = error == nil ? .statusOK : .statusBad
        status.stringValue = report + (error.map { "\n" + $0.localizedDescription } ?? "")
        announce(status.stringValue)
        if tab == .tls { refreshTab() }  // a certificate trusted meanwhile
    }

    func windowWillClose(_ notification: Notification) { testTask?.cancel() }
}
