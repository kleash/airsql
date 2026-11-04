import Foundation

/// Tables and columns the schema cache doesn't have, underlined as advice while typing (Run still runs). Nothing goes
/// to the server: the live check through prepare was dropped because prepare runs real code. A false alarm is worse
/// than a miss, so whatever isn't certain stays silent: a database whose details aren't loaded, anything the text or
/// this session has created or altered, derived tables, CTEs, and every statement other than a plain SELECT, INSERT,
/// REPLACE, UPDATE or DELETE. A column is checked only when every table of its statement is known, against all of
/// them, subqueries' too, so a correlated subquery can't be wrong; inside a function's brackets, where words like YEAR
/// and CHAR aren't names, only a column with its table in front is checked.
public enum SQLNameCheck {
    /// What can be said about `text`, in UTF-16 offsets. `changed`: from `changedNames` of what this session has run.
    public static func problems(in text: String, snapshot: SchemaSnapshot?, database: String?, changed: Set<String> = [],
                                noBackslashEscapes: Bool = false) -> [SQLProblem] {
        guard let snapshot else { return [] }
        let statements = SQLSplitter.statements(in: text, noBackslashEscapes: noBackslashEscapes)
        let changed = statements.reduce(into: changed) { $0.formUnion(changedNames(in: $1.sql, noBackslashEscapes: noBackslashEscapes)) }
        var database = database, problems: [SQLProblem] = []
        for statement in statements {
            let tokens = SQLLexer.tokens(statement.sql, noBackslashEscapes: noBackslashEscapes)
            let words = StatementCheck.codeWords(statement.sql, noBackslashEscapes: noBackslashEscapes)
            guard let first = words.first else { continue }
            // Past these, the tables and the current database are anyone's guess (a routine's body, split on its ;).
            if ["CALL", "EXECUTE", "DECLARE"].contains(first.text) || (first.text == "BEGIN" && words.count > 1 && words[1].text == "NOT")
                || (first.text == "CREATE" && words.contains { $0.text == "BEGIN" }) { break }
            if first.text == "USE" {
                database = words.count > 1 ? SQLQuote.unquoted(words[1].raw) : nil
                continue
            }
            // A statement half typed, or with code in an executable comment, is one this can't read.
            guard tokens.allSatisfy({ $0.isClosed && $0.kind != .codeStart }) else { continue }
            var scan = Scan(words: words)
            guard scan.read() else { continue }
            problems += scan.problems(snapshot, database, changed).map {
                SQLProblem(range: ($0.range.lowerBound + statement.range.lowerBound)..<($0.range.upperBound + statement.range.lowerBound),
                           message: $0.message)
            }
        }
        return Array(problems.prefix(ConsoleScript.unclosedLimit))
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

    private struct Table {
        var database: String?
        var name: String
        var alias: String?
        var range: Range<Int>
    }

    /// One pass over a statement's words, keeping its tables and the names that may be columns.
    private struct Scan {
        let words: [StatementCheck.Word]
        var index = 0
        var tables: [Table] = []
        /// A FROM holds something other than plain tables.
        var columnsOff = false
        var bare: [(name: String, range: Range<Int>)] = []
        var qualified: [(table: String, name: String, range: Range<Int>)] = []
        /// Names that may be declared here rather than columns: after AS, or after a value (`SELECT a + 1 total`).
        var aliases = Set<String>()

        init(words: [StatementCheck.Word]) {
            // After ON DUPLICATE KEY, row aliases (VALUES … AS new(a, b)) name columns this can't see.
            let end = words.indices.first { words[$0].text == "ON" && $0 + 1 < words.count && words[$0 + 1].text == "DUPLICATE" }
            self.words = Array(words[..<(end ?? words.count)])
        }

        private func isName(_ i: Int) -> Bool { i < words.count && (words[i].kind == .word || words[i].kind == .quotedName) }
        private func text(_ i: Int) -> String { i >= 0 && i < words.count && words[i].kind != .quotedName ? words[i].text : "" }
        /// A name that can only be a name here: quoted, or not a reserved word.
        private func isPlainName(_ i: Int) -> Bool {
            isName(i) && (words[i].kind == .quotedName || !SQLWords.reserved.contains(words[i].text))
        }

        /// False when the statement is one to leave alone.
        mutating func read() -> Bool {
            var column = false  // INSERT's list of columns comes right after the table
            switch words[0].text {
            case "SELECT":
                break
            case "INSERT", "REPLACE":
                index = 1
                while ["LOW_PRIORITY", "DELAYED", "HIGH_PRIORITY", "IGNORE", "INTO"].contains(text(index)) { index += 1 }
                readTables(list: false)
                column = text(index) == "("
            case "UPDATE":
                index = 1
                while ["LOW_PRIORITY", "IGNORE"].contains(text(index)) { index += 1 }
                readTables(list: true)
            case "DELETE":
                // In DELETE FROM a USING t a, what follows FROM are aliases; before a FROM, they are too.
                guard !words.indices.contains(where: { text($0) == "USING" && text($0 + 1) != "(" }),
                      let from = words.firstIndex(where: { $0.text == "FROM" }) else { return false }
                index = from
            default:
                return false
            }
            guard !words.contains(where: { $0.kind == .word && $0.text == "WITH" }) else { return false }  // CTEs
            // The brackets open here: those of a function hide their words, and FROM's list goes on after a comma.
            var frames = [(hidden: false, inFrom: words[0].text == "UPDATE")]
            while index < words.count {
                let i = index, word = words[i]
                index += 1
                switch word.kind {
                case .symbol where word.raw == "(":
                    let function = isName(i - 1) && !Self.valueLeads.contains(text(i - 1)) && !column
                    frames.append((hidden: text(i + 1) != "SELECT" && (function || frames.last!.hidden), inFrom: false))
                    column = false
                case .symbol where word.raw == ")":
                    frames.removeLast()
                    if frames.isEmpty { return false }
                case .symbol where word.raw == "," && frames.last!.inFrom:
                    readTables(list: true)
                case .symbol where word.raw == "{":
                    columnsOff = true  // ODBC's { OJ … } and { d '…' }
                case .string where text(i - 1) == "AS":
                    aliases.insert(word.raw.dropFirst().dropLast().lowercased())
                case .word, .quotedName:
                    if word.kind == .word, Self.strangers.contains(word.text) { columnsOff = true }
                    if word.kind == .word, Self.fromEnds.contains(word.text) { frames[frames.count - 1].inFrom = false }
                    if word.kind == .word, !frames.last!.hidden, word.text == "FROM" || word.text == "JOIN" {
                        frames[frames.count - 1].inFrom = true
                        readTables(list: true)
                    } else {
                        readName(at: i, hidden: frames.last!.hidden)
                    }
                default:
                    break
                }
            }
            return frames.count == 1
        }

        /// Words after which a value starts, so a name there is a column; a bracket after them isn't a function's.
        static let valueLeads: Set<String> = ["SELECT", "DISTINCT", "WHERE", "AND", "OR", "XOR", "NOT", "ON", "BY", "HAVING",
                                              "WHEN", "THEN", "ELSE", "CASE", "LIKE", "BETWEEN", "IN", "SET", "DIV", "MOD"]
        /// Words that can come straight after a column.
        static let valueEnds: Set<String> = ["FROM", "AS", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "AND", "OR", "XOR", "IS",
                                             "IN", "NOT", "LIKE", "BETWEEN", "REGEXP", "RLIKE", "DESC", "ASC", "ON", "JOIN", "INNER",
                                             "LEFT", "RIGHT", "CROSS", "UNION", "THEN", "ELSE", "END", "WHEN", "DIV", "MOD", "SET"]
        /// What ends a FROM's list.
        static let clauses: Set<String> = ["WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "UNION", "EXCEPT", "INTERSECT", "SET", "SELECT",
                                           "RETURNING"]
        /// Syntax with names of its own, which this doesn't follow: its statement's columns aren't checked.
        static let strangers: Set<String> = ["WINDOW", "LATERAL", "JSON_TABLE", "STRAIGHT_JOIN", "INTO", "FOR", "LOCK", "PROCEDURE"]
        static let fromEnds = clauses.union(strangers)
        /// Words that aren't columns: keywords, functions that need no brackets, and columns no list shows.
        static let notColumns: Set<String> = SQLWords.reserved.union(SQLCompletion.keywords).union(SQLFunction.all.map { $0.name.uppercased() })
            .union(["TRUE", "FALSE", "UNKNOWN", "SQL_CACHE", "SQL_NO_CACHE", "SQL_BUFFER_RESULT", "QUICK", "ROWNUM", "SYSDATE",
                    "_ROWID", "MY_ROW_ID", "ROW_START", "ROW_END", "NEXT", "PREVIOUS", "LASTVAL", "NEXTVAL", "CURRENT_ROLE", "USER"])

        /// A table list from `index`: `[db.]name [PARTITION (…)] [[AS] alias]`, with commas if `list`. Anything else in
        /// it, such as a derived table, turns the columns off; its brackets are left for `read`.
        private mutating func readTables(list: Bool) {
            repeat {
                guard isPlainName(index), !list || text(index + 1) != "(" else {
                    columnsOff = true
                    return
                }
                var table = Table(database: nil, name: SQLQuote.unquoted(words[index].raw), alias: nil, range: words[index].range)
                index += 1
                if text(index) == "." {
                    guard isName(index + 1) else {
                        columnsOff = true
                        return
                    }
                    table.database = table.name
                    table.name = SQLQuote.unquoted(words[index + 1].raw)
                    table.range = words[index + 1].range
                    index += 2
                }
                if text(index) == "PARTITION", text(index + 1) == "(" {
                    while index < words.count, words[index].raw != ")" { index += 1 }
                    index += 1
                }
                if text(index) == "AS" { index += 1 }
                if isPlainName(index), text(index + 1) != "(", !Self.fromEnds.contains(text(index)) {
                    table.alias = SQLQuote.unquoted(words[index].raw)
                    index += 1
                }
                tables.append(table)
                guard list, index < words.count, words[index].raw == "," else { return }
                index += 1
            } while true
        }

        /// Sorts the name at `i`: part of `a.b`, a column, or something declared.
        private mutating func readName(at i: Int, hidden: Bool) {
            guard text(i - 1) != "." else { return }
            let name = SQLQuote.unquoted(words[i].raw)
            if text(i + 1) == "." {
                // table.column; db.table.column and functions stay silent.
                index = i + 2
                while text(index) == "." || isName(index) && text(index - 1) == "." { index += 1 }
                if index == i + 3, isName(i + 2), text(index) != "(" {
                    qualified.append((name, SQLQuote.unquoted(words[i + 2].raw), words[i + 2].range))
                }
                return
            }
            guard !hidden else { return }
            if text(i - 1) == "AS" { return aliases.formUnion([name.lowercased()]) }
            if words[i].kind == .word, Self.notColumns.contains(words[i].text) { return }
            let before = i == 0 ? nil : words[i - 1], after = i + 1 < words.count ? words[i + 1] : nil
            let leads = before.map { $0.kind == .symbol ? $0.raw != ")" : Self.valueLeads.contains(text(i - 1)) } ?? false
            let ends = after.map { $0.kind == .symbol ? $0.raw != "(" : Self.valueEnds.contains(text(i + 1)) } ?? true
            if leads && ends {
                bare.append((name, words[i].range))
            } else {
                aliases.insert(name.lowercased())
            }
        }

        func problems(_ snapshot: SchemaSnapshot, _ current: String?, _ changed: Set<String>) -> [SQLProblem] {
            var problems: [SQLProblem] = []
            var known: [(table: Table, columns: SchemaTable)] = []
            var allKnown = !columnsOff && !tables.isEmpty
            for table in tables {
                guard let name = table.database ?? current, let database = snapshot.database(name), database.detailsLoaded,
                      !["information_schema", "performance_schema"].contains(database.name.lowercased()),
                      Self.isASCII(table.name), !changed.contains(table.name.lowercased()), table.name.uppercased() != "DUAL",
                      !(snapshot.server?.flavour == .mariadb && table.name.hasPrefix("seq_"))  // the Sequence engine's virtual tables
                else {
                    allKnown = false
                    continue
                }
                if let found = snapshot.table(database.name, table.name), !found.columns.isEmpty {
                    known.append((table, found))
                } else {
                    allKnown = false
                    if snapshot.table(database.name, table.name) == nil {
                        problems.append(SQLProblem(range: table.range, message: "No table named “\(table.name)” in “\(database.name)”, "
                                                   + "as far as AirSQL knows. If it's new, refresh the schema"))
                    }
                }
            }
            guard allKnown else { return problems }
            for column in bare where Self.isASCII(column.name) && !aliases.contains(column.name.lowercased())
                && !known.contains(where: { Self.has($0.columns, column.name) }) {
                let place = known.count == 1 ? "“\(known[0].columns.name)”" : "the tables this statement uses"
                problems.append(SQLProblem(range: column.range, message: "No column named “\(column.name)” in \(place), "
                                           + "as far as AirSQL knows. If it's new, refresh the schema"))
            }
            for column in qualified where Self.isASCII(column.name) {
                let named = known.filter { ($0.table.alias ?? $0.table.name).caseInsensitiveCompare(column.table) == .orderedSame }
                guard !named.isEmpty, !named.contains(where: { Self.has($0.columns, column.name) }) else { continue }
                problems.append(SQLProblem(range: column.range, message: "No column named “\(column.name)” in “\(named[0].columns.name)”, "
                                           + "as far as AirSQL knows. If it's new, refresh the schema"))
            }
            return problems.sorted { $0.range.lowerBound < $1.range.lowerBound }
        }

        /// Column names compare without case or accents (cafe is café).
        private static func has(_ table: SchemaTable, _ column: String) -> Bool {
            table.columns.contains { $0.name.compare(column, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }

        /// The server's collations fold accents and other scripts in ways a plain comparison doesn't.
        private static func isASCII(_ name: String) -> Bool { name.utf16.allSatisfy { $0 < 128 } }
    }
}
