import AirSQLCore
import AppKit

/// The document editor (mongo-plan, Safe editing): a field's value, or a whole new document, in shell form in a sheet.
/// For a field, the Type pop-up keeps its type (the text read as one, as the grid's editor reads it) or changes it to
/// the type chosen: the only way a field's type changes. Keep (⌘↩) hands the text and the type chosen (nil: keep it) to
/// `keep`, which makes it a pending change or says why not, under the text; nothing is written to the server here. The
/// text autofills (`MongoAutofill`) with what `complete` offers.
@MainActor
final class MongoValueSheet: NSWindowController, NSTextViewDelegate {
    /// The types the pop-up offers, as `$type` names them.
    static let types = ["string", "int", "long", "double", "decimal", "bool", "date", "objectId", "object", "array", "null"]

    let textView: NSTextView
    let type: NSPopUpButton?
    private let problem = label("", font: .systemFont(ofSize: 12), color: .statusBad, wraps: true)
    private let keep: (_ text: String, _ type: String?) -> String?
    private let complete: MongoAutofill.Complete?
    let autofill = MongoAutofill()
    private var retainUntilClosed: MongoValueSheet?

    /// Shows the sheet on `window`; `type` is the field's type now (nil: a whole document, no pop-up).
    @discardableResult
    static func show(title: String, caption: String, text: String, type: String?, on window: NSWindow,
                     complete: MongoAutofill.Complete? = nil,
                     keep: @escaping (_ text: String, _ type: String?) -> String?) -> MongoValueSheet {
        let sheet = MongoValueSheet(title: title, caption: caption, text: text, type: type, complete: complete, keep: keep)
        window.beginSheet(sheet.window!)
        sheet.retainUntilClosed = sheet
        return sheet
    }

    /// A value of `type` for `MongoChanges.value(_:keeping:)` to read the text as.
    static func template(_ type: String) -> BSONValue {
        switch type {
        case "string": return .string("")
        case "int": return .int32(0)
        case "long": return .int64(0)
        case "double": return .double(0)
        case "decimal": return .decimal128(BSONDecimal128("0")!)
        case "bool": return .bool(false)
        case "date": return .datetime(0)
        case "objectId": return .objectId(BSONObjectId.generate())
        case "object": return .document(BSONDocument())
        case "array": return .array([])
        default: return .null
        }
    }

    private init(title: String, caption: String, text: String, type: String?, complete: MongoAutofill.Complete?,
                 keep: @escaping (String, String?) -> String?) {
        self.keep = keep
        self.complete = complete
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.setAccessibilityIdentifier("mongoValue.text")
        textView.toolTip = "The value in shell form: \"text\", 42, NumberLong(42), ISODate(\"…\"), [ … ], { … }; ⌥⎋ lists what fits here"
        if let type {
            let titles = ["Keep \(type)"] + Self.types.map { "Change to \($0)" }
            self.type = popup(titles, selected: 0, id: "mongoValue.type",
                              tip: "Keep the field's type, reading the text as one, or change it to another type", target: nil, action: nil)
            self.type?.menu?.insertItem(.separator(), at: 1)
        } else {
            self.type = nil
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = title
        super.init(window: window)
        let heading = label(title, font: .systemFont(ofSize: 14, weight: .semibold), wraps: true)
        let note = label(caption, font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, wraps: true)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        problem.setAccessibilityIdentifier("mongoValue.problem")
        problem.isSelectable = true
        problem.isHidden = true
        let cancel = button("Cancel", id: "mongoValue.cancel", tip: "Close this and change nothing", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = button("Keep", id: "mongoValue.keep", tip: "Keep this as a pending change; Apply writes it (⌘↩)", target: self,
                        action: #selector(keepText(_:)), primary: true)
        ok.keyEquivalent = "\r"
        ok.keyEquivalentModifierMask = .command
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, ok])
        var views: [NSView] = [heading, note, scroll]
        if let type = self.type {
            let row = NSStackView(views: [label("Type:"), type])
            row.alignment = .firstBaseline
            views.append(row)
        }
        views += [problem, buttons]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: heading)
        for view in [heading, note, scroll, problem, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let root = SurfaceView(.ground)
        root.addSubview(stack)
        stack.pin(to: root, insets: NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20))
        root.widthAnchor.constraint(equalToConstant: 560).isActive = true
        window.contentView = root
        window.setContentSize(root.fittingSize)
        window.initialFirstResponder = textView
        textView.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func textDidChange(_ notification: Notification) {
        if let complete { autofill.textChanged(textView, complete) }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let complete else { return false }
        return autofill.command(selector, in: textView, complete)
    }

    /// The type chosen in the pop-up; nil: keep the field's.
    var chosenType: String? {
        guard let type, type.indexOfSelectedItem > 1 else { return nil }
        return Self.types[type.indexOfSelectedItem - 2]
    }

    @objc func keepText(_ sender: Any?) {
        if let refusal = keep(textView.string, chosenType) {
            NSSound.beep()
            problem.stringValue = refusal
            problem.isHidden = false
            return
        }
        finish()
    }

    /// Cancel, or Esc: with autofill's list open, Esc closes only the list.
    @objc func cancel(_ sender: Any?) {
        if autofill.isShown { return autofill.close() }
        finish()
    }

    private func finish() {
        autofill.close()
        if let sheet = window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        retainUntilClosed = nil
    }
}
