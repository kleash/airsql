/// JSON checked and laid out without touching its values: strings and numbers are copied byte for byte (going through
/// JSONSerialization would turn 1.10 into 1.1 and round big integers), only the whitespace between them changes. Used
/// for MySQL's JSON and MariaDB's (LONGTEXT with a JSON_VALID check) alike, before Apply and in the editor.
public enum JSONText {
    /// Throws, saying where (line and column), when the text isn't one JSON value or nests deeper than `maxDepth`
    /// (MySQL takes 100 levels; MariaDB's JSON_VALID 31).
    public static func validate(_ text: String, maxDepth: Int = 100) throws {
        var parser = Parser(text, layout: nil, maxDepth: maxDepth)
        try parser.document()
    }

    /// Two-space indents, a member or element per line, as MySQL's JSON_PRETTY lays it out.
    public static func pretty(_ text: String) throws -> String {
        var parser = Parser(text, layout: "  ")
        try parser.document()
        return String(decoding: parser.output, as: UTF8.self)
    }

    /// No whitespace outside strings.
    public static func compact(_ text: String) throws -> String {
        var parser = Parser(text, layout: "")
        try parser.document()
        return String(decoding: parser.output, as: UTF8.self)
    }

    private struct Parser {
        let bytes: [UInt8]
        /// nil: check only; "": compact; otherwise the indent of one level.
        let indent: [UInt8]?
        let maxDepth: Int
        var index = 0
        var depth = 0
        var output: [UInt8] = []

        init(_ text: String, layout: String?, maxDepth: Int = 100) {
            bytes = Array(text.utf8)
            indent = layout.map { Array($0.utf8) }
            self.maxDepth = maxDepth
        }

        mutating func document() throws {
            skipSpace()
            guard index < bytes.count else { throw problem("It's empty; type a JSON value such as {} or []") }
            try value()
            skipSpace()
            guard index == bytes.count else { throw problem("Nothing may follow the JSON value") }
        }

        private mutating func value() throws {
            guard index < bytes.count else { throw problem("A value is missing at the end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): try container(close: UInt8(ascii: "}"), members: true)
            case UInt8(ascii: "["): try container(close: UInt8(ascii: "]"), members: false)
            case UInt8(ascii: "\""): try string()
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): try number()
            default:
                for word in ["true", "false", "null"] where bytes[index...].starts(with: word.utf8) {
                    emit(bytes[index..<index + word.utf8.count])
                    index += word.utf8.count
                    return
                }
                throw problem("Expected a value: an object, array, string, number, true, false or null")
            }
        }

        private mutating func container(close: UInt8, members: Bool) throws {
            depth += 1
            guard depth <= maxDepth else { throw problem("It nests deeper than \(maxDepth) levels, which the server refuses") }
            emit([bytes[index]])
            index += 1
            skipSpace()
            if index < bytes.count, bytes[index] == close {
                emit([close])
                index += 1
                depth -= 1
                return
            }
            while true {
                newline()
                if members {
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                        throw problem("Expected a key in double quotes")
                    }
                    try string()
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw problem("Expected : after the key") }
                    index += 1
                    emit(indent?.isEmpty == false ? Array(": ".utf8) : [UInt8(ascii: ":")])
                    skipSpace()
                }
                try value()
                skipSpace()
                guard index < bytes.count else { throw problem("It ends before the closing \(Character(Unicode.Scalar(close)))") }
                if bytes[index] == UInt8(ascii: ",") {
                    emit([UInt8(ascii: ",")])
                    index += 1
                    skipSpace()
                    continue
                }
                guard bytes[index] == close else {
                    throw problem("Expected , or \(Character(Unicode.Scalar(close)))")
                }
                index += 1
                depth -= 1
                newline()
                emit([close])
                return
            }
        }

        private mutating func string() throws {
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    emit(bytes[start..<index])
                    return
                }
                guard byte >= 0x20 else {
                    throw problem("A string can't hold a raw line break or control character; write \\n or \\t")
                }
                if byte == UInt8(ascii: "\\") {
                    index += 1
                    guard index < bytes.count else { break }
                    if bytes[index] == UInt8(ascii: "u") {
                        let hex = Array("0123456789abcdefABCDEF".utf8)
                        guard index + 4 < bytes.count, bytes[index + 1...index + 4].allSatisfy(hex.contains)
                        else { throw problem("\\u needs four hex digits") }
                        index += 4
                    } else if !Array(#""\/bfnrt"#.utf8).contains(bytes[index]) {
                        throw problem("Unknown escape \\\(Character(Unicode.Scalar(bytes[index])))")
                    }
                }
                index += 1
            }
            index = start
            throw problem("A string isn't closed")
        }

        private mutating func number() throws {
            let start = index
            func digits() -> Int {
                let from = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                return index - from
            }
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            let leadingZero = index < bytes.count && bytes[index] == UInt8(ascii: "0")
            let whole = digits()
            guard whole > 0, !(leadingZero && whole > 1) else { throw problem("A number can't start with 0 or a point") }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw problem("A point must have digits after it") }
            }
            if index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw problem("An exponent must have digits") }
            }
            emit(bytes[start..<index])
        }

        private mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        private mutating func emit<Bytes: Sequence>(_ part: Bytes) where Bytes.Element == UInt8 {
            if indent != nil { output.append(contentsOf: part) }
        }

        /// A line break and the current depth's indent, when laying out pretty.
        private mutating func newline() {
            guard let indent, !indent.isEmpty else { return }
            output.append(0x0A)
            for _ in 0..<depth { output.append(contentsOf: indent) }
        }

        /// The message with the line and column of `index`.
        private func problem(_ message: String) -> EditError {
            let before = bytes[..<min(index, bytes.count)]
            let line = before.filter { $0 == 0x0A }.count + 1
            let lineStart = before.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            let column = String(decoding: bytes[lineStart..<min(index, bytes.count)], as: UTF8.self).count + 1
            return EditError("JSON, line \(line), column \(column): \(message)")
        }
    }
}
