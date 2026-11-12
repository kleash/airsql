import Foundation

/// The `explain` command's answer with executionStats, for a find or an aggregate, as the steps `PlanView` draws
/// (mongo-plan, Explain): the classic engine's stages with their inputs, 7.0's slot-based `queryPlan` with each step's
/// figures found by its planNodeId, an aggregate's `stages` (its `$cursor` holding the query's plan) and a sharded
/// answer's shards. A step's Actual Rows is its nReturned and its Time executionTimeMillisEstimate; the documents and
/// keys it examined end its name, and everything else the server said is in its details. Warnings say what makes the
/// query slow, each also on its step.
public struct MongoExplain: Sendable {
    public var nodes: [PlanNode]
    public var warnings: [String] = []
    /// The steps as indented lines, for the plan's Tree page.
    public var tree: String

    /// A COLLSCAN that read this many documents is worth an index.
    static let largeScan = 1000

    public init(_ explain: BSONDocument) {
        nodes = []
        tree = ""
        nodes = plan(explain)
        tree = Self.lines(nodes, depth: 0).joined(separator: "\n")
    }

    /// One answer: a whole explain, a `$cursor`'s or a shard's.
    private mutating func plan(_ explain: BSONDocument) -> [PlanNode] {
        if case .array(let stages)? = explain["stages"] {
            return stages.compactMap { if case .document(let stage) = $0 { return self.stage(stage) } else { return nil } }
        }
        if case .document(let shards)? = explain["shards"] {
            return shards.fields.map { shard in
                var node = PlanNode(operation: "Shard " + shard.key)
                if case .document(let answer) = shard.value { node.children = plan(answer) }
                return node
            }
        }
        guard case .document(let planner)? = explain["queryPlanner"], case .document(let winning)? = planner["winningPlan"] else { return [] }
        let stats = explain["executionStats"]?.document
        var root = step(stats?["executionStages"]?.document, winning: winning)
        if let docs = Self.number(stats?["totalDocsExamined"]), let returned = Self.number(stats?["nReturned"]),
           docs >= 100, docs >= 10 * max(returned, 1) {
            warn("Examined \(Self.count(docs)) documents to return \(Self.count(returned)): an index on the filter’s fields would read fewer",
                 on: &root)
        }
        if case .array(let rejected)? = planner["rejectedPlans"], !rejected.isEmpty {
            warn("The planner tried \(rejected.count) other plan\(rejected.count == 1 ? "" : "s") and rejected "
                 + (rejected.count == 1 ? "it" : "them"), on: &root)
        }
        return [root]
    }

    /// The plan's root: the classic engine's executionStages (the winning plan with figures), else the slot-based
    /// engine's queryPlan with the figures of its executionStages, else the winning plan alone.
    private mutating func step(_ executed: BSONDocument?, winning: BSONDocument) -> PlanNode {
        if case .document(let queryPlan)? = winning["queryPlan"] {
            var figures: [String: BSONDocument] = [:]
            if let executed { Self.collect(executed, into: &figures) }
            return step(queryPlan, figures: figures)
        }
        return step(executed ?? winning, figures: [:])
    }

    /// One stage of a plan and its inputs.
    private mutating func step(_ stage: BSONDocument, figures: [String: BSONDocument]) -> PlanNode {
        let name = stage["stage"]?.string ?? "?"
        let measured = stage["planNodeId"].flatMap { figures[$0.shellForm()] } ?? stage
        var label = [Self.label(name, stage)]
        if let keys = Self.number(measured["keysExamined"]) { label.append("\(Self.count(keys)) keys examined") }
        if let docs = Self.number(measured["docsExamined"]) { label.append("\(Self.count(docs)) documents examined") }
        var node = PlanNode(operation: label.joined(separator: ", "), actualRows: Self.number(measured["nReturned"]),
                            time: Self.number(measured["executionTimeMillisEstimate"]))
        node.details = Self.details(stage, skipping: ["inputStage", "inputStages", "shards"])
        for key in ["inputStage", "inputStages", "shards"] {
            switch stage[key] {
            case .document(let input)?: node.children.append(step(input, figures: figures))
            case .array(let inputs)?:
                for case .document(let input) in inputs {
                    node.children.append(key == "shards" ? shard(input) : step(input, figures: figures))
                }
            default: break
            }
        }
        let read = Self.number(measured["docsExamined"]) ?? Self.number(measured["numReads"])
        if name == "COLLSCAN", read.map({ $0 >= Double(Self.largeScan) }) ?? true {
            warn("Reads the whole collection\(read.map { " (\(Self.count($0)) documents)" } ?? ""): "
                 + "an index on the filter’s fields would read fewer", on: &node)
        }
        if name == "SORT" {
            warn(Self.spilled(measured) ? "Sorts on disk, as the sort outgrew its memory: an index in the sort’s order would return the documents sorted"
                                        : "Sorts in memory: an index in the sort’s order would return the documents sorted", on: &node)
        }
        return node
    }

    /// One shard of a sharded find: its own plan under its name.
    private mutating func shard(_ shard: BSONDocument) -> PlanNode {
        var node = PlanNode(operation: "Shard " + (shard["shardName"]?.string ?? "?"))
        if case .document(let winning) = shard["winningPlan"] ?? .document(shard) {
            node.children = [step(shard["executionStages"]?.document, winning: winning)]
        }
        return node
    }

    /// One stage of an aggregate the query layer didn't run: `$cursor` holds the query's own plan.
    private mutating func stage(_ stage: BSONDocument) -> PlanNode? {
        guard let (name, value) = stage.fields.first else { return nil }
        var node = PlanNode(operation: name == "$cursor" ? name : name + " " + value.shellForm(maxLength: 80),
                            actualRows: Self.number(stage["nReturned"]), time: Self.number(stage["executionTimeMillisEstimate"]))
        if name == "$cursor", case .document(let answer) = value {
            node.children = plan(answer)
        } else {
            node.details = Self.details(stage, skipping: [])
        }
        if name == "$sort" {
            warn(Self.spilled(stage) ? "$sort sorted on disk, as the sort outgrew its memory" : "$sort sorts in memory", on: &node)
        }
        return node
    }

    private mutating func warn(_ warning: String, on node: inout PlanNode) {
        warnings.append(warning)
        node.details.insert("Warning: " + warning, at: 0)
    }

    // MARK: Words and figures

    private static func label(_ name: String, _ stage: BSONDocument) -> String {
        switch name {
        case "IXSCAN", "COUNT_SCAN", "DISTINCT_SCAN", "IDHACK":
            var label = name + (stage["indexName"]?.string.map { " " + $0 } ?? "")
            if case .document(let bounds)? = stage["indexBounds"] {
                let ranges = bounds.fields.map { field -> String in
                    guard case .array(let list) = field.value else { return field.key }
                    return field.key + ": " + list.map { $0.string ?? $0.shellForm() }.joined(separator: ", ")
                }.joined(separator: "; ")
                label += " (" + (ranges.count > 80 ? ranges.prefix(80) + "…" : ranges) + ")"
            }
            return label
        case "SORT":
            return name + (stage["sortPattern"].map { " " + $0.shellForm(maxLength: 80) } ?? "")
                + (spilled(stage) ? ", spilled to disk" : ", in memory")
        case "LIMIT": return name + (stage["limitAmount"].map { " " + $0.shellForm() } ?? "")
        case "SKIP": return name + (stage["skipAmount"].map { " " + $0.shellForm() } ?? "")
        case "EQ_LOOKUP":
            return name + (stage["foreignCollection"]?.string.map { " " + $0 } ?? "") + (stage["strategy"]?.string.map { " (\($0))" } ?? "")
        default: return name
        }
    }

    private static func spilled(_ stage: BSONDocument) -> Bool {
        stage["usedDisk"] == .bool(true) || (number(stage["spills"]) ?? 0) > 0
    }

    /// The stage's other fields, a "name: value" each.
    private static func details(_ stage: BSONDocument, skipping: Set<String>) -> [String] {
        stage.fields.filter { !skipping.contains($0.key) }.map { $0.key + ": " + ($0.value.string ?? $0.value.shellForm(maxLength: 300)) }
    }

    /// The slot-based engine's stages by planNodeId, the first (outermost) of each: its figures are the step's.
    private static func collect(_ stage: BSONDocument, into figures: inout [String: BSONDocument]) {
        if let id = stage["planNodeId"], figures[id.shellForm()] == nil { figures[id.shellForm()] = stage }
        for field in stage.fields {
            switch field.value {
            case .document(let inner): collect(inner, into: &figures)
            case .array(let list): for case .document(let inner) in list { collect(inner, into: &figures) }
            default: break
            }
        }
    }

    static func number(_ value: BSONValue?) -> Double? {
        switch value {
        case .int32(let n)?: return Double(n)
        case .int64(let n)?: return Double(n)
        case .double(let n)?: return n
        default: return nil
        }
    }

    private static func count(_ n: Double) -> String { String(Int64(n)) }

    private static func lines(_ nodes: [PlanNode], depth: Int) -> [String] {
        nodes.flatMap { node -> [String] in
            let figures = [node.actualRows.map { "returned \(count($0))" }, node.time.map { "\(count($0)) ms" }].compactMap { $0 }
            let line = String(repeating: "    ", count: depth) + node.operation + (figures.isEmpty ? "" : " (" + figures.joined(separator: ", ") + ")")
            return [line] + lines(node.children, depth: depth + 1)
        }
    }
}

extension BSONValue {
    var string: String? { if case .string(let text) = self { return text } else { return nil } }
    var document: BSONDocument? { if case .document(let document) = self { return document } else { return nil } }
}
