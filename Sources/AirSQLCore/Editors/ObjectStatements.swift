import Foundation

/// The statements that put an object editor's code in place, its DEFINER, and the code a new object starts from.
public enum ObjectCode {
    /// The code with its DEFINER clause set to `account` (as SQL, such as `root`@`localhost`), or removed (nil: the
    /// object is then created as whoever runs it). Code without a CREATE header is returned unchanged.
    public static func settingDefiner(_ code: String, to account: String?) -> String {
        guard let header = CreateHeader(code) else { return code }
        var code = code
        if let range = header.definer {
            if let account {
                code.replaceSubrange(range, with: "DEFINER=" + account)
            } else {
                // The clause and the space after it.
                let end = code[range.upperBound...].first == " " ? code.index(after: range.upperBound) : range.upperBound
                code.removeSubrange(range.lowerBound..<end)
            }
        } else if let account {
            code.insert(contentsOf: " DEFINER=" + account, at: header.definerSlot)
        }
        return code
    }

    /// `user`@`host` for an account as CURRENT_USER() gives it (user@host; the host after the last @).
    public static func quotedAccount(_ account: String) -> String {
        if account.uppercased() == "CURRENT_USER" { return "CURRENT_USER" }
        guard let at = account.lastIndex(of: "@") else { return SQLQuote.identifier(account) }
        return SQLQuote.identifier(String(account[..<at])) + "@" + SQLQuote.identifier(String(account[account.index(after: at)...]))
    }

    /// What runs to put `code` in place of the object named `original` in `database` (nil: a new object): USE the
    /// database (the code names the object without it), the object's own sql_mode and time zone, then the code. A
    /// view, and on MariaDB every kind, is replaced in one statement (CREATE OR REPLACE); MySQL can't replace a
    /// routine, trigger or event, so it is dropped first. Code that renames the object drops the old one after.
    public static func statements(_ code: String, kind: ObjectKind, database: String, original: String?,
                                  definition: ObjectDefinition?, server: SchemaServer) throws -> [String] {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let header = CreateHeader(code) else {
            throw DesignError("The code must start with CREATE \(kind.keyword) and the \(kind.rawValue)'s name")
        }
        guard header.kind == kind else {
            throw DesignError("This editor holds a \(kind.rawValue): the code must create one, not a \(header.kind.rawValue)")
        }
        if let named = header.database, !same(named, database, kind: kind, server: server) {
            throw DesignError("The code creates the \(kind.rawValue) in \(named), not in \(database): leave the database out")
        }
        let text = { (value: String) in SQLQuote.string(value, noBackslashEscapes: server.noBackslashEscapes) }
        var statements = ["USE " + SQLQuote.identifier(database)]
        if let mode = definition?.sqlMode { statements.append("SET SESSION sql_mode = " + text(mode)) }
        if let zone = definition?.timeZone { statements.append("SET SESSION time_zone = " + text(zone)) }
        guard let original else { return statements + [code] }
        let renamed = !same(header.name, original, kind: kind, server: server)
        let drop = "DROP " + kind.keyword + " IF EXISTS " + SQLQuote.identifier(database, original)
        if kind == .view || server.flavour == .mariadb {
            statements.append(header.orReplace ? code : orReplace(code, header))
            if renamed { statements.append(drop) }
        } else {
            statements += [drop, code]
        }
        return statements
    }

    /// Where a server's error about the object's CREATE points in `code` (`ConsoleScript.problem`): the whole text is one
    /// statement, however many ; a routine's body holds, and the OR REPLACE Apply may add leaves its lines as they are.
    public static func problem(_ message: String, shown: String, in code: String, noBackslashEscapes: Bool) -> SQLProblem? {
        let sql = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed = code.range(of: sql) else { return nil }
        let start = code[..<trimmed.lowerBound].utf16.count
        let statement = SQLStatement(range: start..<(start + sql.utf16.count), end: start + sql.utf16.count, sql: sql)
        return ConsoleScript.problem(message, shown: shown, statement: statement, noBackslashEscapes: noBackslashEscapes)
    }

    /// Whether replacing this kind of object on this server first drops it, so that failing code leaves nothing.
    public static func dropsFirst(_ kind: ObjectKind, server: SchemaServer) -> Bool {
        kind != .view && server.flavour == .mysql
    }

    /// The code with OR REPLACE after CREATE.
    static func orReplace(_ code: String, _ header: CreateHeader) -> String {
        var code = code
        code.insert(contentsOf: " OR REPLACE", at: header.afterCreate)
        return code
    }

    /// Two names of this kind are the same object: routine and event names have no case; views and triggers follow
    /// lower_case_table_names.
    static func same(_ a: String, _ b: String, kind: ObjectKind, server: SchemaServer) -> Bool {
        let caseless = kind == .procedure || kind == .function || kind == .event || server.lowerCaseTableNames != 0
        return caseless ? a.caseInsensitiveCompare(b) == .orderedSame : a == b
    }

    /// The code a new object starts from: a small working example (an event starts disabled).
    public static func template(_ kind: ObjectKind, name: String, table: String? = nil) -> String {
        let name = SQLQuote.identifier(name)
        switch kind {
        case .view:
            return "CREATE VIEW \(name) AS\nSELECT 1 AS answer"
        case .procedure:
            return "CREATE PROCEDURE \(name)(IN p_id INT)\nBEGIN\n  SELECT p_id;\nEND"
        case .function:
            return "CREATE FUNCTION \(name)(p_value INT) RETURNS INT\nDETERMINISTIC\nRETURN p_value * 2"
        case .trigger:
            return "CREATE TRIGGER \(name) BEFORE INSERT ON \(SQLQuote.identifier(table ?? "table_name")) FOR EACH ROW\nBEGIN\nEND"
        case .event:
            return "CREATE EVENT \(name) ON SCHEDULE EVERY 1 DAY DISABLE\nDO\nBEGIN\nEND"
        }
    }
}
