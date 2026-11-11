import AirSQLCore
import AppKit

/// Agents and MongoDB tabs (mongo-plan, Agents): mongo_open puts a find or a pipeline in a new tab marked as proposed,
/// never run, as open_in_console does with SQL; context and read_console report the collection and pipeline tabs.

/// A collection or pipeline tab as agents see it. Both MongoDB tab controllers conform.
@MainActor
protocol AgentMongoTab: NSViewController {
    var agentKind: String { get }
    var database: String { get }
    var agentCollection: String { get }
    /// The fields as typed: the query bar's, or the pipeline with its options.
    var agentFields: [(String, String)] { get }
    var source: MongoDocumentSource { get }
    var viewer: GridViewer { get }
    var loading: Task<Void, Never>? { get }
    var problem: String? { get }
    /// Reads started: 0 while nothing has run (a proposed tab before Run).
    var reads: Int { get }
}

extension MongoCollectionController: AgentMongoTab {
    var agentKind: String { "collection" }
    var agentCollection: String { name }
    var agentFields: [(String, String)] {
        let query = bar.query
        return [("filter", query.filter), ("projection", query.projection), ("sort", query.sort), ("skip", query.skip),
                ("limit", query.limit), ("collation", query.collation), ("hint", query.hint), ("maxTimeMS", query.maxTimeMS)]
    }
}

extension MongoAggregationController: AgentMongoTab {
    var agentKind: String { "aggregation" }
    var agentCollection: String { collection }
    var agentFields: [(String, String)] {
        [("pipeline", editor.string), ("collation", collation.stringValue), ("maxTimeMS", maxTime.stringValue)]
    }
}

/// The band on a tab an agent proposed: who proposed it, and that nothing ran; Dismiss hides it.
@MainActor
final class AgentProposalBar: NSView {
    init(agent: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let text = "Proposed by \(agent): review, then Run. Nothing has run yet."
        let image = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = .accent
        image.setContentHuggingPriority(.required, for: .horizontal)
        let words = label(text, font: .systemFont(ofSize: 12), wraps: true)
        words.setAccessibilityIdentifier("mongo.proposalText")
        let dismiss = button("Dismiss", id: "mongo.proposalDismiss", tip: "Hide this notice; the query stays as it is",
                             target: self, action: #selector(dismissed(_:)))
        dismiss.controlSize = .small
        let row = NSStackView(views: [image, words])
        row.addView(dismiss, in: .trailing)
        row.spacing = Spacing.unit
        let ground = SurfaceView(NSColor.accent.withAlphaComponent(0.12))
        ground.setAccessibilityIdentifier("mongo.proposal")
        addSubview(ground)
        ground.pin(to: self)
        addSubview(row)
        row.pin(to: self, insets: NSEdgeInsets(top: 5, left: Spacing.double, bottom: 5, right: Spacing.unit))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func dismissed(_ sender: Any?) { removeFromSuperview() }
}

extension MainWindowController {
    /// mongo_open's tab: always a new one, holding the find or the pipeline, which waits for the person's Run.
    func open(_ proposal: MongoProposal, title: String, agent: String, connection: UUID) -> Tab {
        if let pipeline = proposal.pipeline {
            let content = MongoAggregationController(model: model, connection: connection, database: proposal.database,
                                                     collection: proposal.collection)
            content.proposedBy = agent
            let tab = open(content, title: title, connection: connection)
            _ = content.view  // its own first pipeline goes in as it loads; the proposal replaces it
            content.editor.string = pipeline
            content.collation.stringValue = proposal.query.collation
            return tab
        }
        let info = model.openMongo[connection]?.collections[proposal.database]?.first { $0.name == proposal.collection }
            ?? MongoCollectionInfo(name: proposal.collection, kind: .collection)
        let content = MongoCollectionController(model: model, connection: connection, database: proposal.database, collection: info)
        content.proposedBy = agent
        content.bar.query = proposal.query
        return open(content, title: title, connection: connection)
    }
}

extension AgentService {
    func mongoOpen(_ arguments: [String: Any], client: String) throws -> [String: Any] {
        let target = try self.target(arguments)
        let proposal = try target.mongoProposal(arguments)
        guard let main else { throw AirSQLError(.other, "AirSQL has no main window open to put the tab in.") }
        let name = (arguments["title"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String($0.prefix(60))
        } ?? proposal.collection
        let tab = main.open(proposal, title: name + " · proposed by " + client, agent: client, connection: target.saved.id)
        return ["tab": tab.id.uuidString, "title": tab.title, "connection": target.saved.displayName,
                "kind": proposal.pipeline == nil ? "collection" : "aggregation"]
    }

    /// The MongoDB tabs agents may see, in every window: those of connections open to agents.
    func mongoTabs() -> [(Tab, AgentMongoTab, SavedConnection?)] {
        model.allTabs.compactMap { tab in
            guard let content = tab.shown as? AgentMongoTab, let saved = model.connection(tab.connectionID),
                  saved.agentAccess != .off else { return nil }
            return (tab, content, saved)
        }
    }

    /// A MongoDB tab for context's list.
    static func entry(_ tab: Tab, _ content: AgentMongoTab, _ saved: SavedConnection?) -> [String: Any] {
        ["tab": tab.id.uuidString, "title": tab.title, "connection": saved?.displayName ?? NSNull(), "kind": content.agentKind,
         "database": content.database, "collection": content.agentCollection]
    }

    /// read_console of a MongoDB tab: its place and fields (redacted as the command log is), how the last run went, and
    /// with Schema + read the selected documents' _ids and the first documents loaded.
    func readMongo(_ tab: Tab, _ content: AgentMongoTab, _ saved: SavedConnection?) -> [String: Any] {
        var reply = Self.entry(tab, content, saved)
        let fields = content.agentFields.map { ($0.0, AgentTarget.mongoRedacted($0.1)) }
        reply["text"] = fields[0].1  // the filter, or the pipeline
        // The same fields as relaxed Extended JSON, as mongo_find and mongo_aggregate take them; a field that doesn't
        // parse yet (half typed) is left out.
        func json(_ text: String) -> String? {
            text.isEmpty ? nil : (try? BSONDocument(shellForm: text))?.extendedJSON(.relaxed)
        }
        if content.agentKind == "collection" {
            reply["query"] = Dictionary(fields) { $1 }
            reply["queryJSON"] = Dictionary(fields.filter { ["filter", "projection", "sort", "collation"].contains($0.0) }
                .compactMap { name, text in json(text).map { (name, $0) } }) { $1 }
        } else {
            reply["pipeline"] = fields[0].1
            reply["options"] = Dictionary(fields.dropFirst().map { $0 }) { $1 }
            if let stages = try? MongoPipeline.stages(in: fields[0].1) {
                reply["pipelineJSON"] = "[" + stages.map { $0.document.extendedJSON(.relaxed) }.joined(separator: ",") + "]"
            }
        }
        let source = content.source
        var run: [String: Any] = ["documentsLoaded": source.loadedCount]
        if content.loading != nil {
            run["state"] = "running"
        } else if content.reads == 0 {
            run["state"] = "not run"
        } else if let problem = content.problem {
            run["state"] = problem.hasPrefix("Cancelled") ? "cancelled" : "failed"
            run["error"] = AgentTarget.mongoRedacted(problem)
        } else {
            run["state"] = "done"
        }
        reply["run"] = run
        let rows = content.viewer.selectedRows().filter { $0 < source.loadedCount }
        // Documents and their _ids are data: only with read access to the tab's connection.
        if (saved?.agentAccess.rank ?? 0) >= AgentAccess.schemaRead.rank {
            reply["selectedIds"] = rows.compactMap { source.document($0)?["_id"].map(AgentTarget.mongoText) }
            let documents = AgentTarget.mongoTexts((0..<min(source.loadedCount, 50)).compactMap(source.document))
            reply["documents"] = documents.texts
            reply["capped"] = documents.capped || source.loadedCount > documents.texts.count
        } else {
            reply["selectedCount"] = rows.count
            if source.loadedCount > 0 { reply["note"] = "Documents hidden: this connection allows agents Schema access only." }
        }
        return reply
    }
}
