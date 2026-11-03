import Foundation

/// EXPLAIN as a table and a tree (plan §2.6, R15: no graphical plan in 1.0). The table is the server's own EXPLAIN; the
/// tree is MySQL's EXPLAIN FORMAT=TREE (8.0.16 and later), else EXPLAIN FORMAT=JSON (MariaDB, MySQL 5.7) flattened
/// into indented lines.
public enum ExplainPlan {
    /// The statement that gives the plan as a table.
    public static func tableSQL(_ sql: String) -> String { "EXPLAIN " + sql }

    /// The statement that gives the plan as a tree or as JSON, and whether its answer is JSON to flatten.
    public static func treeSQL(_ sql: String, server: ServerInfo?) -> (sql: String, json: Bool) {
        if let server, server.flavor == .mysql, server.versionNumber >= 80016 { return ("EXPLAIN FORMAT=TREE " + sql, false) }
        return ("EXPLAIN FORMAT=JSON " + sql, true)
    }

    /// MariaDB's or MySQL's JSON plan as indented lines: each query block, table (its access, key, rows and
    /// condition), join, subquery, temporary table and sort, in the server's order.
    public static func tree(fromJSON json: String) -> String {
        guard let data = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return json }
        var lines: [String] = []
        walk(root, depth: 0, into: &lines)
        return lines.joined(separator: "\n")
    }

    private static let shown = ["access_type", "key", "used_key_parts", "ref", "rows", "rows_examined_per_scan",
                                "filtered", "attached_condition", "using_index", "using_filesort", "using_temporary_table"]

    private static func walk(_ node: Any, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "    ", count: depth)
        if let list = node as? [Any] {
            for item in list { walk(item, depth: depth, into: &lines) }
            return
        }
        guard let object = node as? [String: Any] else { return }
        for key in object.keys.sorted(by: { order($0) < order($1) }) {
            let value = object[key]!
            switch key {
            case "query_block":
                let id = ((value as? [String: Any])?["select_id"]).map { " #\($0)" } ?? ""
                lines.append(indent + "Query block" + id)
                walk(value, depth: depth + 1, into: &lines)
            case "table":
                guard let table = value as? [String: Any] else { continue }
                let name = table["table_name"].map { "\($0)" } ?? "table"
                let details = shown.compactMap { field in table[field].map { "\(field.replacingOccurrences(of: "_", with: " ")): \(text($0))" } }
                lines.append(indent + "Table " + name + (details.isEmpty ? "" : " (" + details.joined(separator: ", ") + ")"))
                for (inner, child) in table where child is [String: Any] || child is [Any] {
                    if inner == "possible_keys" || inner == "used_key_parts" { continue }
                    walk([inner: child], depth: depth + 1, into: &lines)
                }
            case "nested_loop", "subqueries", "union_result", "materialized_from_subquery", "query_specifications",
                 "duplicates_removal", "filesort", "temporary_table", "grouping_operation", "ordering_operation",
                 "read_sorted_file", "having_subqueries", "window_functions_computation", "block-nl-join", "expression_cache":
                lines.append(indent + key.replacingOccurrences(of: "_", with: " ").capitalized)
                walk(value, depth: depth + 1, into: &lines)
            default:
                if value is [String: Any] || value is [Any] { walk(value, depth: depth, into: &lines) }
            }
        }
    }

    /// Query blocks and tables first, then the rest in name order, so the plan reads top down.
    private static func order(_ key: String) -> String {
        (["query_block": "0", "table": "1", "nested_loop": "2"][key] ?? "3") + key
    }

    private static func text(_ value: Any) -> String {
        if let list = value as? [Any] { return list.map(text).joined(separator: ", ") }
        return "\(value)"
    }
}
