import AirSQLCore
import AppKit

/// The collection tab's side of the query builder (mongo-plan, Phase 5 A): the sample it offers, the grid's Quick
/// Filter and header sort, Builder | Shell, and Aggregate….
extension MongoCollectionController {
    /// The collection's sample for the builder's fields, types and values, read off the main thread.
    func loadBuilderSample() {
        guard let samples = connection?.samples else { return }
        let (database, name) = (database, name)
        Task { [weak self] in
            let sample = try? await samples.sample(database: database, collection: name)
            guard let self, let sample else { return }
            bar.use(sample.schema, paths: knownPaths)
        }
    }

    // MARK: Quick Filter

    /// The clauses a cell's value offers, each with its words: is, is not, greater, less (not for null, documents or
    /// arrays), contains (text); from the cell's BSON value as stored, never its text.
    static func quickFilters(path: String, value: BSONValue) -> [(title: String, clause: BSONDocument)] {
        func op(_ name: String) -> BSONDocument { BSONDocument([(path, .document(BSONDocument([(name, value)])))]) }
        // A regular expression as the value would match as a pattern: `$eq` compares it as a value.
        let equal = { if case .regex = value { return op("$eq") } else { return BSONDocument([(path, value)]) } }()
        var found: [(String, BSONDocument)] = [("is", equal), ("is not", op("$ne"))]
        switch value {
        case .null, .undefined, .document, .array, .minKey, .maxKey, .regex: break
        default: found += [("greater than", op("$gt")), ("less than", op("$lt"))]
        }
        if case .string(let text) = value, !text.isEmpty,
           let contains = try? MongoBuilder.Rule(path, .contains, [text], type: .text).clause() {
            found.append(("contains", contains))
        }
        return found
    }

    /// Quick Filter ▸ for the focused cell: each clause replaces the filter; with ⌥ (Add to Filter) it is added to it.
    /// Not for agents: the value may be of rows they may not read (plan §2.8).
    func quickFilterItem() -> NSMenuItem? {
        guard AgentGate.agent == nil, let (row, column) = viewer.focusedCell, source.paths.indices.contains(column),
              row < source.rowCount else { return nil }
        let path = source.paths[column].joined(separator: ".")
        var items: [NSMenuItem] = []
        for (title, clause) in Self.quickFilters(path: path, value: source.bsonValue(row, column) ?? .null) {
            var shown = clause.shellForm()
            if shown.count > 70 { shown = String(shown.prefix(69)) + "…" }
            for adding in [false, true] {
                let item = NSMenuItem(title: (adding ? "Add to Filter: " : "") + "\(path) \(title)  \(shown)",
                                      action: #selector(quickFilter(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = clause
                item.tag = adding ? 1 : 0
                item.toolTip = (adding ? "Add this condition to the current filter: " : "Find only the documents where ") + shown
                if adding {
                    item.isAlternate = true
                    item.keyEquivalentModifierMask = .option
                }
                items.append(item)
            }
        }
        return MainMenu.submenu("Quick Filter", items)
    }

    /// A Quick Filter item: its clause in place of the filter, or (tag 1) added to it; then Run.
    @objc func quickFilter(_ sender: NSMenuItem) {
        guard let clause = sender.representedObject as? BSONDocument else { return }
        let text = bar.filter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if sender.tag == 1 {
            guard let old = try? BSONDocument(shellForm: text.isEmpty ? "{}" : text) else {
                return bar.show(field: "Filter", "Fix the filter's text before adding a condition to it")
            }
            bar.filter.stringValue = Self.adding(clause, to: old).shellForm()
        } else {
            bar.filter.stringValue = clause.shellForm()
        }
        show(.documents)
        run()
    }

    /// `old` and `clause` both: as the builder writes them when it can read both, else `$and` of the two.
    static func adding(_ clause: BSONDocument, to old: BSONDocument) -> BSONDocument {
        if old.fields.isEmpty { return clause }
        if let group = MongoBuilder.Group(filter: old), let added = MongoBuilder.Group(filter: clause) {
            let both = group.any ? MongoBuilder.Group([.group(group)] + added.children) : MongoBuilder.Group(group.children + added.children)
            if let filter = try? both.filter(), MongoBuilder.Group(filter: filter) != nil { return filter }
        }
        return BSONDocument([("$and", .array([.document(old), .document(clause)]))])
    }

    // MARK: Header sort

    @objc func sortAscending(_ sender: Any?) { sortColumn(sender, ascending: true) }
    @objc func sortDescending(_ sender: Any?) { sortColumn(sender, ascending: false) }

    private func sortColumn(_ sender: Any?, ascending: Bool) {
        guard let column = ((sender as? NSMenuItem)?.representedObject as? Int) ?? viewer.focusedColumn,
              source.paths.indices.contains(column) else { return NSSound.beep() }
        let path = source.paths[column].joined(separator: ".")
        bar.sort.stringValue = BSONDocument([(path, .int32(ascending ? 1 : -1))]).shellForm()
        run()
    }

    // MARK: Builder | Shell, Aggregate…

    @objc func toggleQueryBuilder(_ sender: Any?) { bar.setMode(bar.mode == .builder ? .shell : .builder) }

    /// Aggregate…: an aggregation tab whose pipeline starts with this query's filter, sort, projection, skip and limit.
    @objc func aggregateQuery(_ sender: Any?) {
        bar.readText()
        let find: MongoFind
        do { find = try bar.query.find() } catch {
            return bar.show(error as? MongoQueryText.Problem)
        }
        bar.show(nil)
        guard let main = view.window?.windowController as? MainWindowController else { return NSSound.beep() }
        main.openAggregation(name, database: database, connection: connectionID)
        guard let tab = main.selectedTab?.content as? MongoAggregationController else { return }
        _ = tab.view
        tab.editor.string = Self.pipelineText(find)
        tab.collation.stringValue = bar.collation.stringValue
        tab.maxTime.stringValue = bar.maxTime.stringValue
    }

    /// `[ { $match: … }, { $sort: … }, { $project: … }, { $skip: n }, { $limit: n } ]`, the parts set only.
    static func pipelineText(_ find: MongoFind) -> String {
        var stages: [BSONDocument] = []
        if !find.filter.fields.isEmpty { stages.append(BSONDocument([("$match", .document(find.filter))])) }
        if let sort = find.sort, !sort.fields.isEmpty { stages.append(BSONDocument([("$sort", .document(sort))])) }
        if let projection = find.projection, !projection.fields.isEmpty { stages.append(BSONDocument([("$project", .document(projection))])) }
        func number(_ n: Int64) -> BSONValue { Int32(exactly: n).map(BSONValue.int32) ?? .int64(n) }
        if let skip = find.skip, skip > 0 { stages.append(BSONDocument([("$skip", number(skip))])) }
        if let limit = find.limit, limit > 0 { stages.append(BSONDocument([("$limit", number(limit))])) }
        if stages.isEmpty { stages = [BSONDocument([("$match", .document(BSONDocument()))])] }
        return "[\n" + stages.map { "  " + $0.shellForm() }.joined(separator: ",\n") + "\n]\n"
    }
}
