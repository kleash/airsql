import AirSQLCore
import AppKit

/// Update Many… and Delete Many…'s first sheet (mongo-plan, Phase 2 bulk): the filter, and for an update its operators
/// or pipeline, in shell form. Preview… (⌘↩) hands them to `next`, which counts the documents and shows the command in
/// the preview sheet, or says under the text why it can't; nothing is written here.
@MainActor
final class MongoBulkSheet: NSWindowController {
    let filter: NSTextField
    /// The update's text; nil for a delete.
    let update: NSTextView?
    private let problem = label("", font: .systemFont(ofSize: 12), color: .statusBad, wraps: true)
    private let next: (_ filter: String, _ update: String?) -> String?
    private var retainUntilClosed: MongoBulkSheet?

    @discardableResult
    static func show(title: String, caption: String, filter: String, update: String?, on window: NSWindow,
                     next: @escaping (_ filter: String, _ update: String?) -> String?) -> MongoBulkSheet {
        let sheet = MongoBulkSheet(title: title, caption: caption, filter: filter, update: update, next: next)
        window.beginSheet(sheet.window!)
        sheet.retainUntilClosed = sheet
        return sheet
    }

    private init(title: String, caption: String, filter text: String, update: String?, next: @escaping (String, String?) -> String?) {
        self.next = next
        filter = textField(text, placeholder: "{ field: \"value\" }   every document when empty", id: "mongoBulk.filter",
                           tip: "Which documents to change, in shell form: { status: \"old\" }; empty matches every document")
        filter.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        var scroll: NSScrollView?
        if let update {
            let made = NSTextView.scrollableTextView()
            let text = made.documentView as! NSTextView
            text.string = update
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.isRichText = false
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.isAutomaticTextReplacementEnabled = false
            text.textContainerInset = NSSize(width: 6, height: 6)
            text.setAccessibilityIdentifier("mongoBulk.update")
            text.setAccessibilityLabel("Update")
            text.toolTip = "The change, in shell form: operators such as { $set: { status: \"new\" } }, or a pipeline [ { $set: … } ]"
            made.translatesAutoresizingMaskIntoConstraints = false
            made.borderType = .bezelBorder
            made.heightAnchor.constraint(equalToConstant: 140).isActive = true
            (self.update, scroll) = (text, made)
        } else {
            self.update = nil
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = title
        super.init(window: window)
        filter.target = self
        filter.action = #selector(preview(_:))
        let heading = label(title, font: .systemFont(ofSize: 14, weight: .semibold), wraps: true)
        let note = label(caption, font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, wraps: true)
        let form = Form()
        form.row("Filter", [filter])
        if let scroll { form.row("Update", [scroll]) }
        let grid = form.finish()
        filter.widthAnchor.constraint(equalToConstant: 480).isActive = true
        scroll?.widthAnchor.constraint(equalTo: filter.widthAnchor).isActive = true
        problem.setAccessibilityIdentifier("mongoBulk.problem")
        problem.isSelectable = true
        problem.isHidden = true
        let cancel = button("Cancel", id: "mongoBulk.cancel", tip: "Close this and change nothing", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = button("Preview…", id: "mongoBulk.preview", tip: "Count the documents the filter matches now and show the command "
                        + "before it runs (⌘↩)", target: self, action: #selector(preview(_:)), primary: true)
        ok.keyEquivalent = "\r"
        ok.keyEquivalentModifierMask = .command
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, ok])
        let stack = NSStackView(views: [heading, note, grid, problem, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: heading)
        for view in [heading, note, problem, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let root = SurfaceView(.ground)
        root.addSubview(stack)
        stack.pin(to: root, insets: NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20))
        root.widthAnchor.constraint(equalToConstant: 600).isActive = true
        window.contentView = root
        window.setContentSize(root.fittingSize)
        window.initialFirstResponder = self.update ?? filter
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc func preview(_ sender: Any?) {
        if let refusal = next(filter.stringValue, update?.string) {
            NSSound.beep()
            problem.stringValue = refusal
            problem.isHidden = false
            return
        }
        finish()
    }

    @objc func cancel(_ sender: Any?) { finish() }

    private func finish() {
        if let sheet = window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        retainUntilClosed = nil
    }
}
