import Foundation

/// A formatted SQL changelog read the way Liquibase 4 reads one (FormattedSqlChangeLogParser, StringUtil's statement
/// splitting): the `--liquibase formatted sql` line, then changesets of SQL with their --comment, --rollback and
/// --precondition lines. AirSQL checks what it writes with it before saving, numbers the changesets it adds to a
/// changelog, and runs a changelog's statements in its tests.
public struct LiquibaseChangelog: Equatable {
    public struct Changeset: Equatable {
        public var author: String
        public var id: String
        /// The line of its --changeset.
        public var line: Int
        public var sql = ""
        public var rollback = ""
        public var comment: String?
        public var splitStatements = true
        public var stripComments = true
        public var endDelimiter: String?
        public var runOnChange = false
        public var preconditions = false

        /// What runs, in order: the SQL split and stripped of comments as its attributes say.
        public var statements: [String] {
            LiquibaseChangelog.split(sql, splitStatements: splitStatements, stripComments: stripComments, endDelimiter: endDelimiter)
        }

        /// What --rollback runs (split on semicolons, comments stripped: Liquibase's defaults).
        public var rollbackStatements: [String] {
            LiquibaseChangelog.split(rollback, splitStatements: true, stripComments: true, endDelimiter: nil)
        }
    }

    /// Why Liquibase would refuse the changelog, and where.
    public struct Problem: LocalizedError, Equatable {
        public var line: Int
        public var message: String
        public var errorDescription: String? { "Line \(line): \(message)" }
    }

    public static let header = "--liquibase formatted sql"

    public var changesets: [Changeset] = []

    /// Reads `text`, or throws the first problem Liquibase would stop at.
    public init(_ text: String) throws {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let first = lines.first, Self.matches(first, #"^\s*--\s*liquibase\s*formatted.*"#) else {
            throw Problem(line: 1, message: "A formatted SQL changelog starts with the line \(Self.header)")
        }
        var current: Changeset?
        var sql: [String] = []
        var index = 0
        func finish() throws {
            guard var changeset = current else { return }
            changeset.sql = sql.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !changeset.sql.isEmpty else {
                throw Problem(line: changeset.line, message: "The changeset \(changeset.author):\(changeset.id) has no SQL")
            }
            if changesets.contains(where: { $0.author == changeset.author && $0.id == changeset.id }) {
                throw Problem(line: changeset.line, message: "Two changesets are \(changeset.author):\(changeset.id): each needs its own id")
            }
            changesets.append(changeset)
        }
        while index < lines.count {
            let line = lines[index], number = index + 1
            index += 1
            // Every instruction starts with - or /* (after spaces): other lines are SQL, or nothing outside a changeset.
            guard Self.mayInstruct(line) else {
                if current != nil { sql.append(line) }
                continue
            }
            if Self.matches(line, #"^\s*--[\s]*property\s+(.*:.*)\s+(.*:.*).*"#) { continue }
            if Self.matches(line, #"^\s*?-+\s*property\s.*"#) {
                throw Problem(line: number, message: "Write a property as --property name:<name> value:<value>")
            }
            if let count = Self.group(line, #"^--[\s]*ignoreLines:(\w+)$"#) {
                if count == "start" {
                    while index < lines.count, Self.group(lines[index], #"^--[\s]*ignoreLines:(\w+)$"#) != "end" { index += 1 }
                    index += 1
                } else if let skip = Int(count) {
                    index += skip
                } else {
                    throw Problem(line: number, message: "Write --ignoreLines:start, --ignoreLines:end or --ignoreLines:<count>")
                }
                continue
            }
            if Self.matches(line, #"^--[\s]*ignore:(\w+)"#) || Self.matches(line, #"^-[\s]*?ignoreLines:(\w+).*$"#) {
                throw Problem(line: number, message: "Write --ignoreLines:start, --ignoreLines:end or --ignoreLines:<count>")
            }
            if let head = Self.groups(line, #"^\s*--[\s]*changeset\s+("[^"]+"|[^:]+):\s*("[^"]+"|\S+).*"#) {
                try finish()
                guard Self.matches(line, #"^\s*--[\s]*changeset\s+"# + NSRegularExpression.escapedPattern(for: head[0] + ":" + head[1])
                                   + ".*$") else {
                    throw Problem(line: number, message: "Write the changeset as --changeset author:id, with no space after the colon")
                }
                var changeset = Changeset(author: Self.unquoted(head[0]), id: Self.unquoted(head[1]), line: number)
                changeset.splitStatements = Self.group(line, #".*splitStatements:(\w+).*"#).map { $0.lowercased() == "true" } ?? true
                changeset.stripComments = Self.group(line, #".*stripComments:(\w+).*"#).map { $0.lowercased() == "true" } ?? true
                changeset.runOnChange = Self.group(line, #".*runOnChange:(\w+).*"#)?.lowercased() == "true"
                changeset.endDelimiter = Self.group(line, #".*endDelimiter:(\S*).*"#)
                current = changeset
                sql = []
                continue
            }
            if Self.matches(line, #"^-[\s]*changeset\s.*"#) || Self.matches(line, #"^\s*--[\s]*changeset[\s]*.*$"#) {
                throw Problem(line: number, message: "Write the changeset as --changeset author:id")
            }
            guard current != nil else {
                if Self.matches(line, #"^--[\s]*comment:? (.*)"#) {
                    throw Problem(line: number, message: "A --comment line belongs inside a changeset")
                }
                continue
            }
            if let comment = Self.group(line, #"^--[\s]*comment:? (.*)"#) {
                current?.comment = comment
            } else if Self.matches(line, #"^-[\s]*comment:? (.*)"#) || Self.matches(line, #"^--[\s]*comments:? (.*)"#) {
                throw Problem(line: number, message: "Write a comment as --comment: <text>")
            } else if Self.matches(line, #"^--[\s]*validCheckSum:? (.*)"#) {
                continue
            } else if Self.matches(line, #"^-[\s]*validCheckSum(.*)$"#) {
                throw Problem(line: number, message: "Write a checksum as --validCheckSum: <checksum>")
            } else if let rollback = Self.group(line, #"^\s*--[\s]*rollback (.*)"#) {
                current?.rollback += rollback + "\n"
            } else if Self.matches(line, #"^\s*-[\s]*rollback\s.*"#) {
                throw Problem(line: number, message: "Write a rollback as --rollback <SQL>")
            } else if Self.matches(line, #"^\s*/\*\s*liquibase\s*rollback\s*$"#) {
                var closed = false
                while index < lines.count {
                    let next = lines[index]
                    index += 1
                    if let end = next.range(of: #"\*/\s*$"#, options: .regularExpression) {
                        current?.rollback += next[..<end.lowerBound] + "\n"
                        closed = true
                        break
                    }
                    current?.rollback += next + "\n"
                }
                if !closed { throw Problem(line: number, message: "The /* liquibase rollback comment isn't closed") }
            } else if Self.matches(line, #"^\s*--[\s]*preconditions(.*)"#) {
                current?.preconditions = true
            } else if Self.matches(line, #"^\s*-[\s]*preconditions\s.*"#) {
                throw Problem(line: number, message: "Write preconditions as --preconditions onFail:<action> onError:<action>")
            } else if let check = Self.groups(line, #"^\s*--[\s]*precondition\-([a-zA-Z0-9-]+) (.*)"#) {
                guard ["sql-check", "table-exists", "view-exists"].contains(check[0]) else {
                    throw Problem(line: number, message: "Liquibase has no \(check[0]) precondition in formatted SQL")
                }
                if check[0] == "sql-check", !Self.matches(check[1].trimmingCharacters(in: .whitespaces),
                                                          #"^(?:expectedResult:)?(\w+|'[^']+'|"[^"]+") (.*)"#) {
                    throw Problem(line: number, message: "Write the check as --precondition-sql-check expectedResult:<value> <SQL>")
                }
            } else if Self.matches(line, #"^\s*-[\s]*precondition(.*)"#) || Self.matches(line, #"^\s*--[\s]*precondition\-([a-zA-Z0-9-]+)$"#) {
                throw Problem(line: number, message: "Write a precondition as --precondition-sql-check expectedResult:<value> <SQL>")
            } else {
                sql.append(line)
            }
        }
        try finish()
    }

    /// The SQL of a changeset as the statements Liquibase runs: split at the end delimiter (`;` by default) outside
    /// strings, comments and BEGIN … END blocks, and without -- and /* */ comments unless stripComments is false.
    public static func split(_ sql: String, splitStatements: Bool, stripComments: Bool, endDelimiter: String?) -> [String] {
        let text = Array(sql.utf16)
        let tokens = SQLLexer.tokens(sql)
        let delimiter = endDelimiter.map { Array($0.utf16) }
        var statements: [String] = [], current: [UInt16] = [], blocks = 0, position = 0, k = 0
        func flush() {
            let statement = String(decoding: current, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !statement.isEmpty { statements.append(statement) }
            current = []
        }
        func word(_ index: Int) -> String? {
            guard index < tokens.count, tokens[index].kind == .word else { return nil }
            return String(decoding: text[tokens[index].range], as: UTF16.self).uppercased()
        }
        while k < tokens.count {
            let token = tokens[k]
            current += text[position..<token.range.lowerBound]  // the whitespace before it
            position = token.range.upperBound
            let atLineStart = current.last.map { $0 == 0x0A } ?? true
            // A comment Liquibase strips: -- and /* */ (with /*! … */ code and its */), not MySQL's own # comments.
            if stripComments, [.comment, .hint].contains(token.kind), text[token.range.lowerBound] != 0x23 {
                k += 1
                continue
            }
            if stripComments, token.kind == .codeStart {
                while k < tokens.count, tokens[k].kind != .codeEnd { k += 1 }
                position = k < tokens.count ? tokens[k].range.upperBound : text.count
                k += 1
                continue
            }
            let upper = word(k)
            let next = word(k + 1)
            let transaction = ["TRANSACTION", "TRANS", "TRAN"].contains(next ?? "")
            if upper == "BEGIN", !transaction { blocks += 1 }
            if upper == "END", blocks > 0, !transaction { blocks -= 1 }
            if splitStatements, blocks == 0, token.kind == .symbol || token.kind == .word {
                if let delimiter {
                    let end = token.range.lowerBound + delimiter.count
                    if end <= text.count, Array(text[token.range.lowerBound..<end]).lowercased == delimiter.lowercased,
                       delimiter != Array("/".utf16) || atLineStart {
                        flush()
                        position = end
                        while k < tokens.count, tokens[k].range.lowerBound < end { k += 1 }
                        continue
                    }
                } else if token.range.count == 1 && text[token.range.lowerBound] == 0x3B
                            || atLineStart && (upper == "GO" || token.range.count == 1 && text[token.range.lowerBound] == 0x2F) {
                    flush()
                    k += 1
                    continue
                }
            }
            current += text[token.range]
            k += 1
        }
        current += text[position...]
        flush()
        return statements
    }

    /// Whether Liquibase would read `line`, inside a changeset, as one of its instructions (or refuse it as a misspelt
    /// one) rather than as SQL.
    public static func isInstruction(_ line: String) -> Bool {
        guard mayInstruct(line) else { return false }
        let sql = "SELECT 1;\n" + line
        guard let changelog = try? LiquibaseChangelog(header + "\n--changeset a:b\n" + sql) else { return true }
        return changelog.changesets.first?.sql != sql.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Patterns

    /// Starts with - or /* after spaces and tabs: the only lines that can be instructions.
    static func mayInstruct(_ line: String) -> Bool {
        let rest = line.drop { $0 == " " || $0 == "\t" }
        return rest.hasPrefix("-") || rest.hasPrefix("/*")
    }

    static func matches(_ line: String, _ pattern: String) -> Bool { groups(line, pattern) != nil }

    static func group(_ line: String, _ pattern: String) -> String? { groups(line, pattern)?.first }

    private static let cache = NSCache<NSString, NSRegularExpression>()

    /// The capture groups of `pattern` matched against the whole line, case-insensitively (as Liquibase matches).
    static func groups(_ line: String, _ pattern: String) -> [String]? {
        let full = pattern.hasSuffix("$") ? pattern : pattern + "$"
        let expression: NSRegularExpression
        if let cached = cache.object(forKey: full as NSString) {
            expression = cached
        } else {
            guard let compiled = try? NSRegularExpression(pattern: full, options: [.caseInsensitive]) else { return nil }
            cache.setObject(compiled, forKey: full as NSString)
            expression = compiled
        }
        guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.range.location == 0 else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }

    static func unquoted(_ text: String) -> String {
        text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"") ? String(text.dropFirst().dropLast()) : text
    }
}

private extension Array where Element == UInt16 {
    /// ASCII letters in lower case (delimiters such as GO match without case).
    var lowercased: [UInt16] { map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 } }
}
