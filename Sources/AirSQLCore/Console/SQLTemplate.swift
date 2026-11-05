import Foundation

/// A saved piece of SQL: from the helpers panel, or by its abbreviation and Tab. Its body is a template.
public struct SQLSnippet: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    /// What's typed for it, with Tab; empty: none.
    public var abbreviation: String
    /// The group it's listed under; empty: none.
    public var folder: String
    public var body: String

    public init(name: String, abbreviation: String = "", folder: String = "", body: String) {
        self.name = name
        self.abbreviation = abbreviation
        self.folder = folder
        self.body = body
    }

    /// Those that come with AirSQL. A person's own of the same abbreviation goes first.
    public static let builtIn: [SQLSnippet] = [
        SQLSnippet(name: "Every row of a table", abbreviation: "sel", body: "SELECT * FROM $table$;$END$"),
        SQLSnippet(name: "Rows that meet a condition", abbreviation: "selw", body: "SELECT * FROM $table$ WHERE $condition$;$END$"),
        SQLSnippet(name: "Count rows", abbreviation: "selc", body: "SELECT COUNT(*) FROM $table$ WHERE $condition$;$END$"),
        SQLSnippet(name: "The first rows of a table", abbreviation: "lim", body: "SELECT * FROM $table$ LIMIT $rows$;$END$"),
        SQLSnippet(name: "Insert a row", abbreviation: "ins", body: "INSERT INTO $table$ ($columns$) VALUES ($values$);$END$"),
        SQLSnippet(name: "Update rows", abbreviation: "upd", body: "UPDATE $table$ SET $column$ = $value$ WHERE $condition$;$END$"),
        SQLSnippet(name: "Delete rows", abbreviation: "del", body: "DELETE FROM $table$ WHERE $condition$;$END$"),
        SQLSnippet(name: "New table", abbreviation: "tab", body: "CREATE TABLE $table$ (\n    id INT PRIMARY KEY AUTO_INCREMENT,\n    $column$ $type$\n);$END$"),
        SQLSnippet(name: "New view", abbreviation: "view", body: "CREATE VIEW $view$ AS\nSELECT $columns$ FROM $table$;$END$"),
        SQLSnippet(name: "New column", abbreviation: "col", body: "ALTER TABLE $table$ ADD COLUMN $column$ $type$;$END$"),
    ]
}

/// A snippet's body: plain SQL with fields. `$name$` is a field to fill in, its name there to type over; the same name
/// again follows it. Tab goes from field to field and on to `$END$`, where the cursor rests. `$SELECTION$` is the selected
/// text, for Surround With. `$$` is a dollar. A `$` that starts none of these is itself.
public enum SQLTemplate {
    public struct Expansion: Equatable, Sendable {
        public var text: String
        /// The fields in order, each with every place it's in (UTF-16 offsets of `text`).
        public var fields: [[Range<Int>]]
        /// Where the cursor ends.
        public var end: Int?
    }

    public static func expand(_ body: String, selection: String = "") -> Expansion {
        let source = Array(body.utf16)
        var out: [UInt16] = [], names: [String] = [], fields: [[Range<Int>]] = [], end: Int?, index = 0
        func isName(_ unit: UInt16, first: Bool) -> Bool {
            unit == 0x5F || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || (!first && (0x30...0x39).contains(unit))
        }
        while index < source.count {
            guard source[index] == 0x24 else {
                out.append(source[index])
                index += 1
                continue
            }
            if index + 1 < source.count, source[index + 1] == 0x24 {
                out.append(0x24)
                index += 2
                continue
            }
            var close = index + 1
            while close < source.count, isName(source[close], first: close == index + 1) { close += 1 }
            guard close > index + 1, close < source.count, source[close] == 0x24 else {
                out.append(0x24)
                index += 1
                continue
            }
            let name = String(decoding: source[(index + 1)..<close], as: UTF16.self)
            index = close + 1
            if name == "END" {
                end = out.count
            } else if name == "SELECTION" {
                out += Array(selection.utf16)
            } else {
                let range = out.count..<(out.count + name.utf16.count)
                out += Array(name.utf16)
                if let known = names.firstIndex(of: name) {
                    fields[known].append(range)
                } else {
                    names.append(name)
                    fields.append([range])
                }
            }
        }
        return Expansion(text: String(decoding: out, as: UTF16.self), fields: fields, end: end)
    }

    /// `text` as a body that expands to itself.
    public static func escape(_ text: String) -> String { text.replacingOccurrences(of: "$", with: "$$") }
}
