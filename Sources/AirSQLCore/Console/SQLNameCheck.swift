import Foundation

/// Tables and columns the schema cache doesn't have, underlined as advice while typing (Run still runs). Nothing goes
/// to the server: the live check through prepare was dropped because prepare runs real code. A false alarm is worse
/// than a miss, so whatever isn't certain stays silent: a database whose details aren't loaded, anything the text or
/// this session has created or altered, a statement with a syntax error, and a column when a table it could belong to
/// isn't fully known (`SQLResolver` does the reading).
public enum SQLNameCheck {
    /// What can be said about `text`, in UTF-16 offsets. `changed`: from `changedNames` of what this session has run.
    public static func problems(in text: String, snapshot: SchemaSnapshot?, database: String?, changed: Set<String> = [],
                                noBackslashEscapes: Bool = false) -> [SQLProblem] {
        guard let snapshot else { return [] }
        let analysis = SQLAnalysis(text, snapshot: snapshot, database: database, changed: changed, noBackslashEscapes: noBackslashEscapes)
        return Array(problems(analysis).prefix(ConsoleScript.unclosedLimit))
    }

    /// The unknown names of an analysis.
    static func problems(_ analysis: SQLAnalysis) -> [SQLProblem] {
        let refresh = "as far as AirSQL knows. If it's new, refresh the schema"
        return analysis.issues.sorted { $0.range.lowerBound < $1.range.lowerBound }.compactMap { issue in
            switch issue.kind {
            case .unknownTable(let database):
                return SQLProblem(range: issue.range, message: "No table named “\(issue.name)” in “\(database)”, \(refresh)")
            case .unknownColumn(let place):
                return SQLProblem(range: issue.range, message: "No column named “\(issue.name)” in \(place), \(refresh)")
            default:
                return nil
            }
        }
    }

    /// The names (lower case) in `sql` if it is a statement that makes or changes tables: a temporary table's name is
    /// nowhere else to be found, and a new or altered table isn't in the cache yet. Every name, to stay simple: the
    /// worst of an extra one is a miss.
    public static func changedNames(in sql: String, noBackslashEscapes: Bool = false) -> Set<String> {
        let words = StatementCheck.codeWords(sql, noBackslashEscapes: noBackslashEscapes)
        guard let first = words.first, ["CREATE", "ALTER", "DROP", "RENAME"].contains(first.text) else { return [] }
        return Set(words.filter { $0.kind == .word || $0.kind == .quotedName }.map { SQLQuote.unquoted($0.raw).lowercased() })
    }

    /// Whether `sql` runs code that can make tables nobody sees in the text: what it leaves on the session is unknown.
    public static func runsCode(_ sql: String, noBackslashEscapes: Bool = false) -> Bool {
        ["CALL", "EXECUTE"].contains(StatementCheck.codeWords(sql, noBackslashEscapes: noBackslashEscapes).first?.text ?? "")
    }
}
