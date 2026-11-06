import Foundation

/// EXPLAIN as a table, a tree and steps with their figures (`PlanNode`; plan §2.6, R15: no graphical plan). The table is the server's own EXPLAIN; the
/// tree is MySQL's EXPLAIN FORMAT=TREE (8.0.16 and later), else EXPLAIN FORMAT=JSON (MariaDB, MySQL 5.7) flattened
/// into indented lines.
public enum ExplainPlan {
    /// The statement that gives the plan as a table. A bare EXPLAIN on MySQL answers in its explain_format, TREE from 9.7
    /// on; MariaDB has no FORMAT=TRADITIONAL.
    public static func tableSQL(_ sql: String, server: ServerInfo? = nil) -> String {
        (server?.flavor == .mysql ? "EXPLAIN FORMAT=TRADITIONAL " : "EXPLAIN ") + sql
    }

    /// The statement that gives the plan as a tree or as JSON, and whether its answer is JSON to flatten.
    public static func treeSQL(_ sql: String, server: ServerInfo?) -> (sql: String, json: Bool) {
        if let server, server.flavor == .mysql, server.atLeast(8, 0, 16) { return ("EXPLAIN FORMAT=TREE " + sql, false) }
        return ("EXPLAIN FORMAT=JSON " + sql, true)
    }

    /// MariaDB's or MySQL's JSON plan as indented lines: each query block, table (its access, key, rows and
    /// condition), join, subquery, temporary table and sort, in the server's order.
    public static func tree(fromJSON json: String) -> String {
        guard let data = numberingRepeats(json).data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data)
        else { return json }
        var lines: [String] = []
        walk(root, depth: 0, into: &lines)
        return lines.joined(separator: "\n")
    }

    /// MariaDB 10.5 and 10.6 repeat the "table" key of a join, and a JSON reader keeps only the last of them: each
    /// repeat becomes "table#002" and so on, in order, which `walk` and `order` read past.
    static func numberingRepeats(_ json: String) -> String {
        let bytes = Array(json.utf8)
        var out: [UInt8] = [], seen: [[ArraySlice<UInt8>: Int]] = [], index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "{") { seen.append([:]) }
            if byte == UInt8(ascii: "}") { _ = seen.popLast() }
            guard byte == UInt8(ascii: "\"") else {
                out.append(byte)
                index += 1
                continue
            }
            var end = index + 1
            while end < bytes.count, bytes[end] != UInt8(ascii: "\"") { end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1 }
            guard end < bytes.count else { return json }
            let text = bytes[(index + 1)..<end]
            var next = end + 1
            while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
            out += bytes[index..<end]
            if next < bytes.count, bytes[next] == UInt8(ascii: ":"), !seen.isEmpty {
                let count = seen[seen.count - 1][text, default: 0] + 1
                seen[seen.count - 1][text] = count
                if count > 1 { out += Array(String(format: "#%03d", count).utf8) }
            }
            out.append(UInt8(ascii: "\""))
            index = end + 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The steps that hold others.
    static let containers: Set<String> = ["nested_loop", "subqueries", "union_result", "materialized_from_subquery", "query_specifications",
                                          "duplicates_removal", "filesort", "temporary_table", "grouping_operation", "ordering_operation",
                                          "read_sorted_file", "having_subqueries", "window_functions_computation", "block-nl-join",
                                          "expression_cache"]

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
            let key = plain(key)
            switch key {
            case "query_block":
                let id = ((value as? [String: Any])?["select_id"]).map { " #\($0)" } ?? ""
                lines.append(indent + "Query block" + id)
                walk(value, depth: depth + 1, into: &lines)
            case "table":
                guard let table = value as? [String: Any] else { continue }
                let name = table["table_name"].map { "\($0)" } ?? "table"
                let details = shown.compactMap { field -> String? in
                    guard let value = table[field] else { return nil }
                    let name = field.replacingOccurrences(of: "_", with: " ")
                    // using_index: true reads "using index".
                    if field.hasPrefix("using_") { return (value as? Bool) == true ? name : nil }
                    return "\(name): \(text(value))"
                }
                lines.append(indent + "Table " + name + (details.isEmpty ? "" : " (" + details.joined(separator: ", ") + ")"))
                for (inner, child) in table where child is [String: Any] || child is [Any] {
                    if inner == "possible_keys" || inner == "used_key_parts" { continue }
                    walk([inner: child], depth: depth + 1, into: &lines)
                }
            case let name where containers.contains(name):
                lines.append(indent + key.replacingOccurrences(of: "_", with: " ").capitalized)
                walk(value, depth: depth + 1, into: &lines)
            default:
                if value is [String: Any] || value is [Any] { walk(value, depth: depth, into: &lines) }
            }
        }
    }

    /// Query blocks and tables first, then the rest in name order, so the plan reads top down.
    static func order(_ key: String) -> String {
        (["query_block": "0", "table": "1", "nested_loop": "2"][plain(key)] ?? "3") + key
    }

    /// A key without the number `numberingRepeats` gave it.
    static func plain(_ key: String) -> String { String(key.prefix { $0 != "#" }) }

    static func text(_ value: Any) -> String {
        if let list = value as? [Any] { return list.map(text).joined(separator: ", ") }
        return "\(value)"
    }
}
