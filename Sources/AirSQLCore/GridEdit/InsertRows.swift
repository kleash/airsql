import Foundation

/// INSERT statements read back into rows, for Edit as Table (grid-spec §5): the table they write to, the columns they
/// name, and each row's values as pending values: a string or a number as its text, NULL, DEFAULT, and any other
/// expression as SQL sent as it is (NOW(), a sum).
public struct InsertRows: Equatable {
    public var database: String?
    public var table: String
    /// The columns named; empty: every column, in the table's order.
    public var columns: [String]
    public var rows: [[PendingChanges.Value]]

    /// The INSERT … VALUES statements in `sql`, which must all write to the same table and name the same columns.
    public static func parse(_ sql: String, noBackslashEscapes: Bool) throws -> InsertRows {
        var found: InsertRows?
        for statement in SQLSplitter.statements(in: sql, noBackslashEscapes: noBackslashEscapes) {
            let next = try parseOne(statement.sql, noBackslashEscapes: noBackslashEscapes)
            guard var all = found else {
                found = next
                continue
            }
            guard all.database == next.database, all.table == next.table, all.columns == next.columns else {
                throw EditError("The statements write to different tables or columns: select INSERTs of one table, naming the same columns")
            }
            all.rows += next.rows
            found = all
        }
        guard let found else { throw EditError("Select one or more INSERT statements first") }
        return found
    }

    private static func parseOne(_ sql: String, noBackslashEscapes: Bool) throws -> InsertRows {
        let units = Array(sql.utf16)
        // A versioned comment's code (/*! … */) is code: only its markers go.
        let tokens = SQLLexer.tokens(sql, noBackslashEscapes: noBackslashEscapes)
            .filter { ![.comment, .hint, .codeStart, .codeEnd].contains($0.kind) }
        func text(_ token: SQLToken) -> String { String(decoding: units[token.range], as: UTF16.self) }
        func word(_ index: Int) -> String? { index < tokens.count && tokens[index].kind == .word ? text(tokens[index]).uppercased() : nil }
        func symbol(_ index: Int) -> String? { index < tokens.count && tokens[index].kind == .symbol ? text(tokens[index]) : nil }
        func name(_ index: Int) -> String? {
            guard index < tokens.count else { return nil }
            switch tokens[index].kind {
            case .quotedName: return SQLQuote.unquoted(text(tokens[index]))
            case .word: return text(tokens[index])
            default: return nil
            }
        }
        let refusal = EditError("Edit as Table takes INSERT … VALUES statements, such as INSERT INTO t (a, b) VALUES (1, 'x')")
        guard word(0) == "INSERT" else { throw refusal }
        var index = 1
        while let modifier = word(index), ["LOW_PRIORITY", "DELAYED", "HIGH_PRIORITY", "IGNORE", "INTO"].contains(modifier) { index += 1 }
        guard var table = name(index) else { throw refusal }
        var database: String?
        index += 1
        if symbol(index) == ".", let second = name(index + 1) {
            (database, table) = (table, second)
            index += 2
        }
        var columns: [String] = []
        if symbol(index) == "(" {
            index += 1
            while let column = name(index) {
                columns.append(column)
                index += 1
                if symbol(index) == "," { index += 1 } else { break }
            }
            guard symbol(index) == ")" else { throw refusal }
            index += 1
        }
        guard word(index) == "VALUES" || word(index) == "VALUE" else { throw refusal }
        index += 1
        var rows: [[PendingChanges.Value]] = []
        while symbol(index) == "(" {
            index += 1
            var row: [PendingChanges.Value] = [], start = index, depth = 0
            while index < tokens.count {
                let mark = symbol(index)
                if mark == "(" { depth += 1 }
                if mark == ")", depth > 0 { depth -= 1 } else if depth == 0, mark == "," || mark == ")" {
                    guard index > start else { throw refusal }
                    row.append(value(Array(tokens[start..<index]), in: units, noBackslashEscapes: noBackslashEscapes))
                    if mark == ")" { break }
                    start = index + 1
                }
                index += 1
            }
            guard symbol(index) == ")" else { throw refusal }
            guard columns.isEmpty || row.count == columns.count else {
                throw EditError("A row has \(row.count) values for \(columns.count) columns")
            }
            rows.append(row)
            index += 1
            if symbol(index) == "," { index += 1 } else { break }
        }
        if symbol(index) == ";" { index += 1 }
        // ON DUPLICATE KEY UPDATE, RETURNING and the like don't fit a grid of new rows.
        guard index == tokens.count, !rows.isEmpty else { throw refusal }
        return InsertRows(database: database, table: table, columns: columns, rows: rows)
    }

    /// One value's tokens as a pending value.
    private static func value(_ tokens: [SQLToken], in units: [UInt16], noBackslashEscapes: Bool) -> PendingChanges.Value {
        func text(_ token: SQLToken) -> String { String(decoding: units[token.range], as: UTF16.self) }
        let whole = String(decoding: units[tokens[0].range.lowerBound..<tokens[tokens.count - 1].range.upperBound], as: UTF16.self)
        var parts = tokens
        // A character set introducer (_utf8mb4'…') says how the bytes read: the text is the same.
        if parts.count == 2, parts[0].kind == .word, text(parts[0]).hasPrefix("_"), parts[1].kind == .string { parts.removeFirst() }
        if parts.count == 2, parts[0].kind == .symbol, text(parts[0]) == "-", parts[1].kind == .number,
           case .text(let number) = value([parts[1]], in: units, noBackslashEscapes: noBackslashEscapes), !number.hasPrefix("0x") {
            return .text("-" + number)
        }
        guard parts.count == 1 else { return .sql(whole) }
        let raw = text(parts[0])
        switch parts[0].kind {
        case .string:
            guard let first = raw.first, first == "'" || first == "\"" else { return .sql(whole) }  // N'…': as SQL
            return .text(unescaped(raw, quote: first, noBackslashEscapes: noBackslashEscapes))
        case .number:
            let lower = raw.lowercased()
            if lower.hasPrefix("x'") { return .text("0x" + raw.dropFirst(2).dropLast().uppercased()) }
            if lower.hasPrefix("0x") { return .text("0x" + raw.dropFirst(2).uppercased()) }
            if lower.hasPrefix("b'") { return .text(String(raw.dropFirst(2).dropLast())) }
            if lower.hasPrefix("0b") { return .text(String(raw.dropFirst(2))) }
            return .text(raw)
        case .word:
            switch raw.uppercased() {
            case "NULL": return .null
            case "DEFAULT": return .default
            case "TRUE": return .text("1")
            case "FALSE": return .text("0")
            default: return .sql(whole)
            }
        default: return .sql(whole)
        }
    }

    /// A string literal's text: the quote written twice, and backslash escapes unless NO_BACKSLASH_ESCAPES (\% and \_
    /// keep their backslash, as the server keeps it).
    static func unescaped(_ literal: String, quote: Character, noBackslashEscapes: Bool) -> String {
        var result = "", characters = literal.dropFirst().dropLast().makeIterator()
        while let character = characters.next() {
            if character == quote {
                _ = characters.next()  // the second of a doubled quote
                result.append(quote)
            } else if character == "\\", !noBackslashEscapes, let escaped = characters.next() {
                switch escaped {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "0": result.append("\0")
                case "b": result.append("\u{8}")
                case "Z": result.append("\u{1A}")
                case "%", "_": result += "\\" + String(escaped)
                default: result.append(escaped)
                }
            } else {
                result.append(character)
            }
        }
        return result
    }
}
