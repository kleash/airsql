import Foundation

// The object editors (scope: "Views, procedures, functions, triggers and events edited as CREATE code"): an object's
// CREATE statement as the server keeps it (`ObjectDefinition.load`), its DEFINER (`CreateHeader`, `settingDefiner`),
// and the statements that put edited code in place (`ObjectCode.statements`).

/// The kinds of object edited as CREATE code.
public enum ObjectKind: String, CaseIterable {
    case view, procedure, function, trigger, event

    /// VIEW, PROCEDURE…
    public var keyword: String { rawValue.uppercased() }

    /// SHOW CREATE VIEW `db`.`name`, and so on.
    public func showCreate(database: String, name: String) -> String {
        "SHOW CREATE " + keyword + " " + SQLQuote.identifier(database, name)
    }

    /// Where SHOW CREATE puts the statement, the object's sql_mode and (events) its time zone.
    var columns: (code: Int, sqlMode: Int?, timeZone: Int?) {
        switch self {
        case .view: return (1, nil, nil)
        case .procedure, .function, .trigger: return (2, 1, nil)
        case .event: return (3, 1, 2)
        }
    }
}

/// An object's code as the server keeps it, and the settings it was created under: re-creating it under the same
/// sql_mode (and an event under the same time zone) keeps its behaviour.
public struct ObjectDefinition: Equatable {
    public var code: String
    public var sqlMode: String?
    public var timeZone: String?

    public init(code: String, sqlMode: String? = nil, timeZone: String? = nil) {
        self.code = code
        self.sqlMode = sqlMode
        self.timeZone = timeZone
    }

    /// Reads the object's CREATE statement (SHOW CREATE …). The server gives no code to someone who may not see it.
    public static func load(_ kind: ObjectKind, database: String, name: String, from source: SchemaQuerying) async throws
        -> ObjectDefinition {
        let rows = try await source.rows(kind.showCreate(database: database, name: name))
        let columns = kind.columns
        guard let row = rows.first, columns.code < row.count, let code = row[columns.code] else {
            throw DesignError("The server didn't show the code of \(name): you may not have the right to see it")
        }
        return ObjectDefinition(code: code, sqlMode: columns.sqlMode.flatMap { $0 < row.count ? row[$0] : nil },
                                timeZone: columns.timeZone.flatMap { $0 < row.count ? row[$0] : nil })
    }
}

/// The start of a CREATE statement up to the object's name: whether it says OR REPLACE, its DEFINER, its kind and
/// name. Comments and spaces may come between the words; names may be quoted.
public struct CreateHeader {
    public let kind: ObjectKind
    public let orReplace: Bool
    /// The DEFINER clause ("DEFINER=`root`@`localhost`"), if any.
    public let definer: Range<String.Index>?
    /// Its account as the server names it: root@localhost.
    public let definerAccount: String?
    /// The database the code names, if it qualifies the name.
    public let database: String?
    public let name: String
    /// After CREATE, where OR REPLACE goes; where a DEFINER clause goes when there is none.
    let afterCreate: String.Index
    let definerSlot: String.Index

    public init?(_ code: String) {
        var scanner = HeaderScanner(code)
        guard scanner.word() == "CREATE" else { return nil }
        afterCreate = scanner.index
        var orReplace = false
        if scanner.peekWord() == "OR" {
            _ = scanner.word()
            guard scanner.word() == "REPLACE" else { return nil }
            orReplace = true
        }
        self.orReplace = orReplace
        var definer: Range<String.Index>?, account: String?, kind: ObjectKind?
        var slot = scanner.index
        while kind == nil {
            scanner.skipSpace()
            let start = scanner.index
            guard let word = scanner.word() else { return nil }
            switch word {
            case "ALGORITHM":
                guard scanner.symbol("="), scanner.word() != nil else { return nil }
                slot = scanner.index
            case "DEFINER":
                guard scanner.symbol("="), let user = scanner.name() else { return nil }
                var host: String?
                if scanner.symbol("@") {
                    host = scanner.name()
                } else if user.uppercased() == "CURRENT_USER", scanner.symbol("(") {
                    guard scanner.symbol(")") else { return nil }
                }
                definer = start..<scanner.index
                account = user + (host.map { "@" + $0 } ?? "")
            case "SQL":
                guard scanner.word() == "SECURITY", scanner.word() != nil else { return nil }
            case "AGGREGATE":
                break
            default:
                guard let found = ObjectKind(rawValue: word.lowercased()) else { return nil }
                kind = found
            }
        }
        self.kind = kind!
        self.definer = definer
        definerAccount = account
        definerSlot = slot
        if scanner.peekWord() == "IF" {
            _ = scanner.word()
            guard scanner.word() == "NOT", scanner.word() == "EXISTS" else { return nil }
        }
        guard let first = scanner.name() else { return nil }
        if scanner.symbol(".") {
            guard let second = scanner.name() else { return nil }
            database = first
            name = second
        } else {
            database = nil
            name = first
        }
    }
}

/// Reads the words, names and symbols at the start of a statement, skipping spaces and comments.
struct HeaderScanner {
    let text: String
    var index: String.Index

    init(_ text: String) {
        self.text = text
        index = text.startIndex
    }

    mutating func skipSpace() {
        while index < text.endIndex {
            let rest = text[index...]
            if rest.first!.isWhitespace {
                index = text.index(after: index)
            } else if rest.hasPrefix("/*"), !rest.hasPrefix("/*!"), !rest.hasPrefix("/*M!") {
                index = rest.range(of: "*/").map(\.upperBound) ?? text.endIndex
            } else if rest.hasPrefix("#") || rest.hasPrefix("-- ") || rest.hasPrefix("--\t") || rest.hasPrefix("--\n") {
                index = rest.firstIndex(of: "\n") ?? text.endIndex
            } else {
                return
            }
        }
    }

    /// The next bare word, uppercased.
    mutating func word() -> String? {
        skipSpace()
        let start = index
        while index < text.endIndex, text[index].isLetter || text[index].isNumber || text[index] == "_" || text[index] == "$" {
            index = text.index(after: index)
        }
        return start == index ? nil : text[start..<index].uppercased()
    }

    mutating func peekWord() -> String? {
        var copy = self
        return copy.word()
    }

    mutating func symbol(_ symbol: Character) -> Bool {
        skipSpace()
        guard index < text.endIndex, text[index] == symbol else { return false }
        index = text.index(after: index)
        return true
    }

    /// A name: `quoted` (backticks doubled inside), 'a string' or "a string", or a bare word as written.
    mutating func name() -> String? {
        skipSpace()
        guard index < text.endIndex else { return nil }
        let quote = text[index]
        guard quote == "`" || quote == "'" || quote == "\"" else {
            let start = index
            while index < text.endIndex, text[index].isLetter || text[index].isNumber || "_$".contains(text[index]) {
                index = text.index(after: index)
            }
            return start == index ? nil : String(text[start..<index])
        }
        var name = ""
        index = text.index(after: index)
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if character == quote {
                guard index < text.endIndex, text[index] == quote else { return name }
                index = text.index(after: index)
            } else if character == "\\", quote != "`", index < text.endIndex {
                name.append(text[index])
                index = text.index(after: index)
                continue
            }
            name.append(character)
        }
        return nil
    }
}
