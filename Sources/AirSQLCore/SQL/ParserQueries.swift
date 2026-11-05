extension SQLParser {
    /// Not reserved everywhere, but after a table or a select item these go on with the statement.
    private static let aliasStops: Set<String> = ["WINDOW", "EXCEPT", "INTERSECT", "MINUS", "RETURNING", "OFFSET", "LATERAL", "CONNECT"]
    private static let selectModifiers: Set<String> = [
        "ALL", "DISTINCT", "DISTINCTROW", "HIGH_PRIORITY", "STRAIGHT_JOIN", "SQL_SMALL_RESULT", "SQL_BIG_RESULT", "SQL_BUFFER_RESULT",
        "SQL_NO_CACHE", "SQL_CACHE", "SQL_CALC_FOUND_ROWS",
    ]
    /// Clauses of a SELECT in the order the grammar has them.
    private static let clauseOrder: [String: Int] = ["FROM": 1, "WHERE": 2, "GROUP": 3, "HAVING": 4, "WINDOW": 5, "ORDER": 6, "LIMIT": 7,
                                                     "OFFSET": 7, "FETCH": 7, "PROCEDURE": 8, "FOR": 9, "LOCK": 9]
    /// Where reading goes on after an error in a clause.
    static let clauseWords = Set(clauseOrder.keys).union(["INTO", "UNION", "EXCEPT", "INTERSECT", "MINUS", "SET", "RETURNING", "ON"])
    private static let setOperators: Set<String> = ["UNION", "EXCEPT", "INTERSECT", "MINUS"]

    /// A query, from WITH, SELECT, VALUES, TABLE or a "(" at `index`.
    mutating func query() -> SQLQuery {
        deeper(SQLQuery(range: current.range)) { $0.queryBody() }
    }

    private mutating func queryBody() -> SQLQuery {
        let start = current.range.lowerBound
        let result = SQLQuery(range: start..<start)
        if at("WITH") { (result.ctes, result.recursive) = withClause() }
        while true {
            result.blocks.append(block())
            guard at(Self.setOperators) else { break }
            var word = current.upper
            index += 1
            if at("ALL") || at("DISTINCT") {
                word += " " + current.upper
                index += 1
            }
            result.setOperators.append(word)
        }
        if result.blocks.count > 1 {
            // A last block's ORDER BY and LIMIT order the whole union.
            let last = result.blocks.count - 1
            swap(&result.orderBy, &result.blocks[last].orderBy)
            swap(&result.limit, &result.blocks[last].limit)
        }
        result.range = start..<max(start, lastEnd)
        result.extent = result.range
        return result
    }

    /// WITH [RECURSIVE] name [(columns)] AS (query), …
    mutating func withClause() -> ([SQLCTE], Bool) {
        index += 1
        let recursive = accept("RECURSIVE")
        var ctes: [SQLCTE] = []
        repeat {
            let start = current.range.lowerBound
            guard let name = nameIdentifier("a name for the WITH query") else { break }
            let columns = at("(") ? nameList("a column name") : []
            guard expect("AS", "Expected AS after the WITH query’s name\(foundText)"), expect("(") else { break }
            let inner = query()
            closeQuery(inner)
            ctes.append(SQLCTE(name: name, columns: columns, query: inner, range: start..<lastEnd))
            if at("CYCLE") { skip(to: [","]) }  // MariaDB's CYCLE a RESTRICT
        } while accept(",")
        return (ctes, recursive)
    }

    private mutating func block() -> SQLSelect {
        let start = current.range.lowerBound
        var select = SQLSelect(range: start..<start)
        if at("SELECT") {
            selectBody(&select)
        } else if at("(") {
            index += 1
            let inner = query()
            closeQuery(inner)
            select.nested = inner
            clauses(&select)
        } else if at("VALUES") {
            index += 1
            select.clauses.append((.values, start))
            repeat {
                accept("ROW")
                guard at("(") else {
                    fail("Expected a row in brackets\(foundText)")
                    break
                }
                index += 1
                var row: [SQLExpr] = []
                repeat { row.append(expression()) } while accept(",")
                if !expect(")") { skip(to: []); accept(")") }
                select.rows.append(row)
            } while accept(",")
            clauses(&select)
        } else if at("TABLE") {
            let tableStart = current.range.lowerBound
            index += 1
            if let name = dottedName("a table name") {
                select.table = SQLTableRef(kind: .table, range: tableStart..<lastEnd, name: name)
            }
            clauses(&select)
        } else {
            fail("Expected SELECT\(foundText)")
        }
        select.range = start..<max(start, lastEnd)
        return select
    }

    private mutating func selectBody(_ select: inout SQLSelect) {
        select.clauses.append((.selectList, current.range.upperBound))
        index += 1
        while at(Self.selectModifiers) {
            if at("DISTINCT") || at("DISTINCTROW") { select.distinct = true }
            index += 1
        }
        repeat {
            let item = selectItem()
            if case .invalid = item.expr.kind { skip(to: Self.clauseWords.union([","])) } else { select.items.append(item) }
        } while accept(",")
        clauses(&select)
    }

    /// An expression with its alias: RETURNING's list and a SELECT's.
    mutating func selectItem() -> SQLSelectItem {
        let start = current.range.lowerBound
        let expr = expression()
        var alias: SQLIdentifier?
        if accept("AS") {
            if current.kind == .string || isName(current) || current.kind == .word {
                alias = aliasIdentifier()
            } else {
                fail("Expected a name after AS\(foundText)")
            }
        } else if current.kind == .string || canBeAlias(current) {
            alias = aliasIdentifier()
        }
        return SQLSelectItem(expr: expr, alias: alias, range: start..<max(start, lastEnd))
    }

    private func canBeAlias(_ token: Token) -> Bool {
        isName(token) && !Self.aliasStops.contains(token.upper)
    }

    private mutating func aliasIdentifier() -> SQLIdentifier {
        defer { index += 1 }
        var name = identifier(current)
        if current.kind == .string {
            name.value = String(name.value.drop { $0 != "'" && $0 != "\"" }.dropFirst().dropLast())
            name.quoted = true
        }
        return name
    }

    /// What follows the select list, in the grammar's order.
    private mutating func clauses(_ select: inout SQLSelect) {
        var reached = 0, reachedWord = ""
        while !gaveUp {
            let word = current.upper, start = current.range.lowerBound
            if word == "FOR" || word == "LOCK", !(peek().upper == "UPDATE" || peek().upper == "SHARE" || peek().upper == "IN") { break }
            if word == "OFFSET", peek().kind != .number, peek().kind != .variable, peek().upper != "?" { break }
            if let rank = Self.clauseOrder[word] {
                if rank < reached {
                    fail("\(word) can’t come after \(reachedWord)")
                }
                reached = max(reached, rank)
                reachedWord = word
            }
            switch word {
            case "INTO":
                select.clauses.append((.into, start))
                index += 1
                // OUTFILE 'x' with its options, or variables: nothing that names a column.
                skip(to: Self.clauseWords.subtracting(["ON", "SET", "INTO"]))
            case "FROM":
                select.clauses.append((.from, current.range.upperBound))
                index += 1
                if !accept("DUAL") { select.from = tableList(&select.clauses) }
            case "WHERE":
                select.clauses.append((.whereClause, current.range.upperBound))
                index += 1
                select.whereClause = expression()
            case "GROUP":
                index += 1
                select.clauses.append((.groupBy, current.range.upperBound))
                guard expect("BY", "Expected BY after GROUP\(foundText)") else { break }
                repeat {
                    select.groupBy.append(expression())
                    if at("ASC") || at("DESC") { index += 1 }
                } while accept(",")
                if accept("WITH", "ROLLUP") { select.rollup = true }
                if accept("WITH", "CUBE") { select.rollup = true }
            case "HAVING":
                select.clauses.append((.having, current.range.upperBound))
                index += 1
                select.having = expression()
            case "WINDOW":
                select.clauses.append((.window, current.range.upperBound))
                index += 1
                repeat {
                    guard nameIdentifier("a window’s name") != nil, expect("AS"), expect("(") else { break }
                    select.windows += windowBody()
                } while accept(",")
            case "ORDER":
                index += 1
                select.clauses.append((.orderBy, current.range.upperBound))
                guard expect("BY", "Expected BY after ORDER\(foundText)") else { break }
                select.orderBy = order()
            case "LIMIT":
                select.clauses.append((.limit, current.range.upperBound))
                index += 1
                select.limit = limit()
            case "OFFSET":
                select.clauses.append((.limit, current.range.upperBound))
                index += 1
                select.limit.append(expression())
                if at("ROW") || at("ROWS") { index += 1 }
            case "FETCH":  // MariaDB: FETCH FIRST 5 ROWS ONLY
                select.clauses.append((.limit, current.range.upperBound))
                index += 1
                skip(to: Self.clauseWords)
            case "PROCEDURE":
                select.clauses.append((.other, start))
                index += 1
                skip(to: Self.clauseWords.subtracting(["PROCEDURE"]))
            case "FOR", "LOCK":
                select.clauses.append((.other, start))
                index += 1
                skip(to: ["INTO", "UNION"])
            default:
                return
            }
            if !errors.isEmpty { skip(to: Self.clauseWords) }
        }
    }

    /// After LIMIT: n, a, b, n OFFSET m, and MariaDB's ROWS EXAMINED.
    mutating func limit() -> [SQLExpr] {
        var values: [SQLExpr] = []
        if !at("ROWS") {
            values.append(expression())
            if accept(",") || accept("OFFSET") { values.append(expression()) }
        }
        if accept("ROWS", "EXAMINED") { values.append(expression()) }
        return values
    }

    // MARK: Tables

    /// a, b JOIN c ON …, flat. `clauses` hears where each ON starts.
    mutating func tableList(_ clauses: inout [(clause: SQLClause, start: Int)]) -> [SQLTableRef] {
        var tables: [SQLTableRef] = []
        repeat { joinChain(&tables, &clauses) } while accept(",")
        return tables
    }

    private mutating func joinChain(_ tables: inout [SQLTableRef], _ clauses: inout [(clause: SQLClause, start: Int)]) {
        tableFactor(&tables, &clauses, nil)
        while let join = joinWords() {
            let first = tables.count
            tableFactor(&tables, &clauses, join)
            guard tables.count > first else { return }
            if at("ON") {
                clauses.append((.on, current.range.upperBound))
                index += 1
                tables[first].join?.on = expression()
                clauses.append((.from, lastEnd))
            } else if at("USING") {
                index += 1
                if at("(") { tables[first].join?.using = nameList("a column name") } else { fail("Expected ( after USING\(foundText)") }
            }
        }
    }

    /// The words of a join, when one comes next.
    private mutating func joinWords() -> SQLJoin? {
        let start = current.range.lowerBound
        func made(_ kind: String) -> SQLJoin { SQLJoin(kind: kind, range: start..<lastEnd) }
        if accept("JOIN") { return made("JOIN") }
        if accept("INNER", "JOIN") { return made("JOIN") }
        if accept("CROSS", "JOIN") { return made("CROSS JOIN") }
        if accept("STRAIGHT_JOIN") { return made("STRAIGHT_JOIN") }
        if at("LEFT") || at("RIGHT"), peek().upper == "JOIN" || (peek().upper == "OUTER" && peek(2).upper == "JOIN") {
            let side = current.upper
            index += 1
            accept("OUTER")
            index += 1
            return made(side + " JOIN")
        }
        if at("NATURAL") {
            index += 1
            var side = ""
            if at("LEFT") || at("RIGHT") || at("INNER") {
                side = at("INNER") ? "" : current.upper + " "
                index += 1
            }
            accept("OUTER")
            if !expect("JOIN", "Expected JOIN after NATURAL\(foundText)") { return nil }
            return made("NATURAL \(side)JOIN")
        }
        return nil
    }

    private mutating func tableFactor(_ tables: inout [SQLTableRef], _ clauses: inout [(clause: SQLClause, start: Int)], _ join: SQLJoin?) {
        let start = current.range.lowerBound
        var ref: SQLTableRef
        let lateral = accept("LATERAL")
        if at("("), looksLikeQuery(index + 1) {
            index += 1
            let inner = query()
            closeQuery(inner)
            ref = SQLTableRef(kind: .derived, range: start..<lastEnd, query: inner, lateral: lateral)
            aliasOfTable(&ref)
            if at("(") { ref.columnAliases = nameList("a column name") }
        } else if at("(") {
            // ( a JOIN b ): the brackets only group, and what's in them joins as one.
            index += 1
            let first = tables.count
            var chain: [SQLTableRef] = []
            deeper(()) { parser in
                repeat { parser.joinChain(&chain, &clauses) } while parser.accept(",")
            }
            if !expect(")") { skip(to: []); accept(")") }
            tables += chain
            if tables.count > first, tables[first].join == nil { tables[first].join = join }
            return
        } else if at("{") {
            skipBrackets()
            ref = SQLTableRef(kind: .opaque, range: start..<lastEnd)
        } else if at("JSON_TABLE"), peek().upper == "(" {
            index += 2
            let expr = expression()
            skip(to: [])
            accept(")")
            ref = SQLTableRef(kind: .opaque, range: start..<lastEnd, expressions: [expr])
            aliasOfTable(&ref)
        } else if let name = dottedName("a table name") {
            ref = SQLTableRef(kind: .table, range: name.range, name: name)
            afterTableName(&ref)
        } else {
            return
        }
        ref.join = join
        ref.range = start..<lastEnd
        tables.append(ref)
    }

    /// PARTITION, system-versioning, an alias and index hints: what may follow a table's name.
    mutating func afterTableName(_ ref: inout SQLTableRef) {
        if at("PARTITION"), peek().upper == "(" {
            index += 1
            skipBrackets()
        }
        if accept("FOR", "SYSTEM_TIME") {  // MariaDB's system versioning; the bounds are values no higher than a comparison
            if accept("AS", "OF") {
                if at("TIMESTAMP"), peek().kind != .string { index += 1 }
                _ = expression(7)
            } else if accept("BETWEEN") || accept("FROM") {
                _ = expression(7)
                index += 1  // AND, TO
                _ = expression(7)
            } else {
                accept("ALL")
            }
        }
        aliasOfTable(&ref)
        while at("USE") || at("FORCE") || at("IGNORE"), ["INDEX", "KEY"].contains(peek().upper) {
            index += 2
            if accept("FOR") {
                if !accept("JOIN"), !accept("ORDER", "BY") { accept("GROUP", "BY") }
            }
            if at("(") { skipBrackets() } else { fail("Expected ( after the index hint\(foundText)") }
            if at(","), ["USE", "FORCE", "IGNORE"].contains(peek().upper) { index += 1 }
        }
    }

    private mutating func aliasOfTable(_ ref: inout SQLTableRef) {
        if accept("AS") {
            ref.alias = nameIdentifier("an alias")
        } else if canBeAlias(current) {
            ref.alias = identifier(current)
            index += 1
        }
    }
}
