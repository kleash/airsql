import AirSQLCore
import AppKit

/// A collection tab's query bar (mongo-plan, Query bar): the find's filter, projection, sort, skip, limit, collation,
/// hint and max time, each typed in shell form; Run (⌘↩ or Return in a field), a spinner while it reads, the history and
/// favourites, and what's wrong with a field said under them. The filter, projection, sort, collation and hint autofill
/// (`MongoAutofill`) with what the collection tab's `complete` offers.
@MainActor
final class MongoQueryBar: NSView, NSTextFieldDelegate {
    let filter = AirSQL.textField("", placeholder: "{ field: \"value\" }   every document when empty", id: "mongo.filter",
                           tip: "Which documents to find, in shell form: { age: { $gt: 30 } }; Esc lists what fits here")
    let projection = AirSQL.textField("", placeholder: "{ field: 1 }", id: "mongo.projection",
                               tip: "Which fields to show: { name: 1 } keeps name, { notes: 0 } leaves notes out")
    let sort = AirSQL.textField("", placeholder: "{ field: -1 }", id: "mongo.sort", tip: "The order: { age: -1 } is oldest first")
    let skip = AirSQL.textField("", placeholder: "0", id: "mongo.skip", tip: "How many documents to pass over first", width: 64)
    let limit = AirSQL.textField("", placeholder: "none", id: "mongo.limit", tip: "The most documents to find", width: 64)
    let collation = AirSQL.textField("", placeholder: "{ locale: \"en\", strength: 2 }", id: "mongo.collation",
                              tip: "How strings compare: { locale: \"en\", strength: 2 } ignores case")
    let hint = AirSQL.textField("", placeholder: "index name or { field: 1 }", id: "mongo.hint", tip: "The index the server must use")
    let maxTime = AirSQL.textField("", placeholder: "none", id: "mongo.maxTime",
                            tip: "Milliseconds the server may spend on the find before it stops it", width: 80)
    let run = button("Run", id: "mongo.run", tip: Commands.runStatement.tip, target: nil, action: Commands.runStatement.action, primary: true)
    let history = NSPopUpButton(frame: .zero, pullsDown: true)
    let spinner = NSProgressIndicator()
    let problem = label("", font: .systemFont(ofSize: 11.5), color: .statusBad, wraps: true)
    /// Autofill's suggestions for a field's text at a caret.
    var complete: ((MongoCaret.Root, String, Int) -> (Range<Int>, [CompletionItem]))?
    let autofill = MongoAutofill()
    /// Return in a field.
    var onRun: (() -> Void)?
    private var fields: [(name: String, field: NSTextField)] {
        [("Filter", filter), ("Project", projection), ("Sort", sort), ("Skip", skip), ("Limit", limit), ("Collation", collation),
         ("Hint", hint), ("Max Time", maxTime)]
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("mongo.queryBar")
        run.toolTip = "Find the documents the fields describe (⌘↩)"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Reading documents")
        history.addItem(withTitle: "")
        history.item(at: 0)?.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Query History")
        (history.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        history.isBordered = false
        history.toolTip = "Run a query again, or keep this one among the favourites (⌘Y)"
        history.setAccessibilityIdentifier("mongo.history")
        problem.setAccessibilityIdentifier("mongo.problem")
        problem.isSelectable = true
        problem.isHidden = true
        for (_, field) in fields {
            field.delegate = self
            field.target = self
            field.action = #selector(returnPressed(_:))
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        // Each field after its name, which VoiceOver reads with it.
        func named(_ field: NSTextField, _ text: String) -> [NSView] {
            let name = label(text, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            field.setAccessibilityTitleUIElement(name)
            return [name, field]
        }
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views)
            row.spacing = Spacing.unit
            return row
        }
        let first = row(named(filter, "Filter") + [run, spinner, history])
        let second = row(named(projection, "Project") + named(sort, "Sort") + named(skip, "Skip") + named(limit, "Limit"))
        let third = row(named(collation, "Collation") + named(hint, "Hint") + named(maxTime, "Max Time")
                        + [label("ms", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)])
        projection.widthAnchor.constraint(equalTo: sort.widthAnchor).isActive = true
        collation.widthAnchor.constraint(equalTo: hint.widthAnchor).isActive = true
        let stack = NSStackView(views: [first, second, third, problem])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: Spacing.double, bottom: 8, right: Spacing.double)
        for view in stack.arrangedSubviews where view !== problem {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Spacing.double).isActive = true
        }
        problem.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Spacing.double).isActive = true
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        let ground = SurfaceView(.bar)
        addSubview(ground)
        ground.pin(to: self)
        addSubview(stack)
        stack.pin(to: self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The fields as typed.
    var query: MongoQueryText {
        get {
            MongoQueryText(filter: filter.stringValue, projection: projection.stringValue, sort: sort.stringValue, limit: limit.stringValue,
                           skip: skip.stringValue, collation: collation.stringValue, hint: hint.stringValue, maxTimeMS: maxTime.stringValue)
        }
        set {
            filter.stringValue = newValue.filter
            projection.stringValue = newValue.projection
            sort.stringValue = newValue.sort
            limit.stringValue = newValue.limit
            skip.stringValue = newValue.skip
            collation.stringValue = newValue.collation
            hint.stringValue = newValue.hint
            maxTime.stringValue = newValue.maxTimeMS
        }
    }

    var busy = false {
        didSet { if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) } }
    }

    /// Says what's wrong with a field under the fields, and puts the keyboard there; nil clears it.
    func show(_ problem: MongoQueryText.Problem?) {
        self.problem.stringValue = problem.map { "\($0.field): \($0.message)" } ?? ""
        self.problem.isHidden = problem == nil
        guard let problem, let field = fields.first(where: { $0.name == problem.field })?.field else { return }
        window?.makeFirstResponder(field)
    }

    @objc private func returnPressed(_ sender: Any?) { onRun?() }

    // MARK: Autofill

    /// What a field's text is; nil: a number, without autofill.
    func root(of control: NSControl) -> MongoCaret.Root? {
        [(filter, MongoCaret.Root.filter), (projection, .projection), (sort, .sort), (collation, .collation), (hint, .hint)]
            .first { $0.0 === control }?.1
    }

    private func completer(_ control: NSControl) -> MongoAutofill.Complete? {
        guard let root = root(of: control), let complete else { return nil }
        return { complete(root, $0, $1) }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let control = notification.object as? NSControl, let complete = completer(control),
              let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
        autofill.textChanged(editor, complete)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let complete = completer(control) else { return false }
        return autofill.command(selector, in: textView, complete)
    }

    func controlTextDidEndEditing(_ notification: Notification) { autofill.close() }
}
