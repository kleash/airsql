/// What the editor can fold: a statement, what's in a pair of brackets, a comment or a `-- region` of several lines. A
/// fold keeps its first line and hides from that line's end. Offsets are UTF-16 code units.
public enum SQLFolding {
    /// The hidden part of each region, in order of where it starts, the longest first.
    public static func regions(in text: String, noBackslashEscapes: Bool = false) -> [Range<Int>] {
        let units = Array(text.utf16)
        var regions: [Range<Int>] = []
        /// From the end of the line of `start`, when `end` is on a later line.
        func add(_ start: Int, _ end: Int) {
            var lineEnd = start
            while lineEnd < end, units[lineEnd] != 0x0A { lineEnd += 1 }
            if lineEnd < end { regions.append(lineEnd..<end) }
        }
        for statement in SQLSplitter.statements(in: text, noBackslashEscapes: noBackslashEscapes) {
            add(statement.range.lowerBound, statement.end)
        }
        var brackets: [Int] = [], marks: [Int] = []
        for token in SQLLexer.tokens(text, noBackslashEscapes: noBackslashEscapes) {
            let start = token.range.lowerBound
            switch token.kind {
            case .symbol where token.range.count == 1 && units[start] == 0x28: brackets.append(start)
            case .symbol where token.range.count == 1 && units[start] == 0x29:
                if let open = brackets.popLast() { add(open, start) }
            case .symbol where token.range.count == 1 && units[start] == 0x3B: brackets = []
            case .comment where units[start] == 0x2F: add(start, token.range.upperBound)
            case .comment:
                let words = String(decoding: units[token.range], as: UTF16.self).drop { "-# ".contains($0) }.lowercased()
                if words.hasPrefix("region") {
                    marks.append(start)
                } else if words.hasPrefix("endregion"), let open = marks.popLast() {
                    add(open, token.range.upperBound)
                }
            default: break
            }
        }
        return Set(regions).sorted { ($0.lowerBound, -$0.count) < ($1.lowerBound, -$1.count) }
    }
}
