import Foundation

/// The console's query parameters: `?`, `:name` and `${name}` in a statement's code, never in a string or comment. They are filled
/// in on this Mac before the statement goes, as quoted values, so the read-only and safety checks see the final SQL.
public enum QueryParameters {
    /// A parameter in a statement: its place (UTF-16, in the statement) and its key: "?1", "?2"… by order among the
    /// statements of a run, ":name" by name, so the same name takes one value.
    public struct Place: Equatable, Sendable {
        public var range: Range<Int>
        public var key: String
        /// The comment right after it, which says what it is (a routine's `? /* p_id int */`).
        public var hint: String?
    }

    /// Each statement's places, in order.
    public static func places(in statements: [String], noBackslashEscapes: Bool) -> [[Place]] {
        var question = 0
        return statements.map { sql in
            let text = Array(sql.utf16)
            let tokens = SQLLexer.tokens(sql, noBackslashEscapes: noBackslashEscapes)
            var found: [Place] = []
            for (index, token) in tokens.enumerated() where token.kind == .symbol && token.range.count == 1 {
                if text[token.range.lowerBound] == 0x3F {
                    question += 1
                    var hint: String?
                    if index + 1 < tokens.count, tokens[index + 1].kind == .comment {
                        hint = String(decoding: text[tokens[index + 1].range], as: UTF16.self)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/* "))
                    }
                    found.append(Place(range: token.range, key: "?\(question)", hint: hint))
                } else if text[token.range.lowerBound] == 0x3A, index + 1 < tokens.count, tokens[index + 1].kind == .word,
                          tokens[index + 1].range.lowerBound == token.range.upperBound,
                          // lbl:LOOP is a label.
                          index == 0 || tokens[index - 1].range.upperBound < token.range.lowerBound || tokens[index - 1].kind == .symbol {
                    let word = tokens[index + 1].range
                    found.append(Place(range: token.range.lowerBound..<word.upperBound,
                                       key: ":" + String(decoding: text[word], as: UTF16.self)))
                }
            }
            // ${name}: `$` is a name's letter to the lexer.
            for (index, token) in tokens.enumerated() where index + 3 < tokens.count && token.kind == .word
                && String(decoding: text[token.range], as: UTF16.self) == "$" {
                let (open, name, close) = (tokens[index + 1], tokens[index + 2], tokens[index + 3])
                guard open.kind == .symbol, text[open.range.lowerBound] == 0x7B, name.kind == .word, close.kind == .symbol,
                      text[close.range.lowerBound] == 0x7D, open.range.lowerBound == token.range.upperBound,
                      name.range.lowerBound == open.range.upperBound, close.range.lowerBound == name.range.upperBound else { continue }
                found.append(Place(range: token.range.lowerBound..<close.range.upperBound,
                                   key: ":" + String(decoding: text[name.range], as: UTF16.self)))
            }
            found.sort { $0.range.lowerBound < $1.range.lowerBound }
            return found
        }
    }

    /// The keys to ask for, each once, in order.
    public static func keys(_ places: [[Place]]) -> [String] {
        var seen = Set<String>()
        return places.joined().map(\.key).filter { seen.insert($0).inserted }
    }

    /// What a typed value becomes in the SQL: a plain number as it is (not 007, which may be text), NULL as NULL, and
    /// anything else a quoted string, so a value can never become code.
    public static func literal(_ value: String, noBackslashEscapes: Bool) -> String {
        if value.uppercased() == "NULL" { return "NULL" }
        if value.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil { return value }
        return SQLQuote.string(value, noBackslashEscapes: noBackslashEscapes)
    }

    /// `sql` with each of `places` replaced by its value's literal.
    public static func bind(_ sql: String, _ places: [Place], values: [String: String], noBackslashEscapes: Bool) -> String {
        var text = Array(sql.utf16)
        for place in places.reversed() {
            text.replaceSubrange(place.range, with: literal(values[place.key] ?? "", noBackslashEscapes: noBackslashEscapes).utf16)
        }
        return String(decoding: text, as: UTF16.self)
    }
}
