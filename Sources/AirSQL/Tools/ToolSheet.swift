import AirSQLCore
import AppKit

/// What the client tools' sheets (Export, Restore and Run SQL File, Copy to Another Server, Import CSV) share: a heading,
/// the sheet's own form, the command line or what will run, a progress row and the buttons. Work runs off the main
/// thread and is listed in the status bar's Activity with Cancel (plan §2.11); while it runs, the sheet's controls are
/// off with a tooltip saying why, and Cancel becomes Stop. Each is a window of its own, to move aside and keep working in
/// the main window; closing it, disconnecting and quitting ask first while its work runs.
@MainActor
class ToolSheet: NSWindowController, NSWindowDelegate {
    /// The tools' windows open now, which also keeps them until they close.
    private(set) static var open: [ToolSheet] = []
    /// Those whose work uses one of `ids`.
    static func running(on ids: [UUID]) -> [ToolSheet] { open.filter { $0.running && !$0.connections.isDisjoint(with: ids) } }

    let model: AppModel
    let connection: SavedConnection
    let options: ConnectOptions
    let width: CGFloat

    let heading = label("", font: .systemFont(ofSize: 14, weight: .semibold), wraps: true)
    /// What the work is doing, or how it ended (an error in red); selectable, so an error can be copied.
    let status = label("", font: .systemFont(ofSize: 12), wraps: true)
    let timeLeft = label("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    let bar = NSProgressIndicator()
    let spinner = NSProgressIndicator()
    /// Shown when the tool chosen can't run: AirSQL's own way checks the certificate as the connection does.
    let useBuiltIn = button("Use AirSQL's Built-in", id: "tools.useBuiltIn",
                            tip: "Switch to AirSQL's own way, which checks the server's certificate as the connection does",
                            target: nil, action: nil)
    private weak var toolPopup: NSPopUpButton?
    /// Run once without the certificate check, when the tool can't make it (`ToolCommand.mayRunUnchecked`): unticked by
    /// default, never saved, cleared after each run and when the tool changes.
    let unchecked = checkbox("Run without checking the certificate", id: "tools.unchecked", tip: "", on: false, target: nil, action: nil)
    let runButton: NSButton
    let cancelButton: NSButton
    private(set) var running = false
    private var cancellation: Cancellation?
    private var activity: Activity?
    private var started = Date()
    /// The main window it was opened from.
    private(set) weak var opener: NSWindow?

    init(model: AppModel, connection: SavedConnection, options: ConnectOptions, width: CGFloat, action: String, actionTip: String) {
        self.model = model
        self.connection = connection
        self.options = options
        self.width = width
        runButton = button(action, id: "tools.run", tip: actionTip, target: nil, action: nil, primary: true)
        cancelButton = button("Cancel", id: "tools.cancel", tip: "Close the window: nothing runs", target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        useBuiltIn.target = self
        useBuiltIn.action = #selector(useBuiltInPressed(_:))
        useBuiltIn.isHidden = true
        runButton.target = self
        runButton.action = #selector(runPressed(_:))
        runButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.keyEquivalent = "\u{1b}"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: For the sheets

    /// The sheet's form, between the heading and the command box.
    func makeForm() -> NSView { NSView() }
    /// The command line or SQL shown under the form (nil: none).
    func makeCodeBox() -> NSView? { nil }
    /// The page of AirSQL Help the sheet's ? button opens.
    var helpPage: HelpPage { .clientTools }
    /// Buttons left of the spacer, after the help button (Copy Command).
    func extraButtons() -> [NSButton] { [] }
    /// Loads what the form needs (databases, tables, tools), off the main thread; called once the sheet is shown.
    func load() {}
    /// Runs the work (Export, Restore…): call `begin`, then `finish`.
    func run() {}
    /// Turns the form's controls on or off while work runs.
    func setFormEnabled(_ enabled: Bool) {}
    /// Whether the work writes to `connection`, so a connection made read-only since the window opened stops it.
    var writes: Bool { false }
    /// What the tick box risks (Export and Restore's).
    var uncheckedTip: String { "" }
    /// The saved connections the work goes through.
    var connections: Set<UUID> { [connection.id] }

    // MARK: Showing

    /// Shows the window over `parent` and loads what it needs (tests fill it themselves: `loads` false); the same tool
    /// for the same connection, already open, comes to the front instead.
    func show(on parent: NSWindow, loads: Bool = true) {
        guard let window else { return }
        window.title = heading.stringValue
        if let same = Self.open.first(where: { $0.opener === parent && $0.connection.id == connection.id && $0.window?.title == window.title }) {
            same.window?.makeKeyAndOrderFront(nil)
            return
        }
        window.contentView = makeContent()
        window.setContentSize(window.contentView!.fittingSize)
        window.initialFirstResponder = runButton
        window.autorecalculatesKeyViewLoop = true  // Tab goes through every control, in order
        opener = parent
        Self.open.append(self)
        window.setFrameTopLeftPoint(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.maxY - 52))
        window.makeKeyAndOrderFront(nil)
        if loads { load() }
    }

    private func makeContent() -> NSView {
        heading.setAccessibilityIdentifier("tools.heading")
        status.setAccessibilityIdentifier("tools.status")
        status.isSelectable = true
        timeLeft.setAccessibilityIdentifier("tools.timeLeft")
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.isHidden = true
        bar.toolTip = "How far the work has got"
        bar.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let progressText = NSStackView(views: [spinner, status, NSView(), timeLeft])
        progressText.alignment = .firstBaseline
        progressText.spacing = Spacing.unit
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [heading, makeForm()]
        if let code = makeCodeBox() { views.append(code) }
        views += [progressText, bar, buttonRow()]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: progressText)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let root = SurfaceView(.ground)
        root.addSubview(stack)
        stack.pin(to: root, insets: NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20))
        root.widthAnchor.constraint(equalToConstant: width).isActive = true
        return root
    }

    private func buttonRow() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [helpButton(helpPage)] + extraButtons() + [spacer, cancelButton, runButton])
        row.spacing = Spacing.unit
        return row
    }

    /// A box of monospaced, selectable text (the command line, the SQL to run), `lines` lines tall at most.
    func codeBox(id: String, tip: String, lines: CGFloat = 4) -> (NSView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.setAccessibilityIdentifier(id)
        text.toolTip = tip
        let line = text.layoutManager?.defaultLineHeight(for: text.font!) ?? 15
        let box = SurfaceView(.content, radius: Radius.control, border: .separatorColor)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        scroll.pin(to: box, insets: .all(Radius.control))
        box.heightAnchor.constraint(equalToConstant: ceil(line * lines) + 8 + 2 * Radius.control).isActive = true
        return (box, text)
    }

    // MARK: The Tool pop-up

    /// Fills a Tool pop-up: `tools` (two can have one title: the menu's own `addItem` would drop one), then AirSQL's own
    /// way, `builtIn` saying what that does.
    func fill(_ menu: NSPopUpButton, tools: [ClientTool], builtIn: String) {
        toolPopup = menu
        menu.removeAllItems()
        for tool in tools { menu.menu?.addItem(withTitle: tool.title, action: nil, keyEquivalent: "").toolTip = tool.path }
        menu.menu?.addItem(withTitle: "AirSQL (built in)", action: nil, keyEquivalent: "").toolTip = builtIn
    }

    /// The Tool pop-up's note with, under it, the way out when the tool chosen can't run (`useBuiltIn`).
    func toolNote(_ note: NSTextField) -> NSView {
        unchecked.isHidden = true
        unchecked.toolTip = uncheckedTip
        let stack = NSStackView(views: [note, unchecked, useBuiltIn])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    /// `tool`'s command for this run, with the tick box's answer.
    func toolCommand(_ tool: ClientTool, server: ServerInfo?) -> ToolCommand {
        var command = ToolCommand(tool: tool, options: options, server: server)
        command.uncheckedCertificate = unchecked.state == .on
        return command
    }

    /// Shows the tick box if the tool may use it, and warns while it is ticked.
    func showUnchecked(_ command: ToolCommand?, note: NSTextField) {
        unchecked.isHidden = command?.mayRunUnchecked != true
        guard command?.uncheckedNote != nil else { return }
        note.stringValue = "This run won't check the server's certificate: it needs TLS, but can't prove which server it reaches."
        note.textColor = .statusWarning
    }

    /// Notes a run without the check in the SQL log, off the main thread.
    func logUnchecked(_ command: ToolCommand?) {
        guard let text = command?.uncheckedNote else { return }
        let context = connection.displayName + " tools"
        DispatchQueue.global(qos: .utility).async { SQLLog.shared.note(text, context: context) }
    }

    @objc private func useBuiltInPressed(_ sender: Any?) {
        guard let toolPopup else { return }
        toolPopup.selectItem(at: toolPopup.numberOfItems - 1)
        toolPopup.sendAction(toolPopup.action, to: toolPopup.target)
    }

    /// Asks for a program anywhere on this Mac, starting in Homebrew's folder, which Finder hides; `done` gets it with
    /// its version.
    func chooseProgram(_ kind: ClientTool.Kind, done: @escaping (ClientTool) -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/opt")
        panel.message = "Choose the \(kind.names.joined(separator: " or ")) program."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let path = panel.url?.path else { return }
            Task { @MainActor in
                if let tool = await ClientTools.find(kind, chosen: path, folders: []).first { done(tool) }
            }
        }
    }

    // MARK: Running

    /// Says what the sheet is doing while it loads (a spinner), or that it is ready (nil).
    func loading(_ text: String?) {
        spinner.isHidden = text == nil
        if text != nil { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        status.textColor = .labelColor
        status.stringValue = text ?? ""
    }

    /// Work starts: listed in Activity with Cancel, the form off, Cancel turned into Stop. Returns its cancellation.
    func begin(_ title: String) -> Cancellation {
        let cancellation = Cancellation()
        self.cancellation = cancellation
        running = true
        started = Date()
        activity = model.activity.start(title, connection: connection.id) { cancellation.cancel() }
        setFormEnabled(false)
        unchecked.isEnabled = false
        runButton.isEnabled = false
        runButton.toolTip = "It is running: wait for it, or Stop it"
        cancelButton.title = "Stop"
        cancelButton.toolTip = "Stop it now: what has run stays run"
        bar.isHidden = false
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        loading(nil)
        timeLeft.stringValue = ""
        status.stringValue = "Starting…"
        return cancellation
    }

    /// Shows how far the work has got: `done` of `total` (nil: unknown) and what it is doing.
    func progress(_ text: String, done: Int64, total: Int64?) {
        status.stringValue = text
        activity?.detail = text
        guard let total, total > 0 else {
            timeLeft.stringValue = ActivityPopover.elapsed(Date().timeIntervalSince(started)) + " so far"
            return
        }
        let share = min(Double(done) / Double(total), 0.99)
        bar.isIndeterminate = false
        bar.doubleValue = share
        activity?.progress = share
        let elapsed = Date().timeIntervalSince(started)
        if share > 0.02, elapsed > 2 {
            timeLeft.stringValue = "about " + ActivityPopover.elapsed(elapsed / share - elapsed) + " left"
        }
    }

    /// The work ended: `message` says how (in red when it failed), and the sheet can run again or be closed.
    func finish(_ message: String, failed: Bool) {
        running = false
        if unchecked.state == .on {
            unchecked.state = .off  // each run is ticked anew
            unchecked.sendAction(unchecked.action, to: unchecked.target)
        }
        unchecked.isEnabled = true
        cancellation = nil
        activity?.end()
        activity = nil
        bar.stopAnimation(nil)
        bar.isIndeterminate = false
        bar.doubleValue = failed ? bar.doubleValue : 1
        bar.isHidden = failed
        timeLeft.stringValue = failed ? "" : "in " + ActivityPopover.elapsed(Date().timeIntervalSince(started))
        status.stringValue = message
        status.textColor = failed ? .statusBad : .labelColor
        setFormEnabled(true)
        cancelButton.title = "Close"
        cancelButton.toolTip = "Close the window"
        runButton.isEnabled = true
        updateRunButton()
    }

    /// A step of the work is over and nothing more runs until the person says so (the check before a restore): the
    /// sheet as it was before `begin`.
    func idle() {
        running = false
        unchecked.isEnabled = true
        cancellation = nil
        activity?.end()
        activity = nil
        bar.stopAnimation(nil)
        bar.isHidden = true
        status.stringValue = ""
        timeLeft.stringValue = ""
        setFormEnabled(true)
        cancelButton.title = "Cancel"
        cancelButton.toolTip = "Close the window: nothing runs"
        runButton.isEnabled = true
        updateRunButton()
    }

    /// Sets the run button's state from the form (subclasses: what is missing, in its tooltip).
    func updateRunButton() {}

    @objc private func runPressed(_ sender: Any?) {
        guard !running, runButton.isEnabled else { return }
        // Going without the check is the person's call (plan §2.8).
        if unchecked.state == .on, AgentGuard.refuses("Only the person at the Mac can run without checking the certificate.") { return }
        if writes, model.connection(connection.id)?.readOnly == true {
            return finish("\(connection.displayName) is read-only now: turn that off in the connection's settings to write to it",
                          failed: true)
        }
        run()
    }

    @objc private func cancelPressed(_ sender: Any?) {
        if running { stop() } else { close() }
    }

    /// Stops the work: what has run stays run.
    func stop() {
        cancellation?.cancel()
        activity?.cancel()
        status.stringValue = "Stopping…"
    }

    /// Ends the window.
    override func close() {
        Self.open.removeAll { $0 === self }
        super.close()
    }

    /// The close button and Close Window: work under way asks first, and `close` does the rest, as Cancel's does.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard running else {
            close()
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Stop “\(sender.title)”?"
        alert.informativeText = "It is still running. If you stop it, what has run stays run."
        alert.addButton(withTitle: "Keep Running").toolTip = "Let the work finish"
        alert.addButton(withTitle: "Stop").toolTip = "Stop the work now: what has run stays run"
        alert.beginSheetModal(for: sender) { [weak self] in
            if $0 == .alertSecondButtonReturn, self?.running == true { self?.stop() }
        }
        return false
    }

    /// ⌘W: the main menu's Close Tab closes this window while it is in front.
    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }

    // MARK: Words

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
