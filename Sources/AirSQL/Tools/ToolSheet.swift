import AirSQLCore
import AppKit

/// What the client tools' sheets (Export, Restore and Run SQL File, Copy to Another Server, Import CSV) share: a heading,
/// the sheet's own form, the command line or what will run, a progress row and the buttons. Work runs off the main
/// thread and is listed in the status bar's Activity with Cancel (plan §2.11); while it runs, the sheet's controls are
/// off with a tooltip saying why, and Cancel becomes Stop.
@MainActor
class ToolSheet: NSWindowController {
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
    let runButton: NSButton
    let cancelButton: NSButton
    private(set) var running = false
    private var cancellation: Cancellation?
    private var activity: Activity?
    private var started = Date()
    private var retained: ToolSheet?

    init(model: AppModel, connection: SavedConnection, options: ConnectOptions, width: CGFloat, action: String, actionTip: String) {
        self.model = model
        self.connection = connection
        self.options = options
        self.width = width
        runButton = button(action, id: "tools.run", tip: actionTip, target: nil, action: nil, primary: true)
        cancelButton = button("Cancel", id: "tools.cancel", tip: "Close the sheet: nothing runs", target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled], backing: .buffered,
                              defer: true)
        super.init(window: window)
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
    /// Buttons left of the spacer, after the help button (Copy Command).
    func extraButtons() -> [NSButton] { [] }
    /// Loads what the form needs (databases, tables, tools), off the main thread; called once the sheet is shown.
    func load() {}
    /// Runs the work (Export, Restore…): call `begin`, then `finish`.
    func run() {}
    /// Turns the form's controls on or off while work runs.
    func setFormEnabled(_ enabled: Bool) {}

    // MARK: Showing

    /// Shows the sheet on `parent` and loads what it needs (tests fill it themselves: `loads` false).
    func show(on parent: NSWindow, loads: Bool = true) {
        guard let window else { return }
        window.contentView = makeContent()
        window.setContentSize(window.contentView!.fittingSize)
        window.initialFirstResponder = runButton
        window.autorecalculatesKeyViewLoop = true  // Tab goes through every control, in order
        retained = self
        parent.beginSheet(window)
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
        let row = NSStackView(views: [helpButton(.clientTools)] + extraButtons() + [spacer, cancelButton, runButton])
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
        cancelButton.toolTip = "Close the sheet"
        runButton.isEnabled = true
        updateRunButton()
    }

    /// A step of the work is over and nothing more runs until the person says so (the check before a restore): the
    /// sheet as it was before `begin`.
    func idle() {
        running = false
        cancellation = nil
        activity?.end()
        activity = nil
        bar.stopAnimation(nil)
        bar.isHidden = true
        status.stringValue = ""
        timeLeft.stringValue = ""
        setFormEnabled(true)
        cancelButton.title = "Cancel"
        cancelButton.toolTip = "Close the sheet: nothing runs"
        runButton.isEnabled = true
        updateRunButton()
    }

    /// Sets the run button's state from the form (subclasses: what is missing, in its tooltip).
    func updateRunButton() {}

    @objc private func runPressed(_ sender: Any?) {
        guard !running, runButton.isEnabled else { return }
        run()
    }

    @objc private func cancelPressed(_ sender: Any?) {
        if running {
            cancellation?.cancel()
            activity?.cancel()
            status.stringValue = "Stopping…"
            return
        }
        close()
    }

    /// Ends the sheet.
    override func close() {
        if let sheet = window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        retained = nil
    }

    // MARK: Words

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
