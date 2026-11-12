import AirSQLCore
import AppKit

/// The aggregation tab's SQL mode (mongo-plan, Phase 5 C): a SELECT in the console's SQL editor, translated by
/// `MongoSQL` into the tab's pipeline, which shows under it read-only with the notes that apply. Translating replaces the
/// pipeline text (asking first when it was edited by hand); the pipeline is what runs.
@MainActor
final class MongoSQLPage: NSView {
    private unowned let tab: MongoAggregationController
    let scroll: NSScrollView
    let editor: SQLEditorView
    let pipeline = NSTextView()
    let notes = label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: true)
    private(set) lazy var translateButton = button("Translate", id: "aggregate.sql.translate",
                                                   tip: "Write the SELECT as a pipeline in this tab, without running it",
                                                   target: self, action: #selector(translatePressed(_:)))
    private(set) lazy var stagesButton = button("Open as Stages", id: "aggregate.sql.stages",
                                                tip: "Write the SELECT as a pipeline and show its stages as cards to go on with",
                                                target: self, action: #selector(openAsStages(_:)))

    init(tab: MongoAggregationController) {
        self.tab = tab
        (scroll, editor) = SQLEditorView.make(fontSize: CGFloat(tab.model.data.settings.editorFontSize))
        super.init(frame: .zero)
        setAccessibilityIdentifier("aggregate.sqlPage")
        editor.setAccessibilityIdentifier("aggregate.sql")
        editor.setAccessibilityLabel("SQL query of \(tab.collection)")
        editor.toolTip = "Write a SELECT … FROM \(tab.collection) with JOIN, WHERE, GROUP BY, ORDER BY, LIMIT; Run (⌘↩) translates and runs it"
        editor.onChange = { [weak self] in self?.editor.runProblem = nil }

        pipeline.isEditable = false
        pipeline.isSelectable = true
        pipeline.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        pipeline.textColor = .labelColor
        pipeline.backgroundColor = .ground
        pipeline.textContainerInset = NSSize(width: 6, height: 4)
        pipeline.setAccessibilityIdentifier("aggregate.sql.pipeline")
        pipeline.setAccessibilityLabel("The pipeline the SQL translates to")
        pipeline.toolTip = "The MongoDB pipeline this SQL becomes: it is what runs"
        let pipelineScroll = NSScrollView()
        pipelineScroll.documentView = pipeline
        pipeline.autoresizingMask = [.width]
        pipelineScroll.hasVerticalScroller = true
        pipelineScroll.autohidesScrollers = true
        pipelineScroll.borderType = .noBorder
        notes.setAccessibilityIdentifier("aggregate.sql.notes")
        notes.isHidden = true

        let heading = label("As a MongoDB pipeline", font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
        let bar = NSStackView(views: [translateButton, stagesButton, NSView(), heading])
        bar.spacing = Spacing.unit
        bar.edgeInsets = NSEdgeInsets(top: 4, left: Spacing.double, bottom: 4, right: Spacing.double)
        for button in [translateButton, stagesButton] { button.controlSize = .small }
        let barSurface = SurfaceView(.bar)
        barSurface.addSubview(bar)
        bar.pin(to: barSurface)
        notes.setContentHuggingPriority(.required, for: .vertical)
        let notesBox = NSView()
        notesBox.addSubview(notes)
        notes.pin(to: notesBox, insets: NSEdgeInsets(top: 2, left: Spacing.double, bottom: 4, right: Spacing.double))

        let column = NSStackView(views: [scroll, barSurface, pipelineScroll, notesBox])
        column.orientation = .vertical
        column.spacing = 0
        for part in column.arrangedSubviews { part.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        pipelineScroll.heightAnchor.constraint(equalTo: column.heightAnchor, multiplier: 0.38).isActive = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        addSubview(column)
        column.pin(to: self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func translatePressed(_ sender: Any?) { translate(thenRun: false) }

    /// Open as Stages: the translation in the tab's text, then its cards.
    @objc func openAsStages(_ sender: Any?) {
        translate(thenRun: false) { [weak tab] in tab?.show(.stages) }
    }

    /// The SQL as the tab's pipeline (asking before it replaces a pipeline edited by hand), then `then`, or Run.
    func translate(thenRun run: Bool, then: (() -> Void)? = nil) {
        let open = tab.model.openMongo[tab.connectionID], database = tab.database
        let translation: MongoSQL.Translation
        do {
            translation = try MongoSQL.translate(editor.string) { open?.connection.samples.cached(database: database, collection: $0) }
        } catch let refusal as MongoSQL.Refusal {
            let length = (editor.string as NSString).length
            let start = min(refusal.range.lowerBound, max(0, length - 1))
            editor.runProblem = SQLProblem(range: start..<max(start + 1, min(refusal.range.upperBound, length)), message: refusal.message)
            editor.setSelectedRange(NSRange(location: start, length: 0))
            window?.makeFirstResponder(editor)
            return tab.showProblem(refusal.message)
        } catch {
            return tab.showProblem(error.localizedDescription)
        }
        guard translation.collection == tab.collection else {
            return tab.showProblem("This tab's pipeline runs on \(tab.collection): for FROM \(translation.collection), "
                                   + "open Query with SQL… on \(translation.collection)")
        }
        let text = MongoPipeline.text(translation.pipeline)
        // A stage a line, so the whole translation shows at a glance; the tab's text stays laid out as the editor's.
        pipeline.string = "[\n  " + translation.pipeline.map { $0.shellForm() }.joined(separator: ",\n  ") + "\n]"
        notes.stringValue = translation.notes.map { "• " + $0 }.joined(separator: "\n")
        notes.isHidden = translation.notes.isEmpty
        let apply = { [weak self] in
            guard let self else { return }
            if self.tab.editor.string != text { self.tab.replacePipeline(text) }
            self.tab.pipelineWritten = text
            if run { self.tab.run() }
            then?()
        }
        let current = tab.editor.string
        guard current != tab.pipelineWritten, current != text, let window else { return apply() }
        let alert = NSAlert()
        alert.messageText = "Replace the pipeline you edited?"
        alert.informativeText = "The SQL's translation takes the place of the pipeline's text in this tab. Undo (⌘Z) in Shell brings it back."
        alert.addButton(withTitle: "Replace").toolTip = "Put the SQL's pipeline in the tab in place of the edited one"
        alert.addButton(withTitle: "Cancel").toolTip = "Keep the edited pipeline"
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { apply() }
        }
    }
}

// MARK: Query with SQL… (lane P5-stages)

extension SidebarController {
    /// Query with SQL… on the tree's collection: an aggregation tab on its SQL page.
    @objc func queryWithSQL(_ sender: Any?) {
        guard let main, let open = mongoSelection?.open,
              let item = mongoSelection?.items.first(where: { $0.collection != nil && $0.index == nil }), let collection = item.collection
        else { return NSSound.beep() }
        main.openAggregation(collection, database: item.database, connection: open.saved.id, sql: MongoSQLPage.starter(collection))
    }
}

extension MongoCollectionController {
    @objc func queryWithSQL(_ sender: Any?) {
        (view.window?.windowController as? MainWindowController)?.openAggregation(name, database: database, connection: connectionID,
                                                                                   sql: MongoSQLPage.starter(name))
    }
}

extension MongoAggregationController {
    @objc func queryWithSQL(_ sender: Any?) { show(.sql) }
}

extension MongoSQLPage {
    /// The SELECT a new SQL page starts with.
    static func starter(_ collection: String) -> String {
        let name = collection.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } ? collection : "`\(collection.replacingOccurrences(of: "`", with: "``"))`"
        return "SELECT * FROM \(name) LIMIT 100"
    }
}
