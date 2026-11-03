import Foundation

/// SHOW CREATE TABLE's text read line by line. Both MySQL and MariaDB write each column, key and constraint on a line
/// of its own, so the sync script can take the source server's own definitions (types, defaults, generated columns,
/// key options) rather than rebuild them.
struct ReconCreateTable {
    enum Kind { case column, index, foreignKey, check, other }

    struct Line {
        var kind: Kind
        /// The column, key or constraint name; PRIMARY for the primary key.
        var name: String
        /// The definition without its indentation and comma.
        var text: String
    }

    /// "CREATE TABLE `orders` (".
    var head: String
    var lines: [Line]
    /// From the closing parenthesis on: ") ENGINE=InnoDB … COMMENT='…'", and partitioning after it.
    var tail: String

    init?(_ text: String) {
        var rows = text.components(separatedBy: "\n")
        guard rows.count >= 2, rows[0].hasSuffix("("),
              let close = rows.lastIndex(where: { $0.hasPrefix(")") }), close > 0 else { return nil }
        head = rows[0]
        tail = rows[close...].joined(separator: "\n")
        rows = Array(rows[1..<close])
        lines = rows.map { row in
            var text = row.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(",") { text.removeLast() }
            return Self.line(text)
        }
    }

    private static func line(_ text: String) -> Line {
        if text.hasPrefix("`"), let name = identifier(text[...]) { return Line(kind: .column, name: name, text: text) }
        if text.hasPrefix("PRIMARY KEY") { return Line(kind: .index, name: "PRIMARY", text: text) }
        if text.hasPrefix("CONSTRAINT "), let name = identifier(text.dropFirst(11)) {
            let rest = text.dropFirst(11 + SQLQuote.identifier(name).count).trimmingCharacters(in: .whitespaces)
            return Line(kind: rest.hasPrefix("FOREIGN KEY") ? .foreignKey : rest.hasPrefix("CHECK") ? .check : .other,
                        name: name, text: text)
        }
        for keyword in ["UNIQUE KEY ", "KEY ", "FULLTEXT KEY ", "SPATIAL KEY ", "VECTOR KEY ", "UNIQUE INDEX ", "INDEX "]
        where text.hasPrefix(keyword) {
            if let name = identifier(text.dropFirst(keyword.count)) { return Line(kind: .index, name: name, text: text) }
        }
        return Line(kind: .other, name: "", text: text)
    }

    /// The backticked name `text` starts with (doubled backticks in it read as one).
    static func identifier(_ text: Substring) -> String? {
        guard text.first == "`" else { return nil }
        var name = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if character == "`" {
                guard index < text.endIndex, text[index] == "`" else { return name }
                index = text.index(after: index)
            }
            name.append(character)
        }
        return nil
    }

    /// The definition of a column, key or constraint, matched by name without case.
    func definition(_ kind: Kind, _ name: String) -> String? {
        lines.first { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }?.text
    }

    /// The foreign keys' definitions.
    var foreignKeys: [String] { lines.filter { $0.kind == .foreignKey }.map(\.text) }

    /// The CREATE TABLE without foreign keys (the script adds them once every table exists) and without the next
    /// AUTO_INCREMENT value.
    var withoutForeignKeys: String {
        let kept = lines.filter { $0.kind != .foreignKey }.map { "  " + $0.text }
        var tail = self.tail
        if let range = tail.range(of: #" AUTO_INCREMENT=\d+"#, options: .regularExpression) {
            tail.removeSubrange(range)
        }
        return ([head, kept.joined(separator: ",\n"), tail]).joined(separator: "\n")
    }
}
