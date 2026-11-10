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

// MARK: Writing stages, views and saved pipelines (lane P2-aggregate)

extension MongoPipeline {
    /// `$out` or `$merge` when a stage writes to a collection: such a pipeline runs only after a preview, and never on a
    /// read-only connection, in a view or in an export.
    public static func writingStage(_ stages: [BSONDocument]) -> String? {
        stages.compactMap(\.keys.first).first { $0 == "$out" || $0 == "$merge" }
    }

    /// Save as View's command: a view named `name` on `collection` that gives what `stages` give, with their collation.
    public static func viewCommand(_ name: String, on collection: String, _ stages: [BSONDocument],
                                   collation: BSONDocument? = nil) -> BSONDocument {
        BSONDocument([("create", .string(name)), ("viewOn", .string(collection)), ("pipeline", .array(stages.map { .document($0) }))]
                     + (collation.map { [("collation", .document($0))] } ?? []))
    }
}

extension MongoSession {
    /// Runs Save as View's `create` command (`MongoPipeline.viewCommand`) on `database`.
    public func saveView(_ command: BSONDocument, database: String) async throws {
        _ = try await self.command(command, database: database)
    }
}

/// The pipelines kept by name for each collection (Save Pipeline…), beside the query history (`MongoQueryHistory`): in
/// MongoHistory/<connection>.pipelines.json (0600), read and written on a queue of their own.
public final class MongoSavedPipelines: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var database: String
        public var collection: String
        public var name: String
        /// The editor's text, as it was saved.
        public var text: String
    }

    public static let shared = MongoSavedPipelines(directory: MongoQueryHistory.shared.directory)

    public let directory: URL
    private let queue = DispatchQueue(label: "com.kleash.airsql.mongo-pipelines")

    public init(directory: URL) { self.directory = directory }

    func file(_ connection: UUID) -> URL { directory.appendingPathComponent(connection.uuidString + ".pipelines.json") }

    /// The collection's pipelines by name.
    public func entries(_ connection: UUID, database: String, collection: String) async -> [Entry] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: read(connection).filter { $0.database == database && $0.collection == collection }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
        }
    }

    /// Keeps `text` as `name`, replacing a pipeline of that name.
    public func save(_ name: String, text: String, connection: UUID, database: String, collection: String) {
        change(connection, database, collection) { mine in
            mine.removeAll { $0.name == name }
            mine.append(Entry(database: database, collection: collection, name: name, text: text))
        }
    }

    /// Renames a pipeline; one already called `new` is replaced.
    public func rename(_ old: String, to new: String, connection: UUID, database: String, collection: String) {
        change(connection, database, collection) { mine in
            guard old != new, mine.contains(where: { $0.name == old }) else { return }
            mine.removeAll { $0.name == new }
            if let index = mine.firstIndex(where: { $0.name == old }) { mine[index].name = new }
        }
    }

    public func delete(_ name: String, connection: UUID, database: String, collection: String) {
        change(connection, database, collection) { mine in mine.removeAll { $0.name == name } }
    }

    /// Waits for the writes asked for so far (tests).
    public func flush() { queue.sync {} }

    /// `body` changes the collection's pipelines; the others stay as they are.
    private func change(_ connection: UUID, _ database: String, _ collection: String, _ body: @escaping (inout [Entry]) -> Void) {
        queue.async { [self] in
            var all = read(connection)
            var mine = all.filter { $0.database == database && $0.collection == collection }
            all.removeAll { $0.database == database && $0.collection == collection }
            body(&mine)
            guard let data = try? JSONEncoder().encode(all + mine) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = file(connection)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func read(_ connection: UUID) -> [Entry] {
        guard let data = try? Data(contentsOf: file(connection)) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
