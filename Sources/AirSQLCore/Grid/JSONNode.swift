import Foundation

/// A JSON value as a tree for the value panel and View As ▸ Tree: objects keep their keys in the text's order (MariaDB
/// keeps a document as written), arrays number their items, and each node says what it holds ("{3 keys}", "\"b2b\"").
public final class JSONNode {
    public enum Kind: Equatable { case object, array, string, number, bool, null }

    /// The key in its object, "[0]" in an array, "" for the root.
    public let key: String
    public let kind: Kind
    /// A scalar as written (strings in quotes), or the size of an object or array.
    public let value: String
    public let children: [JSONNode]

    public init(key: String, kind: Kind, value: String, children: [JSONNode] = []) {
        self.key = key
        self.kind = kind
        self.value = value
        self.children = children
    }

    /// The tree of `text`, or nil when it isn't JSON (or nests deeper than 512 levels).
    public static func parse(_ text: String) -> JSONNode? {
        var parser = Parser(Array(text.utf8))
        guard let node = parser.value(key: "", depth: 0) else { return nil }
        parser.skipSpace()
        return parser.index == parser.bytes.count ? node : nil
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(key: String, depth: Int) -> JSONNode? {
            skipSpace()
            guard index < bytes.count, depth < 512 else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var children: [JSONNode] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1 } else {
                    while true {
                        skipSpace()
                        guard let name = string(), expect(":"), let child = value(key: name, depth: depth + 1) else { return nil }
                        children.append(child)
                        skipSpace()
                        if expect(",") { continue }
                        guard expect("}") else { return nil }
                        break
                    }
                }
                return JSONNode(key: key, kind: .object, value: "{\(children.count) key\(children.count == 1 ? "" : "s")}", children: children)
            case UInt8(ascii: "["):
                index += 1
                var children: [JSONNode] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1 } else {
                    while true {
                        guard let child = value(key: "[\(children.count)]", depth: depth + 1) else { return nil }
                        children.append(child)
                        skipSpace()
                        if expect(",") { continue }
                        guard expect("]") else { return nil }
                        break
                    }
                }
                return JSONNode(key: key, kind: .array, value: "[\(children.count) item\(children.count == 1 ? "" : "s")]", children: children)
            case UInt8(ascii: "\""):
                let start = index
                guard string() != nil else { return nil }
                return JSONNode(key: key, kind: .string, value: String(decoding: bytes[start..<index], as: UTF8.self))
            default:
                let start = index
                while index < bytes.count, !",:]} \t\r\n".utf8.contains(bytes[index]) { index += 1 }
                let word = String(decoding: bytes[start..<index], as: UTF8.self)
                switch word {
                case "true", "false": return JSONNode(key: key, kind: .bool, value: word)
                case "null": return JSONNode(key: key, kind: .null, value: word)
                default:
                    guard word.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
                    else { return nil }
                    return JSONNode(key: key, kind: .number, value: word)
                }
            }
        }

        mutating func expect(_ character: Character) -> Bool {
            skipSpace()
            guard index < bytes.count, bytes[index] == character.asciiValue! else { return false }
            index += 1
            return true
        }

        /// A string's text without its quotes and escapes; nil when it isn't one.
        mutating func string() -> String? {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") {
                    let literal = String(decoding: bytes[start..<index], as: UTF8.self)
                    return (try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed)) as? String
                } else if byte < 0x20 {
                    return nil
                }
            }
            return nil
        }
    }

    /// The JSON indented two spaces per level, keys in their order (Pretty in the value panel).
    public var pretty: String {
        func write(_ node: JSONNode, _ indent: String, into text: inout String) {
            switch node.kind {
            case .object, .array:
                let (open, close) = node.kind == .object ? ("{", "}") : ("[", "]")
                guard !node.children.isEmpty else { return text += open + close }
                text += open + "\n"
                for (index, child) in node.children.enumerated() {
                    text += indent + "  "
                    if node.kind == .object, let key = try? String(decoding: JSONSerialization.data(withJSONObject: child.key,
                                                                                                     options: .fragmentsAllowed), as: UTF8.self) {
                        text += key + ": "
                    }
                    write(child, indent + "  ", into: &text)
                    text += index < node.children.count - 1 ? ",\n" : "\n"
                }
                text += indent + close
            default:
                text += node.value
            }
        }
        var text = ""
        write(self, "", into: &text)
        return text
    }
}
