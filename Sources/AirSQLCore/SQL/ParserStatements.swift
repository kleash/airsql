import Foundation
extension SQLParser {
    /// Reads the one statement in `tokens`.
    mutating func statement() -> SQLParsedStatement {
        var result = SQLParsedStatement(kind: .other, verb: current.upper == "(" ? "SELECT" : current.upper, range: 0..<0, end: 0)
        switch current.upper {
        case "SELECT", "(", "VALUES", "TABLE":
            result.kind = .select
            result.query = query()
        case "WITH":
            withStatement(&result)
        case "INSERT", "REPLACE":
            insert(&result)
        case "UPDATE":
            update(&result)
        case "DELETE":
            delete(&result)
        case "CREATE":
            create(&result)
        case "ALTER":
            alter(&result)
        case "DROP":
            drop(&result)
        case "TRUNCATE":
            result.kind = .truncate
            index += 1
            accept("TABLE")
            if let name = dottedName("a table name") { result.objects = [SQLObjectRef(kind: "TABLE", name: name)] }
        case "RENAME":
            rename(&result)
        case "USE":
            result.kind = .use
            index += 1
            if let name = nameIdentifier("a database name") { result.objects = [SQLObjectRef(kind: "DATABASE", name: SQLName(parts: [name]))] }
        case "SET":
            set(&result)
        case "CALL":
            call(&result)
        case "EXPLAIN", "DESCRIBE", "DESC", "ANALYZE":
            explain(&result)
        default:
            result.shallow = true
        }
        if !result.shallow, !atEnd, !at(";") {
            if at(")") { fail("Unmatched )") } else { fail("Unexpected \(current.text)") }
        }
        return result
    }

    private mutating func withStatement(_ result: inout SQLParsedStatement) {
        let start = index
        let (ctes, _) = withClause()
        if at("UPDATE") {
            result.ctes = ctes
            update(&result)
        } else if at("DELETE") {
            result.ctes = ctes
            delete(&result)
        } else {
            index = start
            errors = []
            result.kind = .select
            result.query = query()
        }
    }

    // MARK: Writes

    /// `table [PARTITION …] [[AS] alias]`.
    private mutating func namedTable() -> SQLTableRef? {
        let start = current.range.lowerBound
        guard let name = dottedName("a table name") else { return nil }
        var ref = SQLTableRef(kind: .table, range: name.range, name: name)
        afterTableName(&ref)
        ref.range = start..<lastEnd
        return ref
    }

    private mutating func insert(_ result: inout SQLParsedStatement) {
        result.kind = current.upper == "INSERT" ? .insert : .replace
        index += 1
        var write = SQLWrite()
        while at(["LOW_PRIORITY", "DELAYED", "HIGH_PRIORITY", "IGNORE"]) { index += 1 }
        accept("INTO")
        guard let name = dottedName("a table name") else {
            result.write = write
            return
        }
        var table = SQLTableRef(kind: .table, range: name.range, name: name)
        if at("PARTITION"), peek().upper == "(" {
            index += 1
            skipBrackets()
        }
        table.range = name.range.lowerBound..<lastEnd
        write.tables = [table]
        if at("("), !looksLikeQuery(index + 1) {
            let start = current.range.lowerBound
            write.clauses.append((.insertColumns, current.range.upperBound))
            if peek().upper == ")" { index += 2 } else { write.columns = columnNames() }
            write.columnsRange = start..<lastEnd
        }
        if at("VALUES") || at("VALUE"), peek().upper == "(" || peek().upper == "ROW" {
            write.clauses.append((.values, current.range.upperBound))
            index += 1
            repeat {
                let start = current.range.lowerBound
                accept("ROW")
                guard accept("(") else {
                    fail("Expected a row in brackets\(foundText)")
                    break
                }
                var values: [SQLExpr] = []
                if !at(")") {
                    repeat { values.append(expression()) } while accept(",")
                }
                if !expect(")") { skip(to: []); accept(")") }
                write.rows.append(SQLInsertRow(range: start..<lastEnd, values: values))
            } while accept(",")
            if accept("AS") {
                write.rowAlias = nameIdentifier("an alias")
                if at("(") { write.rowAliasColumns = nameList("a column name") }
            }
        } else if at("SET") {
            write.clauses.append((.set, current.range.upperBound))
            index += 1
            write.assignments = assignments()
        } else if at("SELECT") || at("WITH") || at("(") || at("TABLE") {
            result.query = query()
        } else if at("VALUES") {
            fail("Expected a row in brackets after VALUES")
            index += 1
        } else {
            fail("Expected VALUES, SET or SELECT\(foundText)")
        }
        if accept("ON", "DUPLICATE", "KEY", "UPDATE") {
            write.clauses.append((.set, lastEnd))
            write.onDuplicate = assignments()
        }
        returning(&write)
        result.write = write
    }

    /// An INSERT's column list, which may qualify a name: (a, t.b).
    private mutating func columnNames() -> [SQLIdentifier] {
        var names: [SQLIdentifier] = []
        index += 1
        repeat {
            guard let name = dottedName("a column name") else { break }
            names.append(name.last)
        } while accept(",")
        if !expect(")") { skip(to: []); accept(")") }
        return names
    }

    private mutating func assignments() -> [SQLAssignment] {
        var list: [SQLAssignment] = []
        repeat {
            guard let column = dottedName("a column name") else { break }
            guard accept("=") || accept(":=") else {
                fail("Expected = after the column’s name\(foundText)")
                break
            }
            list.append(SQLAssignment(column: column, value: expression()))
        } while accept(",")
        return list
    }

    private mutating func returning(_ write: inout SQLWrite) {
        guard at("RETURNING") else { return }
        write.clauses.append((.returning, current.range.upperBound))
        index += 1
        repeat { write.returning.append(selectItem()) } while accept(",")
    }

    private mutating func update(_ result: inout SQLParsedStatement) {
        result.kind = .update
        result.verb = "UPDATE"
        index += 1
        var write = SQLWrite()
        while at(["LOW_PRIORITY", "IGNORE"]) { index += 1 }
        write.clauses.append((.from, lastEnd))
        tables(&write)
        if at("SET") {
            write.clauses.append((.set, current.range.upperBound))
            index += 1
            write.assignments = assignments()
        } else {
            fail("Expected SET\(foundText)")
            skip(to: Self.clauseWords.subtracting(["ON"]))
        }
        tail(&write)
        result.write = write
    }

    private mutating func delete(_ result: inout SQLParsedStatement) {
        result.kind = .delete
        result.verb = "DELETE"
        index += 1
        var write = SQLWrite()
        while at(["LOW_PRIORITY", "QUICK", "IGNORE"]) { index += 1 }
        func starless(_ parser: inout SQLParser) -> [SQLName] {
            var names: [SQLName] = []
            repeat {
                guard let name = parser.dottedName("a table name") else { break }
                names.append(name)
                if parser.at("."), parser.peek().upper == "*" { parser.index += 2 }
            } while parser.accept(",")
            return names
        }
        if at("FROM") {
            index += 1
            write.clauses.append((.from, lastEnd))
            if isUsingForm() {
                write.deleteTargets = starless(&self)
                expect("USING")
            }
            tables(&write)
        } else {
            write.deleteTargets = starless(&self)
            if expect("FROM", "Expected FROM\(foundText)") {
                write.clauses.append((.from, lastEnd))
                tables(&write)
            }
        }
        tail(&write)
        result.write = write
    }

    private mutating func tables(_ write: inout SQLWrite) {
        let start = current.range.lowerBound
        write.tables = tableList(&write.clauses)
        write.tablesRange = start..<max(start, lastEnd)
    }

    /// DELETE FROM a, b USING …: a USING at this level before any WHERE.
    private func isUsingForm() -> Bool {
        var i = index, level = 0
        while i < tokens.count {
            switch tokens[i].upper {
            case "(": level += 1
            case ")": level -= 1
            case "USING" where level == 0:
                // JOIN b USING (x) is a join's; DELETE's own USING comes before a table.
                return tokens[i + 1 < tokens.count ? i + 1 : i].upper != "("
            case "WHERE", "ORDER", "LIMIT", "RETURNING": if level == 0 { return false }
            default: break
            }
            i += 1
        }
        return false
    }

    /// WHERE, ORDER BY, LIMIT and RETURNING of an UPDATE or DELETE.
    private mutating func tail(_ write: inout SQLWrite) {
        if at("WHERE") {
            write.clauses.append((.whereClause, current.range.upperBound))
            index += 1
            write.whereClause = expression()
        }
        if at("ORDER"), peek().upper == "BY" {
            index += 2
            write.clauses.append((.orderBy, lastEnd))
            write.orderBy = order()
        }
        if at("LIMIT") {
            write.clauses.append((.limit, current.range.upperBound))
            index += 1
            write.limit = limit()
        }
        returning(&write)
    }

    // MARK: Definitions

    private static let objectWords: Set<String> = ["TABLE", "VIEW", "INDEX", "DATABASE", "SCHEMA", "FUNCTION", "PROCEDURE", "TRIGGER", "EVENT",
                                                   "SEQUENCE", "USER", "ROLE", "SERVER", "TABLESPACE", "LOGFILE", "PACKAGE"]

    /// `IF [NOT] EXISTS`, if here.
    private mutating func ifExists() {
        if !accept("IF", "NOT", "EXISTS") { accept("IF", "EXISTS") }
    }

    private mutating func create(_ result: inout SQLParsedStatement) {
        result.kind = .create
        index += 1
        // OR REPLACE, TEMPORARY, ALGORITHM = …, DEFINER = a@b, SQL SECURITY …, UNIQUE, AGGREGATE: all before the object.
        while !atEnd, !at(Self.objectWords), !at("(") { index += 1 }
        guard at(Self.objectWords) else {
            result.shallow = true
            return
        }
        let kind = current.upper == "SCHEMA" ? "DATABASE" : current.upper
        index += 1
        ifExists()
        guard let name = dottedName(kind == "TABLE" ? "a table name" : "a name") else { return }
        result.objects = [SQLObjectRef(kind: kind, name: name)]
        switch kind {
        case "TABLE": createTable(&result)
        case "VIEW": createView(&result)
        case "INDEX": createIndex(&result)
        case "FUNCTION", "PROCEDURE": routineHeader(&result)
        default: result.shallow = true
        }
        if kind == "TABLE" || kind == "INDEX" || kind == "VIEW" { index = result.shallow ? tokens.count : index }
    }

    private static let constraintStarts: Set<String> = ["PRIMARY", "UNIQUE", "KEY", "INDEX", "FULLTEXT", "SPATIAL", "FOREIGN", "CONSTRAINT",
                                                        "CHECK", "PERIOD", "VECTOR"]
    private static let columnWords: Set<String> = [
        "NOT", "NULL", "DEFAULT", "AUTO_INCREMENT", "PRIMARY", "KEY", "UNIQUE", "COMMENT", "COLLATE", "ON", "GENERATED", "AS", "CHECK",
        "REFERENCES", "INVISIBLE", "VISIBLE", "COLUMN_FORMAT", "STORAGE", "CONSTRAINT", "SERIAL", "WITHOUT", "WITH", "ENGINE_ATTRIBUTE",
    ]

    /// `(columns and keys)`, then options (not read), or AS SELECT, or LIKE.
    private mutating func createTable(_ result: inout SQLParsedStatement) {
        if at("LIKE") || (at("(") && peek().upper == "LIKE") {
            let bracket = accept("(")
            index += 1
            if let name = dottedName("a table name") { result.objects.append(SQLObjectRef(kind: "TABLE", name: name)) }
            if bracket { accept(")") }
            return
        }
        if at("("), !looksLikeQuery(index + 1) {
            index += 1
            repeat {
                if at(")") { break }  // a trailing comma is for the server to say: this reads no further here
                if at(Self.constraintStarts) {
                    skip(to: [","])
                } else if let column = columnDefinition() {
                    result.columns.append(column)
                } else {
                    skip(to: [","])
                }
            } while accept(",")
            if !expect(")") { skip(to: []); accept(")") }
        }
        // Table options and partitions aren't read; a query after them is.
        while !atEnd, !at("SELECT"), !at("WITH") {
            if at("(") {
                if looksLikeQuery(index + 1) { break }
                skipBrackets()
            } else {
                index += 1
            }
        }
        if !atEnd { result.query = query() }
    }

    private mutating func columnDefinition() -> SQLColumnDefinition? {
        let start = current.range.lowerBound
        guard let name = nameIdentifier("a column name") else { return nil }
        var column = SQLColumnDefinition(name: name, type: "", range: start..<start)
        var type: [String] = [], inType = true
        while !atEnd, !at(","), !at(")") {
            if at(Self.columnWords) { inType = false }
            if at("AUTO_INCREMENT") { column.autoIncrement = true }
            if at("(") {
                let open = index
                skipBrackets()
                if inType { type.append(tokens[open..<index].map(\.text).joined()) }
            } else {
                if inType { type.append(current.upper) }
                index += 1
            }
        }
        column.type = type.joined(separator: " ").replacingOccurrences(of: " (", with: "(")
        column.range = start..<lastEnd
        return column
    }

    /// `[(columns)] AS query`, then WITH CHECK OPTION.
    private mutating func createView(_ result: inout SQLParsedStatement) {
        if at("(") { _ = nameList("a column name") }
        guard expect("AS", "Expected AS after the view’s name\(foundText)") else { return }
        result.query = query()
        if accept("WITH") { index = tokens.count }
    }

    /// `[USING …] ON table (…)`, then options, not read.
    private mutating func createIndex(_ result: inout SQLParsedStatement) {
        while !atEnd, !at("ON") { index += 1 }
        guard accept("ON") else {
            fail("Expected ON and a table")
            return
        }
        if let name = dottedName("a table name") { result.objects.append(SQLObjectRef(kind: "TABLE", name: name)) }
        index = tokens.count
    }

    /// `(parameters)`, its characteristics, and where the body starts. The body isn't read.
    private mutating func routineHeader(_ result: inout SQLParsedStatement) {
        result.shallow = true
        guard at("(") else { return }
        let close = bracketEnd()
        index += 1
        while index < close {
            if at(["IN", "OUT", "INOUT"]) { index += 1 }
            if isName(current) { result.parameters.append(identifier(current)) }
            skip(to: [","])
            if !accept(",") { break }
        }
        index = close
        result.bodyStart = tokens.first { $0.upper == "BEGIN" && $0.range.lowerBound >= current.range.lowerBound }?.range.lowerBound
        index = tokens.count
    }

    /// The index just past the ")" of the "(" at `index`, without moving.
    private func bracketEnd() -> Int {
        var copy = self
        copy.skipBrackets()
        return copy.index
    }

    private mutating func alter(_ result: inout SQLParsedStatement) {
        result.kind = .alter
        result.shallow = true
        index += 1
        while !atEnd, !at(Self.objectWords) { index += 1 }
        guard at(Self.objectWords) else { return }
        let kind = current.upper == "SCHEMA" ? "DATABASE" : current.upper
        index += 1
        ifExists()
        if isName(current), let name = dottedName("a name") { result.objects = [SQLObjectRef(kind: kind, name: name)] }
    }

    private mutating func drop(_ result: inout SQLParsedStatement) {
        result.kind = .drop
        index += 1
        while !atEnd, !at(Self.objectWords) { index += 1 }
        guard at(Self.objectWords) else {
            result.shallow = true
            return
        }
        let kind = current.upper == "SCHEMA" ? "DATABASE" : current.upper
        index += 1
        ifExists()
        repeat {
            guard let name = dottedName("a name") else { return }
            result.objects.append(SQLObjectRef(kind: kind, name: name))
        } while accept(",")
        if kind == "INDEX", accept("ON"), let table = dottedName("a table name") { result.objects.append(SQLObjectRef(kind: "TABLE", name: table)) }
        index = tokens.count  // RESTRICT, CASCADE, WAIT, ALGORITHM: nothing that names anything
    }

    private mutating func rename(_ result: inout SQLParsedStatement) {
        result.kind = .rename
        index += 1
        guard accept("TABLE") || accept("TABLES") else {
            result.shallow = true
            return
        }
        repeat {
            guard let old = dottedName("a table name") else { return }
            result.objects.append(SQLObjectRef(kind: "TABLE", name: old))
            if at("WAIT") || at("NOWAIT") { skip(to: ["TO"]) }
            guard expect("TO", "Expected TO after the table’s name\(foundText)"), let new = dottedName("a table name") else { return }
            result.objects.append(SQLObjectRef(kind: "TABLE", name: new))
        } while accept(",")
    }

    // MARK: The rest

    /// `SET @a = 1, @b := 2`; any other SET (system variables take words like ON as values) isn't read.
    private mutating func set(_ result: inout SQLParsedStatement) {
        result.kind = .set
        index += 1
        guard current.kind == .variable, !current.text.hasPrefix("@@") else {
            result.shallow = true
            return
        }
        repeat {
            guard current.kind == .variable, !current.text.hasPrefix("@@") else {
                result.shallow = true
                return
            }
            index += 1
            guard accept("=") || accept(":=") else {
                fail("Expected = after the variable\(foundText)")
                return
            }
            result.arguments.append(expression())
        } while accept(",")
    }

    private mutating func call(_ result: inout SQLParsedStatement) {
        result.kind = .call
        index += 1
        guard let name = dottedName("a routine name") else { return }
        result.objects = [SQLObjectRef(kind: "PROCEDURE", name: name)]
        guard accept("("), !accept(")") else { return }
        repeat { result.arguments.append(expression()) } while accept(",")
        if !expect(")") { skip(to: []); accept(")") }
    }

    /// EXPLAIN, DESCRIBE and MariaDB's ANALYZE of a statement, which comes back with this kind and that one's parts;
    /// or DESCRIBE of a table.
    private mutating func explain(_ result: inout SQLParsedStatement) {
        let verb = current.upper
        index += 1
        if verb == "ANALYZE", at(["TABLE", "NO_WRITE_TO_BINLOG", "LOCAL"]) {
            result.shallow = true
            return
        }
        if accept("FOR", "CONNECTION") {
            result.shallow = true
            return
        }
        while at(["EXTENDED", "PARTITIONS", "ANALYZE", "FORMAT"]) {
            index += 1
            if accept("=") {
                index += 1
            }
        }
        result.kind = .explain
        if at(["SELECT", "(", "WITH", "VALUES", "TABLE", "INSERT", "REPLACE", "UPDATE", "DELETE"]) {
            var inner = statement()
            inner.kind = .explain
            inner.verb = verb
            inner.range = result.range
            result = inner
        } else if let name = dottedName("a table or statement") {
            result.objects = [SQLObjectRef(kind: "TABLE", name: name)]
            result.shallow = true  // a column or pattern may follow
            index = tokens.count
        }
    }
}
