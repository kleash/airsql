import Foundation

/// How a compare writes schema details so the same thing reads the same on MySQL and MariaDB: type spellings, default
/// expressions, check clauses, and the noise the ignore rules leave out.
enum ReconNormal {
    private static let integers = ["tinyint", "smallint", "mediumint", "int", "bigint"]

    /// A column's type: lowercase, MariaDB's JSON (LONGTEXT with a check) as json, without integer display widths
    /// (MySQL 8.0.19+ drops them) or YEAR's (4).
    static func type(_ column: SchemaColumn) -> String {
        if column.isJSON { return "json" }
        var type = column.columnType.lowercased()
        for name in integers + ["year"] where type.hasPrefix(name + "(") {
            if let close = type.firstIndex(of: ")") {
                type = name + type[type.index(after: close)...]
            }
        }
        return type
    }

    /// utf8 is utf8mb3 (older servers say utf8, newer ones utf8mb3).
    static func charset(_ name: String?) -> String? {
        guard let name = name?.lowercased() else { return nil }
        if name == "utf8" { return "utf8mb3" }
        return name.hasPrefix("utf8_") ? "utf8mb3_" + name.dropFirst(5) : name
    }

    /// Defaults as both flavours mean them: CURRENT_TIMESTAMP whichever way it is written, expressions without the
    /// parentheses MySQL puts around them.
    static func defaultValue(_ value: SchemaDefault) -> SchemaDefault {
        guard case .expression(let text) = value else { return value }
        return .expression(expression(text))
    }

    /// ON UPDATE CURRENT_TIMESTAMP(3) and on update current_timestamp(3) are the same.
    static func onUpdate(_ text: String?) -> String? { text.map(expression) }

    /// An expression (default, generated column, check) without spelling noise: whitespace, case outside quotes,
    /// character set introducers (MySQL writes _utf8mb4'a'), outer parentheses, now() and current_timestamp().
    static func expression(_ text: String) -> String {
        var text = compact(text, lowercase: true)
        for introducer in ["_utf8mb4'", "_utf8mb3'", "_utf8'", "_latin1'", "_binary'", "_ascii'"] {
            text = text.replacingOccurrences(of: introducer, with: "'")
        }
        while text.hasPrefix("("), text.hasSuffix(")"), balanced(text.dropFirst().dropLast()) {
            text = String(text.dropFirst().dropLast())
        }
        for (from, to) in [("current_timestamp()", "current_timestamp"), ("now()", "current_timestamp"),
                           ("localtimestamp()", "current_timestamp"), ("current_date()", "curdate()")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text.replacingOccurrences(of: "now(", with: "current_timestamp(")
    }

    /// Parentheses in `text` pair up (outside quotes), so the outer pair around it can go.
    private static func balanced(_ text: Substring) -> Bool {
        var depth = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "'", "\"", "`": quote = character
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth < 0 { return false }
            default: break
            }
        }
        return depth == 0
    }

    /// RESTRICT and NO ACTION do the same in InnoDB; servers show either for a key declared without a rule.
    static func rule(_ rule: String) -> String {
        let rule = rule.uppercased()
        return rule == "NO ACTION" ? "RESTRICT" : rule
    }

    /// A definition (SHOW CREATE … of a view, routine, trigger, event or sequence) as compared: without DEFINER=…
    /// when that's ignored, without the database's own name before object names, without whitespace when ignored.
    static func definition(_ text: String, database: String, rules: ReconIgnoreRules) -> String {
        var text = qualifiersRemoved(text, database: database)
        if rules.definer { text = definerRemoved(text) }
        return rules.whitespace ? compact(text, lowercase: false) : text
    }

    /// `db`.`name` → `name`, for the database a definition belongs to (MySQL qualifies the names in a view's body).
    static func qualifiersRemoved(_ text: String, database: String) -> String {
        text.replacingOccurrences(of: SQLQuote.identifier(database) + ".", with: "")
    }

    /// The text with the database's own qualifier replaced by another database's (a view's body for the target).
    static func qualifiersMapped(_ text: String, from: String, to: String) -> String {
        from == to ? text : text.replacingOccurrences(of: SQLQuote.identifier(from) + ".", with: SQLQuote.identifier(to) + ".")
    }

    /// Without its DEFINER=`user`@`host` clause, so it runs as whoever runs the script.
    static func definerRemoved(_ text: String) -> String {
        guard let range = text.range(of: "DEFINER=", options: .caseInsensitive) else { return text }
        var index = range.upperBound
        // `user`@`host`, 'user'@'host', user@host or CURRENT_USER, each part possibly quoted with doubled quotes.
        while index < text.endIndex, !text[index].isWhitespace {
            if let close = text[index] == "`" || text[index] == "'" ? text[index] : nil {
                index = text.index(after: index)
                while index < text.endIndex {
                    if text[index] == close {
                        let next = text.index(after: index)
                        if next < text.endIndex, text[next] == close {
                            index = text.index(after: next)
                            continue
                        }
                        break
                    }
                    index = text.index(after: index)
                }
                if index < text.endIndex { index = text.index(after: index) }
            } else {
                index = text.index(after: index)
            }
        }
        var end = index
        while end < text.endIndex, text[end] == " " { end = text.index(after: end) }
        return String(text[..<range.lowerBound] + text[end...])
    }

    /// The text without whitespace that doesn't matter: outside quotes and comments, a run of whitespace becomes one
    /// space between two word characters and nothing elsewhere; a line comment keeps its line break. `lowercase`
    /// lowercases outside quotes too.
    static func compact(_ text: String, lowercase: Bool) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        var pendingSpace = false
        func isWord(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return scalar == "_" || scalar == "$" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }
        func emit(_ scalar: Unicode.Scalar) {
            if pendingSpace, isWord(result.last), isWord(scalar) { result.append(" ") }
            pendingSpace = false
            result.append(scalar)
        }
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            if scalar.properties.isWhitespace {
                pendingSpace = !result.isEmpty
                index += 1
            } else if scalar == "'" || scalar == "\"" || scalar == "`" {
                // Quoted text as it is, with doubled quotes and (outside backticks) backslash escapes.
                emit(scalar)
                index += 1
                while index < scalars.count {
                    let inner = scalars[index]
                    result.append(inner)
                    index += 1
                    if inner == "\\", scalar != "`", index < scalars.count {
                        result.append(scalars[index])
                        index += 1
                    } else if inner == scalar {
                        guard index < scalars.count, scalars[index] == scalar else { break }
                        result.append(scalars[index])
                        index += 1
                    }
                }
            } else if scalar == "#" || scalar == "-" && next == "-"
                        && (index + 2 == scalars.count || scalars[index + 2].properties.isWhitespace) {
                emit(scalar)
                index += 1
                while index < scalars.count, scalars[index] != "\n" {
                    result.append(scalars[index])
                    index += 1
                }
                if index < scalars.count { result.append("\n") }
                index += 1
            } else if scalar == "/" && next == "*" {
                emit(scalar)
                result.append("*")
                index += 2
                while index < scalars.count {
                    if scalars[index] == "*", index + 1 < scalars.count, scalars[index + 1] == "/" {
                        result.append("*")
                        result.append("/")
                        index += 2
                        break
                    }
                    result.append(scalars[index])
                    index += 1
                }
            } else {
                if lowercase {
                    for lower in String(scalar).lowercased().unicodeScalars { emit(lower) }
                } else {
                    emit(scalar)
                }
                index += 1
            }
        }
        return String(result)
    }
}
