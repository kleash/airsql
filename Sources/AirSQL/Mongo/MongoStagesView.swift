import AirSQLCore
import AppKit

/// The aggregation tab's Stages mode (mongo-plan, Phase 5 B): a card per stage of the pipeline's text, never folded, so
/// card n is stage n. A card's edit rewrites only its own stage in the tab's text (`MongoPipeline.replacingStage`), the
/// rest byte for byte; a stage no card shows exactly is a Shell card of its own text. The text stays the one truth: the
/// cards are rebuilt from it whenever it changed elsewhere.
@MainActor
final class MongoStagesView: NSView {
    /// The kinds a card can be, in the `+ Stage` menu's order (Join first: what SQL people miss most).
    enum Kind: Int, CaseIterable {
        case join, filter, group, sort, show, limit, unwind, shell

        var title: String {
            switch self {
            case .join: return "Join — JOIN"
            case .filter: return "Filter — WHERE"
            case .group: return "Group — GROUP BY"
            case .sort: return "Sort — ORDER BY"
            case .show: return "Show fields — SELECT"
            case .limit: return "Limit — LIMIT"
            case .unwind: return "Unwind"
            case .shell: return "Shell"
            }
        }

        var tip: String {
            switch self {
            case .join: return "Add each document's matching documents from another collection ($lookup)"
            case .filter: return "Keep only the documents that match conditions ($match)"
            case .group: return "Make one document per value of the chosen fields, with counts, sums and averages ($group)"
            case .sort: return "Put the documents in order by fields ($sort)"
            case .show: return "Keep only the ticked fields ($project)"
            case .limit: return "Keep only the first documents ($limit)"
            case .unwind: return "Make one document per item of an array field ($unwind)"
            case .shell: return "Type the stage in shell form, for any stage the cards don't cover"
            }
        }

        init(_ form: MongoStageForm) {
            switch form {
            case .join: self = .join
            case .filter: self = .filter
            case .group: self = .group
            case .sort: self = .sort
            case .show: self = .show
            case .limit: self = .limit
            case .unwind: self = .unwind
            case .shell: self = .shell
            }
        }
    }

    private unowned let tab: MongoAggregationController
    let scroll = NSScrollView()
    private let list = NSStackView()
    /// The text the cards were built from; another text means they are out of date.
    private(set) var builtFrom: String?
    private(set) var stages: [MongoPipeline.Stage] = []
    private(set) var forms: [MongoStageForm] = []
    private(set) var cards: [Card] = []
    /// Stages the person chose to see as Shell, until the cards are rebuilt.
    private var forcedShell: Set<Int> = []
    /// Collections whose sample is being read for the cards.
    private var asked: Set<String> = []
    /// Bumped by each rebuild: an action from an old card is dropped.
    private var generation = 0

    init(tab: MongoAggregationController) {
        self.tab = tab
        super.init(frame: .zero)
        setAccessibilityIdentifier("aggregate.stages")
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = Spacing.half
        list.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.double, bottom: Spacing.double, right: Spacing.double)
        document.addSubview(list)
        list.pin(to: document)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .ground
        addSubview(scroll)
        scroll.pin(to: self)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(connectionChanged(_:)), name: .openConnectionDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var open: OpenMongoConnection? { tab.model.openMongo[tab.connectionID] }

    // MARK: The text

    /// Builds the cards again when the text changed elsewhere; the text's error when it isn't a pipeline.
    @discardableResult
    func sync() -> String? {
        let text = tab.editor.string
        guard text != builtFrom else { return nil }
        do {
            stages = try MongoPipeline.stages(in: text)
        } catch let error as MongoPipeline.ParseError {
            return MongoAggregationController.problem(error, in: text).message
        } catch {
            return error.localizedDescription
        }
        if builtFrom != nil { forcedShell = [] }
        builtFrom = text
        rebuild()
        return nil
    }

    /// The first card that can't be written as it is filled in, as Run says it.
    var firstProblem: String? {
        cards.lazy.compactMap { card in card.problemText.map { "Stage \(card.index + 1): \($0)" } }.first
    }

    /// Puts `text` in the tab's editor (one undoable change) and keeps the cards on it without building them again.
    private func write(_ text: String) {
        builtFrom = text
        stages = (try? MongoPipeline.stages(in: text)) ?? []
        tab.replacePipeline(text)
    }

    /// The card's stage written into the text, or its problem shown on the card.
    private func commit(_ index: Int, _ form: MongoStageForm) {
        guard tab.editor.string == builtFrom, forms.indices.contains(index) else { return refreshFromText() }
        let card = cards[index]
        do {
            let stage = try form.stage()
            card.show(problem: nil)
            forms[index] = form
            if stage != stages[index].document {
                write(try MongoPipeline.replacingStage(index, with: stage, in: builtFrom ?? ""))
            }
            refreshFields()
            card.form = form
            showWarnings()
        } catch {
            forms[index] = form
            card.form = form
            card.show(problem: (error as? BSONError)?.message ?? error.localizedDescription)
        }
    }

    /// A Shell card's text, spliced into the pipeline as typed when it is one stage.
    private func commitText(_ index: Int, _ text: String) {
        guard tab.editor.string == builtFrom, stages.indices.contains(index), let whole = builtFrom else { return refreshFromText() }
        let card = cards[index]
        do {
            let found = try MongoPipeline.stages(in: text)
            guard found.count == 1 else {
                return card.show(problem: found.isEmpty ? "Type one stage, such as { $match: {} }" : "Type one stage here: + Stage adds another")
            }
            card.show(problem: nil)
            let range = NSRange(stages[index].range)
            forms[index] = .shell(found[0].document)
            write((whole as NSString).replacingCharacters(in: range, with: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            refreshFields()
        } catch let error as MongoPipeline.ParseError {
            card.show(problem: "Line \(error.line), column \(error.column): \(error.message)")
        } catch {
            card.show(problem: error.localizedDescription)
        }
    }

    /// The text changed under the cards (typed in Shell, a saved pipeline opened): build them from it.
    private func refreshFromText() {
        if let problem = sync() { tab.showShell(because: problem) }
    }

    /// A change of the pipeline's shape (a stage added, moved, removed, another kind): the text, then the cards again.
    private func reshape(_ text: String, shell: Set<Int> = []) {
        write(text)
        forcedShell = shell
        rebuild()
    }

    // MARK: Fields offered

    private func sample(_ collection: String) -> MongoSample? {
        guard let open else { return nil }
        if let found = open.connection.samples.cached(database: tab.database, collection: collection) { return found }
        if !asked.contains(collection) {
            asked.insert(collection)
            let (samples, database) = (open.connection.samples, tab.database)
            // Off the main thread, as autofill reads it; the cards' fields follow once it is in.
            Task.detached {
                _ = try? await samples.sample(database: database, collection: collection)
                await MainActor.run { [weak self] in
                    self?.refreshFields()
                    self?.showWarnings()
                }
            }
        }
        return nil
    }

    /// The collection's paths (`items.[].sku`): its sample's, else what the grid loaded.
    private var basePaths: [String] {
        sample(tab.collection)?.paths ?? tab.source.paths.map { $0.joined(separator: ".") }
    }

    /// The paths each stage sees: `fieldsBefore[n]` for card n.
    private var fieldsBefore: [[String]] {
        let base = basePaths
        let after = MongoStageForm.fields(after: forms, base: base) { [weak self] in self?.sample($0)?.paths ?? [] }
        return [base] + after
    }

    /// The names a field box offers: each path as a query names it, once.
    static func names(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.map(MongoBuilder.queryPath).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var collections: [String] {
        guard let open else { return [] }
        if open.collections[tab.database] == nil { open.loadDatabase(tab.database) }
        return (open.collections[tab.database] ?? []).map(\.name)
    }

    private func refreshFields() {
        let before = fieldsBefore
        for card in cards where before.indices.contains(card.index) {
            card.offer(Self.names(before[card.index]), foreign: { [weak self] in Self.names(self?.sample($0)?.paths ?? []) },
                       collections: collections)
        }
    }

    @objc private func connectionChanged(_ note: Notification) {
        guard (note.object as? OpenMongoConnection) === open, !cards.isEmpty else { return }
        refreshFields()
        showWarnings()
    }

    /// Each Join card's warnings, from the cached samples.
    private func showWarnings() {
        for card in cards {
            guard case .join(let join) = forms[card.index] else { continue }
            card.show(warnings: MongoJoinCheck.warnings(from: join.from, localField: join.localField, foreignField: join.foreignField,
                                                        as: join.as, here: sample(tab.collection), there: sample(join.from)))
        }
    }

    /// Count Each Stage's counts on the cards.
    func updateCounts() {
        for card in cards {
            card.count.stringValue = tab.count(ofStage: card.index + 1).map { "\($0.formatted()) document\($0 == 1 ? "" : "s")" } ?? ""
        }
    }

    // MARK: The cards

    private func rebuild() {
        generation += 1
        forms = stages.enumerated().map { index, stage in forcedShell.contains(index) ? .shell(stage.document) : MongoStageForm(stage: stage.document) }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards = []
        let before = fieldsBefore
        for index in forms.indices {
            list.addArrangedSubview(addButton(at: index, compact: true))
            let card = Card(index: index, form: forms[index], text: stageText(index), view: self)
            card.offer(Self.names(before[index]), foreign: { [weak self] in Self.names(self?.sample($0)?.paths ?? []) },
                       collections: collections)
            cards.append(card)
            list.addArrangedSubview(card.box)
            card.box.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -2 * Spacing.double).isActive = true
        }
        list.addArrangedSubview(addButton(at: forms.count, compact: false))
        if forms.isEmpty {
            list.addArrangedSubview(caption("No stages yet: + Stage adds one. Join brings in another collection's documents, "
                                            + "Group counts and sums them.", width: 420))
        }
        showWarnings()
        updateCounts()
    }

    private func stageText(_ index: Int) -> String {
        guard let text = builtFrom, stages.indices.contains(index) else { return "" }
        return (text as NSString).substring(with: NSRange(stages[index].range))
    }

    /// `+ Stage` (a pull-down of the kinds, Join first) to put a stage in at `index`.
    private func addButton(at index: Int, compact: Bool) -> NSView {
        let pull = NSPopUpButton(frame: .zero, pullsDown: true)
        pull.addItem(withTitle: compact ? "+" : "+ Stage")
        for kind in Kind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(addStage(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index * 100 + kind.rawValue
            item.toolTip = kind.tip
            pull.menu?.addItem(item)
        }
        pull.controlSize = compact ? .small : .regular
        pull.bezelStyle = compact ? .inline : .rounded
        pull.isBordered = !compact
        pull.toolTip = compact ? "Put a new stage before stage \(index + 1)" : "Add a stage at the end of the pipeline: Join, Filter, Group…"
        pull.setAccessibilityLabel(compact ? "Add a stage before stage \(index + 1)" : "Add a stage")
        pull.setAccessibilityIdentifier("stages.add.\(index)")
        pull.translatesAutoresizingMaskIntoConstraints = false
        return pull
    }

    @objc private func addStage(_ sender: NSMenuItem) {
        add(Kind(rawValue: sender.tag % 100) ?? .filter, at: sender.tag / 100)
    }

    /// Puts a new stage of `kind` in at `index`, filled with a first guess the card then edits.
    func add(_ kind: Kind, at index: Int) {
        guard tab.editor.string == builtFrom, let text = builtFrom else { return refreshFromText() }
        do {
            let made = try MongoPipeline.insertingStage(try first(kind, at: index), at: index, in: text)
            let shifted = Set(forcedShell.map { $0 >= index ? $0 + 1 : $0 })
            reshape(made, shell: kind == .shell ? shifted.union([index]) : shifted)
            cards.first { $0.index == index }?.focus()
        } catch {
            tab.showProblem((error as? BSONError)?.message ?? error.localizedDescription)
        }
    }

    /// Stage `index` as another kind: its first guess replaces it (Shell keeps it and shows its text).
    func change(_ index: Int, to kind: Kind) {
        guard tab.editor.string == builtFrom, let text = builtFrom, forms.indices.contains(index), kind != Kind(forms[index]) else { return }
        if kind == .shell { return reshape(text, shell: forcedShell.union([index])) }
        do {
            reshape(try MongoPipeline.replacingStage(index, with: try first(kind, at: index), in: text), shell: forcedShell.subtracting([index]))
        } catch {
            tab.showProblem((error as? BSONError)?.message ?? error.localizedDescription)
        }
    }

    func remove(_ index: Int) {
        guard tab.editor.string == builtFrom, let text = builtFrom, stages.indices.contains(index) else { return refreshFromText() }
        do {
            reshape(try MongoPipeline.removingStage(index, in: text),
                    shell: Set(forcedShell.compactMap { $0 == index ? nil : $0 > index ? $0 - 1 : $0 }))
        } catch {
            tab.showProblem((error as? BSONError)?.message ?? error.localizedDescription)
        }
    }

    /// Stage `index` one place up (`by` -1) or down (+1): its text moves as it is.
    func move(_ index: Int, by offset: Int) {
        let other = index + offset
        guard tab.editor.string == builtFrom, var text = builtFrom, stages.indices.contains(index), stages.indices.contains(other)
        else { return refreshFromText() }
        // The later one first, so the earlier range stays where it is.
        let (low, high) = (min(index, other), max(index, other))
        let ns = text as NSString
        let (lowText, highText) = (ns.substring(with: NSRange(stages[low].range)), ns.substring(with: NSRange(stages[high].range)))
        text = (text as NSString).replacingCharacters(in: NSRange(stages[high].range), with: lowText)
        text = (text as NSString).replacingCharacters(in: NSRange(stages[low].range), with: highText)
        let swapped = Set(forcedShell.map { $0 == index ? other : $0 == other ? index : $0 })
        reshape(text, shell: swapped)
        cards.first { $0.index == other }?.focus()
    }

    func runToHere(_ index: Int) { tab.run(through: index) }

    /// Join's "One document per match": an Unwind card of its `as` right after it, or that card gone.
    func setOnePerMatch(_ index: Int, _ on: Bool, preserve: Bool = false) {
        guard tab.editor.string == builtFrom, let text = builtFrom, case .join(let join) = forms[index] else { return refreshFromText() }
        do {
            if on, linkedUnwind(after: index) == nil {
                let unwind = try MongoStageForm.unwind(.init(path: join.as, preserve: preserve)).stage()
                reshape(try MongoPipeline.insertingStage(unwind, at: index + 1, in: text), shell: Set(forcedShell.map { $0 > index ? $0 + 1 : $0 }))
            } else if !on, linkedUnwind(after: index) != nil {
                remove(index + 1)
            }
        } catch {
            tab.showProblem((error as? BSONError)?.message ?? error.localizedDescription)
        }
    }

    /// The Unwind card after Join `index` that unwinds what it joined.
    func linkedUnwind(after index: Int) -> MongoStageForm.Unwind? {
        guard case .join(let join)? = forms[safe: index], case .unwind(let unwind)? = forms[safe: index + 1], unwind.path == join.as else { return nil }
        return unwind
    }

    /// Join's "Keep documents without a match": its Unwind card's preserve.
    func setKeepUnmatched(_ index: Int, _ on: Bool) {
        guard var unwind = linkedUnwind(after: index) else { return }
        unwind.preserve = on
        commit(index + 1, .unwind(unwind))
        cards[index + 1].form = .unwind(unwind)
        cards[index + 1].rebuildBody()
    }

    /// A Join card's edit: its stage, and the Unwind card after it follows a new `as`.
    fileprivate func edited(_ index: Int, _ form: MongoStageForm) {
        let linked = linkedUnwind(after: index)
        commit(index, form)
        if case .join(let join) = form, var unwind = linked, unwind.path != join.as, cards[index].problemText == nil {
            unwind.path = join.as
            commit(index + 1, .unwind(unwind))
            cards[index + 1].rebuildBody()
        }
        if case .join = form { cards[index].syncPerMatch() }
    }

    fileprivate var currentGeneration: Int { generation }

    /// A first guess for a new stage of `kind` at `index`, from the fields it sees.
    private func first(_ kind: Kind, at index: Int) throws -> BSONDocument {
        let fields = Self.names(fieldsBefore[safe: index] ?? basePaths).filter { $0 != "_id" }
        switch kind {
        case .join:
            let from = collections.first { $0 != tab.collection } ?? tab.collection
            // orders → customers: customerId, when there is one.
            let guess = String(from.hasSuffix("s") ? from.dropLast() : Substring(from)) + "Id"
            return try MongoStageForm.join(.init(from: from, localField: fields.contains(guess) ? guess : "_id", foreignField: "_id",
                                                 as: from)).stage()
        case .filter, .shell: return BSONDocument([("$match", .document(BSONDocument()))])
        case .group: return try MongoStageForm.group(.init(outputs: [.init(.count)])).stage()
        case .sort: return try MongoStageForm.sort([.init(fields.first ?? "_id")]).stage()
        case .show:
            if let path = fields.first { return try MongoStageForm.show(.init(paths: [path])).stage() }
            return BSONDocument([("$project", .document(BSONDocument([("_id", .int32(1))])))])
        case .limit: return try MongoStageForm.limit(10).stage()
        case .unwind:
            let arrays = (fieldsBefore[safe: index] ?? []).filter { $0.hasSuffix(".[]") }.map { MongoBuilder.queryPath($0) }
            return try MongoStageForm.unwind(.init(path: arrays.first ?? fields.first ?? "_id")).stage()
        }
    }

    // MARK: One card

    /// Card n: its kind, ↑ ↓, remove, Run to Here and its count over the form of its stage, then what's wrong with it.
    @MainActor
    final class Card {
        let index: Int
        var form: MongoStageForm
        let text: String
        unowned let view: MongoStagesView
        let box = SurfaceView(.content, radius: 8, border: .softSeparator)
        let kind: NSPopUpButton
        let count = label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        let body = NSStackView()
        let problem = label("", font: .systemFont(ofSize: 11), color: .systemRed, wraps: true)
        let warnings = label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: true)
        private(set) var problemText: String?
        private var actions: [Act] = []
        private var offers: [(NSComboBox, Bool)] = []
        private var fieldNames: [String] = []
        private var foreign: (String) -> [String] = { _ in [] }
        private var collections: [String] = []
        private var perMatch: NSButton?
        private var keepUnmatched: NSButton?
        private(set) var shellEditor: SQLEditorView?
        private let generation: Int

        init(index: Int, form: MongoStageForm, text: String, view: MongoStagesView) {
            self.index = index
            self.form = form
            self.text = text
            self.view = view
            generation = view.currentGeneration
            let number = "Stage \(index + 1)"
            kind = popup(Kind.allCases.map(\.title), selected: Kind(form).rawValue, id: "stage.\(index).kind",
                         tip: "Choose what stage \(index + 1) does; another kind starts it again", target: nil, action: nil)
            for (item, each) in zip(kind.itemArray, Kind.allCases) { item.toolTip = each.tip }
            kind.setAccessibilityLabel("\(number) kind")
            box.translatesAutoresizingMaskIntoConstraints = false
            box.setAccessibilityElement(true)
            box.setAccessibilityRole(.group)
            box.setAccessibilityLabel("\(number): \(Kind(form).title)")
            box.setAccessibilityIdentifier("stage.\(index)")

            let numberLabel = label("\(index + 1)", font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor)
            numberLabel.toolTip = "Stage \(index + 1): it gets the documents stage \(index) gives"
            let header = NSStackView(views: [numberLabel, kind, count, NSView(),
                                             symbol("forward.end", "Run to Here", id: "stage.\(index).run",
                                                    tip: "Run the stages up to this one and show the documents it gives") { [weak view] in view?.runToHere(index) },
                                             symbol("chevron.up", "Move Up", id: "stage.\(index).up",
                                                    tip: "Move this stage before the one above it") { [weak view] in view?.move(index, by: -1) },
                                             symbol("chevron.down", "Move Down", id: "stage.\(index).down",
                                                    tip: "Move this stage after the one below it") { [weak view] in view?.move(index, by: 1) },
                                             symbol("trash", "Remove Stage", id: "stage.\(index).remove",
                                                    tip: "Take this stage out of the pipeline") { [weak view] in view?.remove(index) }])
            header.spacing = Spacing.unit
            header.arrangedSubviews[3].setContentHuggingPriority(.init(1), for: .horizontal)
            let up = header.arrangedSubviews[5] as? NSButton, down = header.arrangedSubviews[6] as? NSButton
            up?.isEnabled = index > 0
            down?.isEnabled = index < view.stages.count - 1
            kind.target = act { [weak self] in
                guard let self, let chosen = Kind(rawValue: self.kind.indexOfSelectedItem) else { return }
                self.view.change(self.index, to: chosen)
            }
            kind.action = #selector(Act.fire(_:))

            body.orientation = .vertical
            body.alignment = .leading
            body.spacing = Spacing.half
            problem.isHidden = true
            warnings.isHidden = true
            problem.setAccessibilityIdentifier("stage.\(index).problem")
            warnings.setAccessibilityIdentifier("stage.\(index).warnings")
            let column = NSStackView(views: [header, body, problem, warnings])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = Spacing.unit
            column.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.unit + 4, bottom: Spacing.unit + 2, right: Spacing.unit + 4)
            box.addSubview(column)
            column.pin(to: box)
            for part in [header, body, problem, warnings] {
                part.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * (Spacing.unit + 4)).isActive = true
            }
            rebuildBody()
        }

        func show(problem text: String?) {
            problemText = text
            problem.stringValue = text ?? ""
            problem.isHidden = text == nil
        }

        func show(warnings list: [String]) {
            warnings.stringValue = list.map { "⚠︎ " + $0 }.joined(separator: "\n")
            warnings.isHidden = list.isEmpty
        }

        func focus() { box.window?.makeFirstResponder(kind) }

        /// The fields this stage sees, their collection's fields (`foreign`) and this database's collections, in its boxes.
        func offer(_ names: [String], foreign: @escaping (String) -> [String], collections: [String]) {
            fieldNames = names
            self.foreign = foreign
            self.collections = collections
            for (box, isForeign) in offers { fill(box, isForeign) }
        }

        private func fill(_ box: NSComboBox, _ isForeign: Bool) {
            let items: [String]
            if isForeign, case .join(let join) = form { items = foreign(join.from) } else { items = fieldNames }
            guard (box.objectValues as? [String]) != items else { return }
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }

        // MARK: Bodies

        func rebuildBody() {
            body.arrangedSubviews.forEach { $0.removeFromSuperview() }
            offers = []
            perMatch = nil
            keepUnmatched = nil
            shellEditor = nil
            let id = "stage.\(index)"
            switch form {
            case .filter:
                // shortcut: the Filter card is its $match as text until MongoConditionsView (lane P5-query) merges; then
                // this case becomes `MongoConditionsView(group:onChange:)` committing `.filter(group)`.
                shellBody()
            case .shell:
                shellBody()
            case .join(let join):
                var names = collections
                if !names.contains(join.from) { names.insert(join.from, at: 0) }
                let from = popup(names, selected: names.firstIndex(of: join.from) ?? 0, id: id + ".join.from",
                                 tip: "Choose the collection of this database whose documents join", target: nil, action: nil)
                from.setAccessibilityLabel("Join from collection")
                from.target = act { [weak self] in
                    guard let self, case .join(var j) = self.form, let title = from.titleOfSelectedItem, title != j.from else { return }
                    // A new collection: its name for the joined documents too, unless one was typed.
                    if j.as == j.from { j.as = title }
                    j.from = title
                    self.view.edited(self.index, .join(j))
                    self.rebuildBody()
                }
                from.action = #selector(Act.fire(_:))
                let local = combo(join.localField, id: id + ".join.local", label: "This collection's field",
                                  tip: "Choose the field here whose value must equal their field (ON this = theirs)") { [weak self] value in
                    self?.editJoin { $0.localField = value }
                }
                let theirs = combo(join.foreignField, foreign: true, id: id + ".join.foreign", label: "Their field",
                                   tip: "Choose the field of their documents that must equal this one") { [weak self] value in
                    self?.editJoin { $0.foreignField = value }
                }
                let name = field(join.as, id: id + ".join.as", label: "As",
                                 tip: "Name the field that gets the matching documents, as an array (the table's alias in SQL)") { [weak self] value in
                    self?.editJoin { $0.as = value }
                }
                body.addArrangedSubview(row([word("From"), from, word("where"), local, word("="), theirs]))
                body.addArrangedSubview(row([word("As"), name]))
                let one = checkbox("One document per match", id: id + ".join.perMatch",
                                   tip: "Make one document per matching document, as SQL's JOIN does, with an Unwind stage after this one",
                                   on: false, target: nil, action: nil)
                let keep = checkbox("Keep documents without a match", id: id + ".join.keep",
                                    tip: "Keep documents with no match too, as SQL's LEFT JOIN does (the Unwind keeps empty arrays)",
                                    on: false, target: nil, action: nil)
                one.target = act { [weak self] in
                    guard let self else { return }
                    self.view.setOnePerMatch(self.index, one.state == .on, preserve: keep.state == .on)
                }
                one.action = #selector(Act.fire(_:))
                keep.target = act { [weak self] in
                    guard let self else { return }
                    self.view.setKeepUnmatched(self.index, keep.state == .on)
                }
                keep.action = #selector(Act.fire(_:))
                (perMatch, keepUnmatched) = (one, keep)
                body.addArrangedSubview(row([one, keep]))
                syncPerMatch()
            case .group(let group):
                for (n, path) in group.by.enumerated() {
                    let by = combo(path, id: id + ".group.by.\(n)", label: "Group by field \(n + 1)",
                                   tip: "Choose a field: one result per value of it (GROUP BY)") { [weak self] value in
                        self?.editGroup { $0.by[n] = value }
                    }
                    body.addArrangedSubview(row([word(n == 0 ? "By" : "and"), by,
                                                 removeButton(id + ".group.by.\(n).remove", "Stop grouping by this field") { [weak self] in
                                                     self?.editGroup(again: true) { $0.by.remove(at: n) }
                                                 }]))
                }
                if group.by.isEmpty {
                    body.addArrangedSubview(caption("Every document in one group: add a field to group by.", width: 420))
                }
                for (n, output) in group.outputs.enumerated() {
                    let op = popup(MongoStageForm.Accumulator.allCases.map { $0.title + ($0.sqlHint.isEmpty ? "" : " — \($0.sqlHint)") },
                                   selected: MongoStageForm.Accumulator.allCases.firstIndex(of: output.op) ?? 0, id: id + ".group.op.\(n)",
                                   tip: "Choose what this result works out over each group's documents", target: nil, action: nil)
                    op.setAccessibilityLabel("Result \(n + 1) calculation")
                    op.target = act { [weak self] in
                        let chosen = MongoStageForm.Accumulator.allCases[op.indexOfSelectedItem]
                        self?.editGroup(again: true) { g in Self.rename(&g.outputs[n]) { $0.op = chosen } }
                    }
                    op.action = #selector(Act.fire(_:))
                    var parts: [NSView] = [op]
                    if output.op != .count {
                        parts.append(word("of"))
                        parts.append(combo(output.field, id: id + ".group.field.\(n)", label: "Result \(n + 1) field",
                                           tip: "Choose the field this result works over") { [weak self] value in
                            self?.editGroup(again: true) { g in Self.rename(&g.outputs[n]) { $0.field = value } }
                        })
                    }
                    parts += [word("as"), field(output.name, id: id + ".group.name.\(n)", label: "Result \(n + 1) name",
                                                 tip: "Name the field this result is written in (AS in SQL)", width: 140) { [weak self] value in
                                  self?.editGroup { $0.outputs[n].name = value }
                              },
                              removeButton(id + ".group.output.\(n).remove", "Take this result out") { [weak self] in
                                  self?.editGroup(again: true) { $0.outputs.remove(at: n) }
                              }]
                    body.addArrangedSubview(row(parts))
                }
                body.addArrangedSubview(row([
                    smallButton("+ Field", id: id + ".group.addBy", tip: "Group by one more field") { [weak self] in
                        guard let self else { return }
                        let next = self.fieldNames.first { f in f != "_id" && !group.by.contains(f) } ?? "_id"
                        self.editGroup(again: true) { $0.by.append(next) }
                    },
                    smallButton("+ Result", id: id + ".group.addOutput", tip: "Add a count, sum, average… of each group") { [weak self] in
                        self?.editGroup(again: true) { $0.outputs.append(.init(.count)) }
                    },
                ]))
            case .sort(let keys):
                for (n, key) in keys.enumerated() {
                    let path = combo(key.path, id: id + ".sort.field.\(n)", label: "Sort field \(n + 1)",
                                     tip: "Choose a field to put the documents in order by") { [weak self] value in
                        self?.editSort { $0[n].path = value }
                    }
                    let way = popup(["Ascending — ASC", "Descending — DESC"], selected: key.ascending ? 0 : 1, id: id + ".sort.way.\(n)",
                                    tip: "Choose smallest first (ascending) or largest first (descending)", target: nil, action: nil)
                    way.setAccessibilityLabel("Sort field \(n + 1) order")
                    way.target = act { [weak self] in self?.editSort { $0[n].ascending = way.indexOfSelectedItem == 0 } }
                    way.action = #selector(Act.fire(_:))
                    body.addArrangedSubview(row([word(n == 0 ? "By" : "then"), path, way,
                                                 removeButton(id + ".sort.\(n).remove", "Stop sorting by this field") { [weak self] in
                                                     self?.editSort(again: true) { $0.remove(at: n) }
                                                 }]))
                }
                body.addArrangedSubview(smallButton("+ Field", id: id + ".sort.add", tip: "Sort by one more field, for documents that tie") { [weak self] in
                    guard let self else { return }
                    let next = self.fieldNames.first { f in !keys.contains { $0.path == f } } ?? "_id"
                    self.editSort(again: true) { $0.append(.init(next)) }
                })
            case .show(let projection):
                let names = fieldNames.filter { $0 != "_id" }
                let all = names + projection.paths.filter { !names.contains($0) }
                let idBox = checkbox("_id", id: id + ".show._id", tip: "Show the documents' _id", on: projection.includeId, target: nil, action: nil)
                idBox.target = act { [weak self] in self?.editShow { $0.includeId = idBox.state == .on } }
                idBox.action = #selector(Act.fire(_:))
                var boxes: [NSView] = [idBox]
                for path in all {
                    let box = checkbox(path, id: id + ".show.\(path)", tip: "Show \(path)", on: projection.paths.contains(path), target: nil, action: nil)
                    box.target = act { [weak self] in
                        self?.editShow { p in
                            if box.state == .on { p.paths.append(path) } else { p.paths.removeAll { $0 == path } }
                        }
                    }
                    box.action = #selector(Act.fire(_:))
                    boxes.append(box)
                }
                let columns = 3
                let grid = NSGridView(views: stride(from: 0, to: boxes.count, by: columns).map { start in
                    let slice = Array(boxes[start..<min(start + columns, boxes.count)])
                    return slice + Array(repeating: NSGridCell.emptyContentView, count: columns - slice.count)
                })
                grid.columnSpacing = Spacing.double
                grid.rowSpacing = Spacing.half
                body.addArrangedSubview(grid)
            case .limit(let n):
                body.addArrangedSubview(row([word("First"), field(String(n), id: id + ".limit", label: "Limit",
                                                                    tip: "Type how many documents to keep (LIMIT)", width: 90) { [weak self] value in
                    guard let self else { return }
                    let number = Int64(value.trimmingCharacters(in: .whitespaces)) ?? 0
                    self.view.commit(self.index, .limit(number))
                }, word("documents")]))
            case .unwind(let unwind):
                let path = combo(unwind.path, id: id + ".unwind.path", label: "Array field",
                                 tip: "Choose the array field: one document per item of it") { [weak self] value in
                    guard let self, case .unwind(var u) = self.form else { return }
                    u.path = value
                    self.view.commit(self.index, .unwind(u))
                }
                let keep = checkbox("Keep documents without items", id: id + ".unwind.keep",
                                    tip: "Keep documents whose array is missing or empty (preserveNullAndEmptyArrays)",
                                    on: unwind.preserve, target: nil, action: nil)
                keep.target = act { [weak self] in
                    guard let self, case .unwind(var u) = self.form else { return }
                    u.preserve = keep.state == .on
                    self.view.commit(self.index, .unwind(u))
                }
                keep.action = #selector(Act.fire(_:))
                body.addArrangedSubview(row([word("One document per item of"), path, keep]))
            }
        }

        /// Join's ticks from the stage after it.
        func syncPerMatch() {
            let linked = view.linkedUnwind(after: index)
            perMatch?.state = linked == nil ? .off : .on
            keepUnmatched?.state = linked?.preserve == true ? .on : .off
            keepUnmatched?.isEnabled = linked != nil
            keepUnmatched?.toolTip = linked == nil ? "Tick One document per match first: then documents without one can be kept"
                : "Keep documents with no match too, as SQL's LEFT JOIN does (the Unwind keeps empty arrays)"
        }

        /// A Shell card: the stage's text in the console's editor, its error shown.
        private func shellBody() {
            let (scroll, editor) = SQLEditorView.make(fontSize: 12)
            scroll.rulersVisible = false
            editor.positionLabel.isHidden = true
            editor.otherLanguage = (problems: { text in
                do {
                    _ = try MongoPipeline.stages(in: text)
                    return []
                } catch let error as MongoPipeline.ParseError {
                    return [MongoAggregationController.problem(error, in: text)]
                } catch { return [] }
            }, folds: { _ in [] })
            editor.string = text
            editor.setAccessibilityIdentifier("stage.\(index).shell")
            editor.setAccessibilityLabel("Stage \(index + 1) in shell form")
            editor.toolTip = "Type the stage in shell form, such as { $facet: {…} }; it goes into the pipeline as typed"
            let currentIndex = index
            editor.onChange = { [weak self, weak editor] in
                guard let self, let editor, self.generation == self.view.currentGeneration else { return }
                self.view.commitText(currentIndex, editor.string)
            }
            shellEditor = editor
            scroll.borderType = .lineBorder
            let lines = CGFloat(min(12, max(1, text.components(separatedBy: "\n").count)))
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: lines * 16 + 10).isActive = true
            body.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        // MARK: Edits

        private func editJoin(_ change: (inout MongoStageForm.Join) -> Void) {
            guard case .join(var j) = form else { return }
            change(&j)
            view.edited(index, .join(j))
        }

        /// A group edit; `again`: rows came or went, so the body is laid out again.
        private func editGroup(again: Bool = false, _ change: (inout MongoStageForm.Grouping) -> Void) {
            guard case .group(var g) = form else { return }
            change(&g)
            view.commit(index, .group(g))
            if again { rebuildBody() }
        }

        /// A result's name follows its calculation and field while it is the name AirSQL gave it.
        static func rename(_ output: inout MongoStageForm.Output, _ change: (inout MongoStageForm.Output) -> Void) {
            let kept = output.name != MongoStageForm.Output.defaultName(output.op, output.field)
            change(&output)
            if !kept { output.name = MongoStageForm.Output.defaultName(output.op, output.field) }
        }

        private func editSort(again: Bool = false, _ change: (inout [MongoBuilder.SortKey]) -> Void) {
            guard case .sort(var keys) = form else { return }
            change(&keys)
            view.commit(index, .sort(keys))
            if again { rebuildBody() }
        }

        private func editShow(_ change: (inout MongoBuilder.Projection) -> Void) {
            guard case .show(var p) = form else { return }
            change(&p)
            view.commit(index, .show(p))
        }

        // MARK: Controls

        private func act(_ body: @escaping () -> Void) -> Act {
            let made = Act { [weak self] in
                guard let self, self.generation == self.view.currentGeneration else { return }
                body()
            }
            actions.append(made)
            return made
        }

        private func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views)
            row.spacing = Spacing.unit
            return row
        }

        private func word(_ text: String) -> NSTextField { label(text, font: .systemFont(ofSize: 12), color: .secondaryLabelColor) }

        /// A field box of the fields this stage sees (`foreign`: of the joined collection); any typed path works.
        private func combo(_ value: String, foreign isForeign: Bool = false, id: String, label: String, tip: String,
                           _ done: @escaping (String) -> Void) -> NSComboBox {
            let box = NSComboBox()
            box.stringValue = value
            box.completes = true
            box.numberOfVisibleItems = 14
            box.toolTip = tip
            box.setAccessibilityIdentifier(id)
            box.setAccessibilityLabel(label)
            box.placeholderString = "field"
            box.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            box.translatesAutoresizingMaskIntoConstraints = false
            box.widthAnchor.constraint(equalToConstant: 190).isActive = true
            box.cell?.sendsActionOnEndEditing = true
            box.target = act { [weak box] in
                guard let box else { return }
                done(box.stringValue.trimmingCharacters(in: .whitespaces))
            }
            box.action = #selector(Act.fire(_:))
            offers.append((box, isForeign))
            fill(box, isForeign)
            return box
        }

        private func field(_ value: String, id: String, label: String, tip: String, width: CGFloat = 190,
                           _ done: @escaping (String) -> Void) -> NSTextField {
            let field = textField(value, placeholder: "", id: id, tip: tip, width: width)
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.setAccessibilityLabel(label)
            field.cell?.sendsActionOnEndEditing = true
            field.target = act { [weak field] in
                guard let field else { return }
                done(field.stringValue.trimmingCharacters(in: .whitespaces))
            }
            field.action = #selector(Act.fire(_:))
            return field
        }

        private func symbol(_ name: String, _ title: String, id: String, tip: String, _ run: @escaping () -> Void) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: title) ?? NSImage(),
                                  target: act(run), action: #selector(Act.fire(_:)))
            button.bezelStyle = .inline
            button.isBordered = false
            button.toolTip = tip
            button.setAccessibilityLabel("\(title), stage \(index + 1)")
            button.setAccessibilityIdentifier(id)
            return button
        }

        private func removeButton(_ id: String, _ tip: String, _ run: @escaping () -> Void) -> NSButton {
            let button = symbol("minus.circle", "Remove", id: id, tip: tip, run)
            button.setAccessibilityLabel(tip)
            return button
        }

        private func smallButton(_ title: String, id: String, tip: String, _ run: @escaping () -> Void) -> NSButton {
            let made = button(title, id: id, tip: tip, target: act(run), action: #selector(Act.fire(_:)))
            made.controlSize = .small
            made.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            return made
        }
    }
}

/// A control's target that runs a closure (the cards' controls; the card keeps them).
final class Act: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}
