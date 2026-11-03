import Foundation

/// View As ▸ Text: rows as a plain-text table, the way the mysql client prints them (numbers to the right).
public enum GridText {
    /// `rows` by the columns given; nil is NULL. Values longer than `cellLimit` characters, or on several lines, are
    /// shortened to one line.
    public static func table(_ names: [String], _ rows: [[String?]], rightAligned: [Bool], nullText: String = "NULL",
                             cellLimit: Int = 200) -> String {
        func shown(_ value: String?) -> String {
            guard let value else { return nullText }
            let line = value.replacingOccurrences(of: "\r\n", with: "↵").replacingOccurrences(of: "\n", with: "↵")
                .replacingOccurrences(of: "\t", with: " ")
            return line.count > cellLimit ? String(line.prefix(cellLimit - 1)) + "…" : line
        }
        let cells = rows.map { $0.map(shown) }
        var widths = names.map(\.count)
        for row in cells {
            for (index, cell) in row.enumerated() where index < widths.count { widths[index] = max(widths[index], cell.count) }
        }
        let rule = "+" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "+"
        func line(_ values: [String], aligned: Bool) -> String {
            "| " + values.enumerated().map { index, value in
                let pad = String(repeating: " ", count: max(0, widths[index] - value.count))
                return aligned && rightAligned[index] ? pad + value : value + pad
            }.joined(separator: " | ") + " |"
        }
        return ([rule, line(names, aligned: false), rule] + cells.map { line($0, aligned: true) } + [rule]).joined(separator: "\n")
    }
}

extension JSONNode {
    /// View As ▸ Tree: rows as an array of objects, a key per column; numbers stay numbers, NULL is null, and a JSON
    /// column's value is a tree of its own.
    public static func rows(_ columns: [GridColumn], _ rows: [[String?]]) -> JSONNode {
        let items = rows.enumerated().map { index, row -> JSONNode in
            let fields = zip(columns, row).map { column, value -> JSONNode in
                guard let value else { return JSONNode(key: column.name, kind: .null, value: "null") }
                if column.kind == .json, let tree = JSONNode.parse(value) {
                    return JSONNode(key: column.name, kind: tree.kind, value: tree.value, children: tree.children)
                }
                if column.kind == .number, Double(value) != nil {
                    return JSONNode(key: column.name, kind: .number, value: value)
                }
                let quoted = (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "\"\(value)\""
                return JSONNode(key: column.name, kind: .string, value: quoted)
            }
            return JSONNode(key: "[\(index)]", kind: .object, value: "{\(fields.count) key\(fields.count == 1 ? "" : "s")}", children: fields)
        }
        return JSONNode(key: "", kind: .array, value: "[\(items.count) row\(items.count == 1 ? "" : "s")]", children: items)
    }
}
