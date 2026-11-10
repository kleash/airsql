import Foundation

/// An aggregation pipeline as the editor holds it (mongo-plan, Aggregation): an array of stage documents in shell form,
/// `[{$match: …}, {$group: …}]`, or the stages alone, one after another with or without commas between them. Each
/// stage keeps where it is in the text, so the editor folds one stage per region and points an error at its place.
/// Offsets are UTF-16 code units, as in `SQLFolding`.
public enum MongoPipeline {
    public struct Stage: Equatable, Sendable {
        public var document: BSONDocument
        /// From its `{` to just after its `}`.
        public var range: Range<Int>
        /// The operator: `$match`, `$group`, …
        public var name: String { document.fields.first?.key ?? "" }
    }

    /// What's wrong with the text, where: the stage (from 0) when it is in one, its line and column (from 1, in
    /// characters) and its UTF-16 offset.
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var message: String
        public var stage: Int?
        public var line: Int
        public var column: Int
        public var offset: Int
        public var description: String { "Line \(line), column \(column): \(message)" }
    }

    /// The stages of `text`, each a document with exactly one field whose name starts with `$`. Empty text is an empty
    /// pipeline.
    public static func stages(in text: String) throws -> [Stage] {
        let units = Array(text.utf16)
        var stages: [Stage] = []
        var i = 0
        func skipSpace() { while i < units.count, [0x20, 0x09, 0x0A, 0x0D].contains(units[i]) { i += 1 } }
        func fail(_ message: String, at offset: Int, stage: Int? = nil) -> ParseError {
            let (line, column) = place(of: offset, in: units)
            return ParseError(message: message, stage: stage, line: line, column: column, offset: offset)
        }
        func found(_ at: Int) -> String {
            at < units.count ? "‘" + String(decoding: units[at..<at + 1], as: UTF16.self) + "’" : "the end of the text"
        }

        skipSpace()
        let bracketed = i < units.count && units[i] == UInt8(ascii: "[")
        if bracketed { i += 1 }
        while true {
            skipSpace()
            if i == units.count {
                if bracketed { throw fail("The pipeline’s ‘[’ has no closing ‘]’", at: i) }
                break
            }
            if bracketed && units[i] == UInt8(ascii: "]") {
                i += 1
                skipSpace()
                guard i == units.count else { throw fail("Expected the end of the text after the pipeline’s ‘]’, found \(found(i))", at: i) }
                break
            }
            guard units[i] == UInt8(ascii: "{") else {
                throw fail("Expected a stage such as {$match: {…}}, found \(found(i))", at: i)
            }
            let start = i
            i = end(ofDocumentAt: start, in: units)
            let index = stages.count
            let document: BSONDocument
            do {
                document = try BSONDocument(shellForm: String(decoding: units[start..<i], as: UTF16.self))
            } catch let error as BSONError {
                throw shifted(error, stage: index, start: start, units: units)
            }
            guard document.fields.count == 1, let name = document.fields.first?.key, name.hasPrefix("$") else {
                let message: String
                switch document.fields.count {
                case 0: message = "Stage \(index + 1) is empty: a stage is one operator, such as {$match: {…}}"
                case 1: message = "Stage \(index + 1)’s ‘\(document.fields[0].key)’ isn’t a stage: a stage’s name starts with $, such as $match"
                default:
                    message = "Stage \(index + 1) has \(document.fields.count) fields (\(document.keys.joined(separator: ", "))): "
                        + "a stage is one operator, so put each in a stage of its own"
                }
                throw fail(message, at: start, stage: index)
            }
            stages.append(Stage(document: document, range: start..<i))
            skipSpace()
            if i < units.count && units[i] == UInt8(ascii: ",") { i += 1 }
        }
        return stages
    }

    /// The stages as the editor shows them: an array with each stage indented on lines of its own.
    public static func text(_ stages: [BSONDocument]) -> String {
        guard !stages.isEmpty else { return "[]" }
        let blocks = stages.map { "  " + $0.shellForm(pretty: true).replacingOccurrences(of: "\n", with: "\n  ") }
        return "[\n" + blocks.joined(separator: ",\n") + "\n]"
    }

    /// Just after the `}` that closes the `{` at `start`, past strings and regular expressions; the end of the text
    /// when it never closes (the parser then says what's missing).
    static func end(ofDocumentAt start: Int, in units: [UInt16]) -> Int {
        var depth = 0, i = start
        while i < units.count {
            let c = units[i]
            switch c {
            case UInt16(UInt8(ascii: "{")), UInt16(UInt8(ascii: "[")): depth += 1
            case UInt16(UInt8(ascii: "}")), UInt16(UInt8(ascii: "]")):
                depth -= 1
                if depth == 0 { return i + 1 }
            case UInt16(UInt8(ascii: "\"")), UInt16(UInt8(ascii: "'")):
                i += 1
                while i < units.count, units[i] != c, units[i] != 0x0A {
                    if units[i] == UInt16(UInt8(ascii: "\\")) { i += 1 }
                    i += 1
                }
            case UInt16(UInt8(ascii: "/")):
                // Shell form has no division: a `/` starts a regular expression, which may hold brackets.
                var inClass = false
                i += 1
                while i < units.count, units[i] != 0x0A, inClass || units[i] != UInt16(UInt8(ascii: "/")) {
                    switch units[i] {
                    case UInt16(UInt8(ascii: "\\")): i += 1
                    case UInt16(UInt8(ascii: "[")): inClass = true
                    case UInt16(UInt8(ascii: "]")): inClass = false
                    default: break
                    }
                    i += 1
                }
            default: break
            }
            i += 1
        }
        return units.count
    }

    /// The shell parser's error, which counts from the stage's own start, moved to the whole text's line and column.
    static func shifted(_ error: BSONError, stage: Int, start: Int, units: [UInt16]) -> ParseError {
        let pattern = #/^Line (\d+), column (\d+): (.*)$/#
        let (startLine, startColumn) = place(of: start, in: units)
        guard let match = error.message.wholeMatch(of: pattern.dotMatchesNewlines()), let line = Int(match.1), let column = Int(match.2) else {
            return ParseError(message: error.message, stage: stage, line: startLine, column: startColumn, offset: start)
        }
        let wholeLine = startLine + line - 1, wholeColumn = line == 1 ? startColumn + column - 1 : column
        return ParseError(message: String(match.3), stage: stage, line: wholeLine, column: wholeColumn,
                          offset: offset(line: wholeLine, column: wholeColumn, in: units))
    }

    /// Line and column (from 1; the column in characters, as the shell parser counts) of a UTF-16 offset.
    static func place(of offset: Int, in units: [UInt16]) -> (line: Int, column: Int) {
        let before = units[..<min(offset, units.count)]
        let lineStart = before.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        return (before.filter { $0 == 0x0A }.count + 1, String(decoding: before[lineStart...], as: UTF16.self).count + 1)
    }

    static func offset(line: Int, column: Int, in units: [UInt16]) -> Int {
        var start = 0
        for _ in 1..<max(line, 1) { start = (units[start...].firstIndex(of: 0x0A) ?? units.count - 1) + 1 }
        let lineEnd = units[start...].firstIndex(of: 0x0A) ?? units.count
        let text = String(decoding: units[start..<lineEnd], as: UTF16.self)
        return start + text.prefix(column - 1).utf16.count
    }
}
