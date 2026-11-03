import Foundation

// Liquibase formatted SQL changelogs (plan §2.9, scope group "lb"): changesets from a whole schema (LiquibaseSchema),
// from a compare's sync steps, and from any change AirSQL previews (Save as Changeset). LiquibaseChangelog reads them
// back as Liquibase does, so what AirSQL writes is checked before it is saved.

/// Settings ▸ Liquibase: who changesets are by, their ids and files, and how routines are written.
public struct LiquibaseSettings: Codable, Equatable {
    /// One changelog file, or a folder with a file per changeset and a master changelog that includes them in order.
    public enum Layout: String, Codable, CaseIterable { case oneFile, folder }
    /// How a changeset keeps a procedure, function, trigger or event whole (its body has semicolons): as its only
    /// statement (splitStatements:false), or with each statement ended by // (endDelimiter://).
    public enum Delimiter: String, Codable, CaseIterable { case splitStatements, slashes }

    /// Who the changesets are by; empty: the Mac account's name.
    public var author = ""
    /// Changeset ids: {date} (20261102), {time} (141500), {n} (001, 002…) and {object} (the table, view or routine).
    public var ids = "{date}-{n}-{object}"
    public var layout = Layout.oneFile
    /// Views, routines, triggers and events without their DEFINER, so they run as whoever runs the changelog.
    public var stripDefiner = true
    public var delimiter = Delimiter.splitStatements
    /// A --rollback for each changeset whose undoing can be written (DROP for what it creates).
    public var rollback = true
    /// The changelog Save as Changeset adds to; empty until one is chosen.
    public var changelog = ""

    public init() {}

    /// Settings saved by another version may lack keys; those keep their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LiquibaseSettings()
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? defaults.author
        ids = try container.decodeIfPresent(String.self, forKey: .ids) ?? defaults.ids
        layout = try container.decodeIfPresent(Layout.self, forKey: .layout) ?? defaults.layout
        stripDefiner = try container.decodeIfPresent(Bool.self, forKey: .stripDefiner) ?? defaults.stripDefiner
        delimiter = try container.decodeIfPresent(Delimiter.self, forKey: .delimiter) ?? defaults.delimiter
        rollback = try container.decodeIfPresent(Bool.self, forKey: .rollback) ?? defaults.rollback
        changelog = try container.decodeIfPresent(String.self, forKey: .changelog) ?? defaults.changelog
    }

    /// The author as a changeset line can hold it (no colon); the account's name when none is set.
    public var authorName: String {
        let name = author.filter { $0 != ":" && !$0.isNewline }.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? NSUserName() : name
    }
}

/// A changeset AirSQL writes: its statements, what undoes them when that can be written, and how formatted SQL keeps
/// them apart (attributes only where they are needed).
public struct LiquibaseChangeset: Equatable {
    public var author = ""
    public var id = ""
    /// The table, view, routine… it is about: the {object} of its id.
    public var object: String
    /// Without their delimiters.
    public var statements: [String]
    public var rollback: [String]
    public var comment: String?
    /// Run again when its SQL changes (views, written as CREATE OR REPLACE).
    public var runOnChange = false
    /// A count of what it would create: anything but 0 marks it as ran without running it (onFail:MARK_RAN).
    public var precondition: String?

    public init(object: String, statements: [String], rollback: [String] = [], comment: String? = nil) {
        self.object = object
        self.statements = statements.map(Liquibase.trimmed).filter { !$0.isEmpty }
        self.rollback = rollback.map(Liquibase.trimmed).filter { !$0.isEmpty }
        self.comment = comment
    }

    /// The changeset as formatted SQL, ending with a line break.
    public func text(_ delimiter: LiquibaseSettings.Delimiter = .splitStatements) -> String {
        let body = statements.map(Liquibase.guarded)
        let compound = body.contains(where: Liquibase.isCompound)
        let slashes = compound && (delimiter == .slashes || body.count > 1)
        var head = "--changeset \(author):\(id)"
        if runOnChange { head += " runOnChange:true" }
        if compound && !slashes { head += " splitStatements:false" }
        if slashes { head += " endDelimiter://" }
        if body.contains(where: Liquibase.hasComments) { head += " stripComments:false" }
        var lines = [head]
        if let comment, !comment.isEmpty { lines.append("--comment: " + Liquibase.oneLine(comment)) }
        if let precondition {
            lines += ["--preconditions onFail:MARK_RAN onError:HALT", "--precondition-sql-check expectedResult:0 " + Liquibase.oneLine(precondition)]
        }
        lines.append(slashes ? body.map { $0 + "\n//" }.joined(separator: "\n")
                     : compound ? body[0] : body.map { $0 + ";" }.joined(separator: "\n"))
        lines += rollback.map { "--rollback " + Liquibase.oneLine($0) + ";" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The text, once Liquibase is sure to read the same statements and rollback from it.
    public func checkedText(_ delimiter: LiquibaseSettings.Delimiter = .splitStatements) throws -> String {
        let text = text(delimiter)
        let read = try LiquibaseChangelog(LiquibaseChangelog.header + "\n\n" + text).changesets
        guard read.count == 1, read[0].statements == statements.map(Liquibase.guarded),
              read[0].rollbackStatements == rollback.map(Liquibase.oneLine) else {
            throw LiquibaseChangelog.Problem(line: 1, message: "Liquibase would read the changeset for \(object) differently from "
                                             + "how it runs here, so AirSQL didn't write it")
        }
        return text
    }
}

/// Writing changesets and changelogs.
public enum Liquibase {
    // MARK: Ids and files

    /// Gives each changeset the author and an id from the settings: {n} counts on from `first` (one more than the
    /// changesets a changelog has); an id already `taken` gets -2, -3….
    public static func numbered(_ changesets: [LiquibaseChangeset], settings: LiquibaseSettings, first: Int = 1,
                                taken: Set<String> = [], date: Date = Date()) -> [LiquibaseChangeset] {
        var used = taken
        let day = stamp(date, "yyyyMMdd"), time = stamp(date, "HHmmss")
        return changesets.enumerated().map { offset, changeset in
            var changeset = changeset
            changeset.author = settings.authorName
            let n = String(format: "%03d", first + offset)
            var base = settings.ids.replacingOccurrences(of: "{date}", with: day).replacingOccurrences(of: "{time}", with: time)
                .replacingOccurrences(of: "{n}", with: n).replacingOccurrences(of: "{object}", with: safe(changeset.object))
            base = String(base.map { $0.isWhitespace || $0 == "\"" ? "-" : $0 })
            if base.isEmpty { base = n }
            var id = base, suffix = 2
            while used.contains(id) {
                id = base + "-\(suffix)"
                suffix += 1
            }
            used.insert(id)
            changeset.id = id
            return changeset
        }
    }

    /// A name as part of an id or a file name: letters, digits, _ - and . kept, anything else as _.
    public static func safe(_ name: String) -> String {
        let kept = String(name.map { $0.isLetter || $0.isNumber || "_-.".contains($0) ? $0 : "_" })
        return kept.isEmpty ? "change" : kept
    }

    /// A changeset's file in a folder layout: its id.
    public static func fileName(_ changeset: LiquibaseChangeset) -> String { safe(changeset.id) + ".sql" }

    /// The master changelog of a folder layout: the changesets' files, included in order.
    public static func master(_ files: [String]) -> String {
        "databaseChangeLog:\n" + files.map { file in
            let quoted = "\"" + file.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            return "  - include:\n      file: \(quoted)\n      relativeToChangelogFile: true\n"
        }.joined()
    }

    public static let masterName = "db.changelog-master.yaml"

    /// A whole changelog: the header line, then the changesets apart by blank lines.
    public static func changelog(_ changesets: [LiquibaseChangeset], delimiter: LiquibaseSettings.Delimiter) -> String {
        ([LiquibaseChangelog.header + "\n"] + changesets.map { $0.text(delimiter) }).joined(separator: "\n")
    }

    // MARK: Sources

    /// A change AirSQL previewed and ran (Save as Changeset): one changeset titled as the change, with a rollback when
    /// every statement has one. Statements Liquibase handles itself are left out (USE, and the transaction around
    /// them: each changeset runs in a transaction of its own), and so is the database the change names its objects
    /// with, so the changeset runs in whichever database Liquibase updates.
    public static func changeset(_ change: ChangeSQL, rollback wanted: Bool = true) -> LiquibaseChangeset {
        changeset(title: change.title, statements: change.statements, rollback: wanted)
    }

    /// Statements run elsewhere (the console's) as one changeset, as `changeset(_:)` makes one of a previewed change.
    public static func changeset(title: String, statements: [String], rollback wanted: Bool = true) -> LiquibaseChangeset {
        var statements = statements.map(trimmed)
        let database = statements.lazy.compactMap(usedDatabase).first ?? statements.first.flatMap(namedDatabase)
        statements.removeAll { usedDatabase($0) != nil || ["START TRANSACTION", "BEGIN", "BEGIN WORK", "COMMIT", "ROLLBACK"]
            .contains($0.uppercased()) }
        if let database { statements = statements.map { unqualified($0, database: database) } }
        // A change that sets the session's sql_mode or time zone (the object editor's) puts them back after, as later
        // changesets run on the same session.
        if statements.contains(where: { statement in
            let tokens = Tokens(statement)
            return tokens.word(0) == "SET" && (0..<tokens.count).contains { ["SQL_MODE", "TIME_ZONE"].contains(tokens.word($0) ?? "") }
        }) {
            statements = [sessionSave] + statements + [sessionTail]
        }
        let undo = statements.reversed().map(rollback)
        // The first name in backticks: the table or routine the change is about.
        let object = statements.lazy.compactMap { statement in
            Tokens(statement).tokens.first { $0.kind == .quotedName }.map { SQLQuote.unquoted(String(decoding: Array(statement.utf16)[$0.range], as: UTF16.self)) }
        }.first
        return LiquibaseChangeset(object: object ?? title, statements: statements,
                                  rollback: wanted && !undo.contains(nil) ? undo.compactMap { $0 } : [], comment: title)
    }

    /// A compare's sync script (`ReconResult.steps`): a changeset per structure step, one per run of data steps on the
    /// same table (in UTC and with the session settings the compare read them in), destructive steps saying so.
    public static func changesets(_ result: ReconResult, destructive: Bool, rollback wanted: Bool = true) -> [LiquibaseChangeset] {
        var changesets: [LiquibaseChangeset] = []
        var data: (object: String, statements: [String], comment: String?)?
        func flushData() {
            guard let run = data else { return }
            changesets.append(LiquibaseChangeset(object: run.object, statements: sessionHead(noBackslashEscapes: result.target.noBackslashEscapes)
                                                    + run.statements + [sessionTail], comment: run.comment))
            data = nil
        }
        for step in result.steps(destructive: destructive) {
            var sql = step.sql, comment: String?
            if sql.hasPrefix("-- "), let end = sql.firstIndex(of: "\n") {
                comment = String(sql[sql.index(sql.startIndex, offsetBy: 3)..<end])
                sql = String(sql[sql.index(after: end)...])
            }
            if step.kind == .data {
                if data?.object != step.object { flushData() }
                data = (step.object, (data?.statements ?? []) + [sql], data?.comment ?? comment)
                continue
            }
            flushData()
            changesets.append(LiquibaseChangeset(object: step.object, statements: [sql],
                                                 rollback: wanted ? rollback(sql).map { [$0] } ?? [] : [], comment: comment))
        }
        flushData()
        return changesets
    }

    /// What a changeset of rows (or of a table with zero dates or TIMESTAMP defaults) runs first, as mysqldump does: in
    /// UTC (TIMESTAMP values as they were read), with NO_AUTO_VALUE_ON_ZERO (a 0 in an AUTO_INCREMENT column stays 0)
    /// and no strict mode (zero dates load), and the backslash escapes its strings were written with. `sessionTail`
    /// puts the session's own settings back.
    public static func sessionHead(noBackslashEscapes: Bool = false) -> [String] {
        [sessionSave,
         "SET SESSION sql_mode = '" + (noBackslashEscapes ? "NO_AUTO_VALUE_ON_ZERO,NO_BACKSLASH_ESCAPES" : "NO_AUTO_VALUE_ON_ZERO")
            + "', SESSION time_zone = '+00:00'"]
    }
    public static let sessionSave = "SET @airsql_sql_mode = @@SESSION.sql_mode, @airsql_time_zone = @@SESSION.time_zone"
    public static let sessionTail = "SET SESSION sql_mode = @airsql_sql_mode, SESSION time_zone = @airsql_time_zone"

    // MARK: Rollback

    /// The statement that undoes `statement`, when one can be written: DROP for CREATE TABLE, VIEW, PROCEDURE,
    /// FUNCTION, TRIGGER, EVENT, SEQUENCE and INDEX; DROP for what ALTER TABLE adds (columns, keys, foreign keys,
    /// checks); RENAME TABLE back. Nil for the rest (data, drops, CREATE OR REPLACE, which may have replaced something).
    public static func rollback(_ statement: String) -> String? {
        let tokens = Tokens(statement)
        guard let first = tokens.word(0) else { return nil }
        switch first {
        case "CREATE":
            // Past what may come before the kind: OR REPLACE (nothing to undo then), ALGORITHM=…, DEFINER=…, UNIQUE….
            var k = 1
            while k < tokens.count, !creatable.contains(tokens.word(k) ?? "") {
                if ["OR", "TEMPORARY"].contains(tokens.word(k) ?? "") { return nil }
                k += 1
            }
            guard let kind = tokens.word(k) else { return nil }
            if tokens.word(k + 1) == "IF" { return nil }
            guard let (name, next) = tokens.name(k + 1) else { return nil }
            if kind == "INDEX" {
                guard tokens.word(next) == "ON", let (table, _) = tokens.name(next + 1) else { return nil }
                return "DROP INDEX \(name) ON \(table)"
            }
            return "DROP \(kind) \(name)"
        case "ALTER":
            guard tokens.word(1) == "TABLE", let (table, start) = tokens.name(2) else { return nil }
            var undo: [String] = []
            for clause in tokens.clauses(from: start) {
                guard let inverse = tokens.inverse(clause) else { return nil }
                undo.insert(inverse, at: 0)
            }
            return undo.isEmpty ? nil : "ALTER TABLE \(table) " + undo.joined(separator: ", ")
        case "RENAME":
            guard tokens.word(1) == "TABLE" else { return nil }
            var pairs: [String] = [], k = 2
            while let (from, afterFrom) = tokens.name(k), tokens.word(afterFrom) == "TO", let (to, next) = tokens.name(afterFrom + 1) {
                pairs.insert("\(to) TO \(from)", at: 0)
                guard tokens.text(next) == "," else { return next >= tokens.count ? "RENAME TABLE " + pairs.joined(separator: ", ") : nil }
                k = next + 1
            }
            return nil
        default:
            return nil
        }
    }

    private static let creatable: Set<String> = ["TABLE", "VIEW", "PROCEDURE", "FUNCTION", "TRIGGER", "EVENT", "SEQUENCE", "INDEX"]

    /// A statement's tokens without comments, with the words and names rollback looks for.
    struct Tokens {
        let text: [UInt16]
        let tokens: [SQLToken]
        var count: Int { tokens.count }

        init(_ sql: String) {
            text = Array(sql.utf16)
            tokens = SQLLexer.tokens(sql).filter { ![.comment, .hint].contains($0.kind) }
        }

        func text(_ k: Int) -> String? {
            k < tokens.count ? String(decoding: text[tokens[k].range], as: UTF16.self) : nil
        }

        func word(_ k: Int) -> String? { k < tokens.count && tokens[k].kind == .word ? text(k)?.uppercased() : nil }

        /// A name, maybe qualified (`db`.`t`), as written; and the token after it.
        func name(_ k: Int) -> (String, Int)? {
            guard k < tokens.count, [.word, .quotedName].contains(tokens[k].kind), let first = text(k) else { return nil }
            if text(k + 1) == ".", k + 2 < tokens.count, [.word, .quotedName].contains(tokens[k + 2].kind), let second = text(k + 2) {
                return (first + "." + second, k + 3)
            }
            return (first, k + 1)
        }

        /// ALTER TABLE's clauses from token `start`: ranges of tokens apart by commas outside parentheses.
        func clauses(from start: Int) -> [Range<Int>] {
            var result: [Range<Int>] = [], depth = 0, begin = start
            for k in start..<tokens.count {
                switch text(k) {
                case "(": depth += 1
                case ")": depth -= 1
                case "," where depth == 0:
                    result.append(begin..<k)
                    begin = k + 1
                default: break
                }
            }
            if begin < tokens.count { result.append(begin..<tokens.count) }
            return result
        }

        /// What undoes an ALTER TABLE clause: ADD [COLUMN] c → DROP COLUMN c, ADD [UNIQUE|FULLTEXT|SPATIAL] KEY|INDEX k →
        /// DROP INDEX k, ADD CONSTRAINT f FOREIGN KEY → DROP FOREIGN KEY f, ADD CONSTRAINT c CHECK|UNIQUE → DROP
        /// CONSTRAINT c / DROP INDEX c.
        func inverse(_ clause: Range<Int>) -> String? {
            var k = clause.lowerBound
            guard word(k) == "ADD" else { return nil }
            k += 1
            let keyWords: Set<String> = ["INDEX", "KEY", "UNIQUE", "FULLTEXT", "SPATIAL", "PRIMARY", "FOREIGN", "CHECK", "PERIOD",
                                         "SYSTEM", "CONSTRAINT", "IF", "PARTITION", "VECTOR"]
            if word(k) == "COLUMN" { k += 1 }
            if word(k) == "CONSTRAINT" {
                guard let (name, next) = name(k + 1) else { return nil }
                switch word(next) {
                case "FOREIGN": return "DROP FOREIGN KEY \(name)"
                case "UNIQUE": return "DROP INDEX \(name)"
                case "CHECK": return "DROP CONSTRAINT \(name)"
                default: return nil
                }
            }
            if let word = word(k), ["UNIQUE", "FULLTEXT", "SPATIAL", "INDEX", "KEY"].contains(word) {
                if ["UNIQUE", "FULLTEXT", "SPATIAL"].contains(word) { k += 1 }
                if let next = self.word(k), ["INDEX", "KEY"].contains(next) { k += 1 }
                guard text(k) != "(", let (name, _) = name(k), clause.contains(k) else { return nil }
                return "DROP INDEX \(name)"
            }
            if let word = word(k), keyWords.contains(word) { return nil }
            guard text(k) != "(", let (column, _) = name(k), clause.contains(k) else { return nil }
            return "DROP COLUMN \(column)"
        }
    }

    // MARK: Text

    /// Without surrounding space and the delimiter at the end.
    static func trimmed(_ statement: String) -> String {
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") { text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        return text
    }

    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Holds a semicolon of its own (a routine's body), so splitting it on semicolons would cut it apart.
    static func isCompound(_ statement: String) -> Bool {
        let text = Array(statement.utf16)
        return SQLLexer.tokens(statement).contains { $0.kind == .symbol && $0.range.count == 1 && text[$0.range.lowerBound] == 0x3B }
    }

    /// Holds a comment Liquibase would strip: -- or /* */, executable /*! */ comments included (MySQL's own # comments
    /// Liquibase leaves).
    static func hasComments(_ statement: String) -> Bool {
        let text = Array(statement.utf16)
        return SQLLexer.tokens(statement).contains { token in
            token.kind == .codeStart || [.comment, .hint].contains(token.kind) && text[token.range.lowerBound] != 0x23
        }
    }

    /// The statement with each -- comment that Liquibase would read as one of its own lines (-- rollback …,
    /// -- changeset …) turned into a # comment, which MySQL and MariaDB read the same way.
    static func guarded(_ statement: String) -> String {
        guard statement.contains("--") else { return statement }
        let text = Array(statement.utf16)
        var result = text, removed = 0
        for token in SQLLexer.tokens(statement) where token.kind == .comment && text[token.range.lowerBound] == 0x2D {
            var start = token.range.lowerBound
            while start > 0, text[start - 1] != 0x0A { start -= 1 }
            var end = token.range.upperBound
            while end < text.count, text[end] != 0x0A { end += 1 }
            let line = String(decoding: text[start..<end], as: UTF16.self)
            guard LiquibaseChangelog.isInstruction(line) else { continue }
            let at = token.range.lowerBound - removed
            result.replaceSubrange(at..<at + 2, with: [0x23])
            removed += 1
        }
        return String(decoding: result, as: UTF16.self)
    }

    /// The database of a `USE db` statement.
    static func usedDatabase(_ statement: String) -> String? {
        let tokens = Tokens(statement)
        guard tokens.count == 2, tokens.word(0) == "USE", let (name, _) = tokens.name(1) else { return nil }
        return SQLQuote.unquoted(name)
    }

    /// The database a statement's first object is named with, `db` of CREATE TABLE `db`.`t`, ALTER TABLE `db`.`t`,
    /// DROP VIEW `db`.`v`, INSERT INTO `db`.`t`, UPDATE `db`.`t`….
    static func namedDatabase(_ statement: String) -> String? {
        let tokens = Tokens(statement)
        for k in 0..<min(tokens.count, 8) where tokens.tokens[k].kind == .quotedName {
            guard tokens.text(k + 1) == ".", let name = tokens.text(k) else { return nil }
            return SQLQuote.unquoted(name)
        }
        return nil
    }

    /// `statement` with `database`'s qualifier left out of the names it qualifies (`db`.`t` → `t`).
    static func unqualified(_ statement: String, database: String) -> String {
        let quoted = SQLQuote.identifier(database)
        guard statement.contains(quoted + ".") else { return statement }
        let text = Array(statement.utf16), tokens = SQLLexer.tokens(statement)
        var result = text, removed = 0
        for (k, token) in tokens.enumerated() where token.kind == .quotedName && k + 1 < tokens.count
            && String(decoding: text[token.range], as: UTF16.self) == quoted && tokens[k + 1].range.count == 1
            && text[tokens[k + 1].range.lowerBound] == 0x2E {
            let start = token.range.lowerBound - removed, end = tokens[k + 1].range.upperBound - removed
            result.removeSubrange(start..<end)
            removed += end - start
        }
        return String(decoding: result, as: UTF16.self)
    }

    static func stamp(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
