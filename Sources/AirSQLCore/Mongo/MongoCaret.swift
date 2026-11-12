import Foundation

/// Where the caret is in half-typed shell-form text (mongo-plan, Phase 3: autofill): the keys from the root down to it,
/// what is typed there and the keys beside it. One scan up to the caret, past strings and regular expressions, keeping a
/// stack of the documents, arrays and calls open; no parse, so text that doesn't parse yet still has a place. Offsets are
/// UTF-16 code units.
public struct MongoCaret: Equatable, Sendable {
    /// What the whole text is: the caller knows.
    public enum Root: String, Sendable {
        case filter, projection, sort, hint, collation, update, pipeline
        /// An inserted document, or an edited field's value.
        case document
    }

    public enum Slot: Equatable, Sendable {
        /// A document's key, bare or quoted (`quoted`).
        case key
        /// A value, not in quotes.
        case value
        /// Inside a quoted value.
        case string
        /// Inside a quoted value after `"$`: a field path.
        case reference
        /// Inside a quoted value after `"$$`: a variable.
        case variable
        /// Inside a regular expression, a call's arguments or after a key before its colon: nothing fits.
        case none
    }

    public let root: Root
    /// The keys down to the caret, `[]` for an array's element, a value's own key last: `$group › total › $sum`. In a
    /// pipeline, from the stage's name (the pipeline's own array left out).
    public var chain: [String] = []
    public var slot = Slot.value
    /// What is typed at the caret (without an opening quote), and where.
    public var prefix = ""
    public var range: Range<Int>
    /// A key being typed in quotes.
    public var quoted = false
    /// The keys already in the caret's document, and those of them with a plain value (`from: "orders"`).
    public var siblings: [String] = []
    public var values: [String: String] = [:]
    /// A pipeline's stages closed before the caret's, each from its `{` to just after its `}`.
    public var stagesBefore: [Range<Int>] = []

    private struct Frame {
        enum Kind { case document, array, call }
        var kind: Kind
        var start: Int
        /// The key whose value is being read (a document's).
        var key: String?
        /// A key read, its colon not yet.
        var pending: String?
        var siblings: [String] = []
        var values: [String: String] = [:]
        var expectsKey: Bool { kind == .document && key == nil }
    }

    public init(text: String, caret: Int, root: Root) {
        self.root = root
        let units = Array(text.utf16.prefix(max(0, caret)))
        let end = units.count
        range = end..<end
        var stack: [Frame] = []
        let first = units.first { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }
        // The text may leave out its outermost brackets: a filter typed `status: "paid"`, stages one after another.
        switch root {
        case .pipeline where first != 0x5B: stack.append(Frame(kind: .array, start: 0))
        case .filter, .projection, .sort, .collation, .update: if first != 0x7B { stack.append(Frame(kind: .document, start: 0)) }
        default: break
        }
        let pipelineDepth = 1  // a stage is a document right inside the pipeline's array

        func isWord(_ c: UInt16) -> Bool {
            SQLLexer.isNameChar(c) || c == 0x2E || c == 0x2D || c == 0x2B  // . - + (paths, numbers)
        }
        func scalar(_ value: String) {
            guard let top = stack.indices.last, let key = stack[top].key else { return }
            stack[top].values[key] = value
        }

        var i = 0, inString: (start: Int, quote: UInt16)?, inRegex = false
        scan: while i < end {
            let c = units[i]
            switch c {
            case 0x7B, 0x5B, 0x28:  // { [ (
                stack.append(Frame(kind: c == 0x7B ? .document : c == 0x5B ? .array : .call, start: i))
                i += 1
            case 0x7D, 0x5D, 0x29:  // } ] )
                if let frame = stack.popLast(), root == .pipeline, frame.kind == .document, stack.count == pipelineDepth {
                    stagesBefore.append(frame.start..<(i + 1))
                }
                i += 1
            case 0x2C:  // ,
                if let top = stack.indices.last, stack[top].kind == .document { (stack[top].key, stack[top].pending) = (nil, nil) }
                i += 1
            case 0x3A:  // :
                if let top = stack.indices.last, stack[top].kind == .document, let key = stack[top].pending {
                    stack[top].key = key
                    stack[top].pending = nil
                    stack[top].siblings.append(key)
                }
                i += 1
            case 0x22, 0x27:  // " '
                var j = i + 1
                while j < end, units[j] != c {
                    if units[j] == 0x5C { j += 1 }
                    j += 1
                }
                guard j < end else {
                    inString = (i + 1, c)
                    break scan
                }
                let content = String(decoding: units[(i + 1)..<j], as: UTF16.self)
                if let top = stack.indices.last, stack[top].expectsKey { stack[top].pending = content } else { scalar(content) }
                i = j + 1
            case 0x2F:  // a regular expression: shell form has no division
                var j = i + 1, inClass = false
                while j < end, inClass || units[j] != 0x2F {
                    if units[j] == 0x5C { j += 1 } else if units[j] == 0x5B { inClass = true } else if units[j] == 0x5D { inClass = false }
                    j += 1
                }
                guard j < end else {
                    inRegex = true
                    break scan
                }
                i = j + 1
            case _ where isWord(c):
                var j = i
                while j < end, isWord(units[j]) { j += 1 }
                if j == end { break scan }  // the word at the caret: what is typed
                let word = String(decoding: units[i..<j], as: UTF16.self)
                if let top = stack.indices.last, stack[top].expectsKey { stack[top].pending = word } else { scalar(word) }
                i = j
            default:
                i += 1
            }
        }

        let top = stack.last
        chain = stack.compactMap { $0.kind == .array ? "[]" : $0.kind == .document ? $0.key : nil }
        if root == .pipeline, !chain.isEmpty { chain.removeFirst() }
        siblings = top?.siblings ?? []
        values = top?.values ?? [:]
        if inRegex { slot = .none; return }
        if let (start, _) = inString {
            prefix = String(decoding: units[start...], as: UTF16.self)
            range = start..<end
            if top?.expectsKey == true {
                (slot, quoted) = (.key, true)
            } else {
                slot = prefix.hasPrefix("$$") ? .variable : prefix.hasPrefix("$") ? .reference : .string
            }
            return
        }
        var start = end
        while start > 0, isWord(units[start - 1]) { start -= 1 }
        prefix = String(decoding: units[start...], as: UTF16.self)
        range = start..<end
        switch top?.kind {
        case .document?: slot = top!.expectsKey ? (top!.pending == nil || !prefix.isEmpty ? .key : .none) : .value
        case .call?: slot = .none
        default: slot = .value
        }
    }
}
