import Foundation

/// A step of a plan as the Operations view lists it: the server's estimates and, once analyzed, what really happened.
public struct PlanNode: Equatable, Sendable {
    public var operation: String
    /// The rows the server expected, and its cost figure.
    public var rows: Double?
    public var cost: Double?
    /// The rows it really read, its time in milliseconds over all its loops, and those loops.
    public var actualRows: Double?
    public var time: Double?
    public var loops: Double?
    public var children: [PlanNode] = []
    /// It took a large share of the plan's time (or, not analyzed, its cost) by itself.
    public var hot = false

    public init(operation: String, rows: Double? = nil, cost: Double? = nil, actualRows: Double? = nil, time: Double? = nil,
                loops: Double? = nil, children: [PlanNode] = []) {
        self.operation = operation
        self.rows = rows
        self.cost = cost
        self.actualRows = actualRows
        self.time = time
        self.loops = loops
        self.children = children
    }
}

extension ExplainPlan {
    /// The statement that runs `sql` and reports what happened, whether its answer is JSON; nil: the server can't.
    /// It runs the statement: read-only connections refuse both forms (`ReadOnlyClassifier`).
    public static func analyzeSQL(_ sql: String, server: ServerInfo?) -> (sql: String, json: Bool)? {
        guard let server, server.flavor == .mysql else { return ("ANALYZE FORMAT=JSON " + sql, true) }
        return server.atLeast(8, 0, 18) ? ("EXPLAIN ANALYZE " + sql, false) : nil
    }

    /// The steps of the server's plan: `json` is its JSON, else MySQL's tree.
    public static func nodes(from plan: String, json: Bool) -> [PlanNode] {
        marked(json ? nodes(fromJSON: plan) : nodes(fromTree: plan))
    }

    // MARK: JSON (MariaDB, MySQL before 8.0.16)

    static func nodes(fromJSON json: String) -> [PlanNode] {
        guard let data = numberingRepeats(json).data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        return collect(root)
    }

    private static func collect(_ node: Any) -> [PlanNode] {
        if let list = node as? [Any] { return list.flatMap(collect) }
        guard let object = node as? [String: Any] else { return [] }
        var nodes: [PlanNode] = []
        for key in object.keys.sorted(by: { order($0) < order($1) }) {
            let value = object[key]!
            switch plain(key) {
            case "query_block":
                let block = value as? [String: Any] ?? [:]
                var step = figures(of: block, operation: "Query block" + (block["select_id"].map { " #\($0)" } ?? ""))
                step.children = collect(value)
                nodes.append(step)
            case "table":
                guard let table = value as? [String: Any] else { continue }
                var words = ["Table " + (table["table_name"].map { "\($0)" } ?? "?")]
                if let access = table["access_type"] { words.append("\(access)") }
                if let key = table["key"] { words.append("key \(key)") }
                if let condition = table["attached_condition"] { words.append("where \(condition)") }
                var step = figures(of: table, operation: words.joined(separator: " · "))
                for (inner, child) in table where child is [String: Any] || child is [Any] {
                    if !["possible_keys", "used_key_parts", "cost_info", "used_columns", "r_engine_stats"].contains(inner) {
                        step.children += collect([inner: child])
                    }
                }
                nodes.append(step)
            case let name where containers.contains(name):
                var step = figures(of: value as? [String: Any] ?? [:],
                                   operation: name.replacingOccurrences(of: "_", with: " ").capitalized)
                step.children = collect(value)
                nodes.append(step)
            default:
                if value is [String: Any] || value is [Any] { nodes += collect(value) }
            }
        }
        return nodes
    }

    /// A JSON step's figures: MariaDB's `rows`, `cost` and `r_…`, MySQL's `rows_examined_per_scan` and `cost_info`.
    private static func figures(of object: [String: Any], operation: String) -> PlanNode {
        let cost = object["cost_info"] as? [String: Any]
        let tableTime = number(object["r_table_time_ms"]), otherTime = number(object["r_other_time_ms"])
        return PlanNode(operation: operation, rows: number(object["rows"] ?? object["rows_examined_per_scan"]),
                        cost: number(object["cost"] ?? cost?["query_cost"] ?? cost?["prefix_cost"]),
                        actualRows: number(object["r_rows"]),
                        time: number(object["r_total_time_ms"]) ?? tableTime.map { $0 + (otherTime ?? 0) },
                        loops: number(object["r_loops"]))
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        return (value as? String).flatMap(Double.init)
    }

    // MARK: MySQL's tree

    /// `-> Filter: (a > 1)  (cost=0.35 rows=1) (actual time=0.05..0.06 rows=1 loops=2)`, four spaces deeper for each level.
    static func nodes(fromTree tree: String) -> [PlanNode] {
        var lines: [(depth: Int, node: PlanNode)] = []
        for line in tree.split(whereSeparator: \.isNewline) {
            let text = line.drop { $0 == " " }
            guard text.hasPrefix("->") else {
                if !lines.isEmpty { lines[lines.count - 1].node.operation += " " + text }
                continue
            }
            lines.append(((line.count - text.count) / 4, step(String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces))))
        }
        var index = 0
        func level(_ depth: Int) -> [PlanNode] {
            var nodes: [PlanNode] = []
            while index < lines.count, lines[index].depth >= depth {
                var node = lines[index].node
                let own = lines[index].depth
                index += 1
                node.children = level(own + 1)
                nodes.append(node)
            }
            return nodes
        }
        return level(0)
    }

    private static let estimate = try! NSRegularExpression(pattern: #"\s*\(cost=(?:[0-9.e+]+\.\.)?([0-9.e+]+) rows=([0-9.e+]+)\)"#)
    private static let actual = try! NSRegularExpression(pattern: #"\s*\(actual time=[0-9.e+]+\.\.([0-9.e+]+) rows=([0-9.e+]+) loops=([0-9]+)\)"#)

    private static func step(_ line: String) -> PlanNode {
        var text = line
        func take(_ pattern: NSRegularExpression) -> [Double?]? {
            let whole = NSRange(text.startIndex..., in: text)
            guard let match = pattern.firstMatch(in: text, range: whole), let range = Range(match.range, in: text) else { return nil }
            let found = (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).flatMap { Double(text[$0]) } }
            text.removeSubrange(range)
            return found
        }
        var node = PlanNode(operation: "")
        if let found = take(estimate) { (node.cost, node.rows) = (found[0], found[1]) }
        if let found = take(actual) {
            (node.actualRows, node.loops) = (found[1], found[2])
            node.time = found[0].map { $0 * (found[2] ?? 1) }
        }
        node.operation = text
        return node
    }

    // MARK: Hot spots

    /// Marks the steps whose own share (their figure less their children's) is at least a third of the plan's.
    private static func marked(_ nodes: [PlanNode]) -> [PlanNode] {
        let analyzed = contains(nodes) { $0.time != nil }
        let figure: (PlanNode) -> Double = { (analyzed ? $0.time : $0.cost) ?? 0 }
        let total = nodes.map(figure).reduce(0, +)
        guard total > 0 else { return nodes }
        func mark(_ node: PlanNode) -> PlanNode {
            var node = node
            node.hot = figure(node) - node.children.map(figure).reduce(0, +) >= total / 3
            node.children = node.children.map(mark)
            return node
        }
        return nodes.map(mark)
    }

    private static func contains(_ nodes: [PlanNode], where test: (PlanNode) -> Bool) -> Bool {
        nodes.contains { test($0) || contains($0.children, where: test) }
    }
}
