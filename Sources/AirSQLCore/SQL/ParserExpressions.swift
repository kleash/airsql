extension SQLParser {
    /// How tightly each operator binds, as MySQL's manual lists them; a word or symbol not here isn't an infix.
    private static let binaryPower: [String: Int] = [
        ":=": 1, "OR": 2, "||": 2, "XOR": 3, "AND": 4, "&&": 4,
        "=": 7, "<=>": 7, ">=": 7, ">": 7, "<=": 7, "<": 7, "<>": 7, "!=": 7,
        "|": 8, "&": 9, "<<": 10, ">>": 10, "+": 11, "-": 11, "*": 12, "/": 12, "DIV": 12, "MOD": 12, "%": 12, "^": 13,
    ]
    /// Above NOT and level with comparisons: IS, LIKE, IN, BETWEEN and the like.
    private static let predicatePower = 7
    private static let notPower = 5
    private static let unaryPower = 14
    /// Past this a chain like 1 + 1 + 1 … isn't read on: the walkers recurse, and a stack is finite. AND and OR chains
    /// stay flat, so they don't count.
    private static let chainLimit = 256

    static let units: Set<String> = [
        "MICROSECOND", "SECOND", "MINUTE", "HOUR", "DAY", "WEEK", "MONTH", "QUARTER", "YEAR", "SECOND_MICROSECOND", "MINUTE_MICROSECOND",
        "MINUTE_SECOND", "HOUR_MICROSECOND", "HOUR_SECOND", "HOUR_MINUTE", "DAY_MICROSECOND", "DAY_SECOND", "DAY_MINUTE", "DAY_HOUR",
        "YEAR_MONTH", "SQL_TSI_SECOND", "SQL_TSI_MINUTE", "SQL_TSI_HOUR", "SQL_TSI_DAY", "SQL_TSI_WEEK", "SQL_TSI_MONTH", "SQL_TSI_QUARTER",
        "SQL_TSI_YEAR", "FRAC_SECOND",
    ]
    /// Reserved words that are values or start one without brackets.
    private static let valueWords: Set<String> = [
        "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER", "LOCALTIME", "LOCALTIMESTAMP", "UTC_DATE", "UTC_TIME",
        "UTC_TIMESTAMP",
    ]
    /// Reserved words that brackets make a call, past the read-only list of functions (which has the rest).
    private static let callWords: Set<String> = ["MATCH", "VALUES", "SCHEMA", "CHAR", "INSERT", "IF", "LEFT", "RIGHT", "REPLACE", "REPEAT"]

    /// An expression; `SQLExpr.Kind.invalid` if none is here, with the error said.
    mutating func expression(_ power: Int = 0) -> SQLExpr {
        deeper(SQLExpr(kind: .invalid, range: current.range)) { $0.expressionBody(power) }
    }

    private mutating func expressionBody(_ power: Int) -> SQLExpr {
        var left = prefix()
        var chain = 0
        while !gaveUp {
            chain += 1
            if chain > Self.chainLimit {
                gaveUp = true
                index = tokens.count
                break
            }
            let token = current
            guard token.kind == .word || token.kind == .symbol, !token.upper.isEmpty else { break }
            if token.upper == "->" || token.upper == "->>" {
                index += 1
                let path = prefix()
                left = SQLExpr(kind: .binary, range: left.range.lowerBound..<lastEnd, op: token.upper, opRange: token.range, children: [left, path])
            } else if token.upper == "COLLATE" {
                index += 1
                if current.kind == .word || current.kind == .string || current.kind == .quotedName { index += 1 } else { fail("Expected a collation") }
                left.range = left.range.lowerBound..<lastEnd
            } else if let next = predicate(left, power) {
                left = next
            } else if let strength = Self.binaryPower[token.upper], strength > power {
                index += 1
                // := groups to the right: @a := @b := 1.
                let right = expression(token.upper == ":=" ? strength - 1 : strength)
                let op = token.upper == "&&" ? "AND" : token.upper == "||" ? "OR" : token.upper
                if ["AND", "OR"].contains(op), case .binary = left.kind, left.op == op {
                    left.children.append(right)
                    left.range = left.range.lowerBound..<lastEnd
                    chain = 0
                } else {
                    left = SQLExpr(kind: .binary, range: left.range.lowerBound..<lastEnd, op: op, opRange: token.range, children: [left, right])
                }
            } else {
                break
            }
        }
        return left
    }

    /// IS, IN, LIKE, BETWEEN, with or without NOT, when one follows `left` and binds at this `power`.
    private mutating func predicate(_ left: SQLExpr, _ power: Int) -> SQLExpr? {
        guard Self.predicatePower > power else { return nil }
        let start = index, opRange = current.range
        var negated = false
        if at("IS") {
            index += 1
            negated = accept("NOT")
            let value = current.upper
            guard ["NULL", "TRUE", "FALSE", "UNKNOWN"].contains(value) else {
                fail("Expected NULL, TRUE, FALSE or UNKNOWN after IS\(foundText)")
                return SQLExpr(kind: .isTest, range: left.range, children: [left])
            }
            index += 1
            return SQLExpr(kind: .isTest, range: left.range.lowerBound..<lastEnd, op: value, opRange: opRange, children: [left], negated: negated)
        }
        if at("NOT"), ["IN", "LIKE", "BETWEEN", "REGEXP", "RLIKE"].contains(peek().upper) {
            index += 1
            negated = true
        }
        switch current.upper {
        case "IN":
            index += 1
            return inList(left, negated, opRange)
        case "BETWEEN":
            index += 1
            let low = expression(Self.predicatePower)
            expect("AND", "Expected AND after BETWEEN’s first value\(foundText)")
            let high = expression(Self.predicatePower)
            return SQLExpr(kind: .between, range: left.range.lowerBound..<lastEnd, opRange: opRange, children: [left, low, high], negated: negated)
        case "LIKE", "REGEXP", "RLIKE":
            let op = current.upper
            index += 1
            var children = [left, expression(Self.predicatePower)]
            if accept("ESCAPE") { children.append(expression(Self.predicatePower)) }
            return SQLExpr(kind: .like, range: left.range.lowerBound..<lastEnd, op: op, opRange: opRange, children: children, negated: negated)
        case "SOUNDS" where peek().upper == "LIKE":
            index += 2
            return SQLExpr(kind: .like, range: left.range.lowerBound..<lastEnd, op: "SOUNDS LIKE", opRange: opRange,
                           children: [left, expression(Self.predicatePower)])
        case "MEMBER" where peek().upper == "OF" || peek().upper == "(":
            index += peek().upper == "OF" ? 2 : 1
            return SQLExpr(kind: .like, range: left.range.lowerBound..<lastEnd, op: "MEMBER OF", opRange: opRange,
                           children: [left, expression(Self.predicatePower)])
        default:
            index = start
            return nil
        }
    }

    private mutating func inList(_ left: SQLExpr, _ negated: Bool, _ opRange: Range<Int>) -> SQLExpr {
        var result = SQLExpr(kind: .inList, range: left.range, opRange: opRange, children: [left], negated: negated)
        guard at("(") else {
            fail("Expected ( after IN\(foundText)")
            return result
        }
        if looksLikeQuery(index + 1) {
            index += 1
            result.query = query()
            closeQuery(result.query!)
        } else {
            index += 1
            repeat { result.children.append(expression()) } while accept(",")
            if !expect(")") { skip(to: []); accept(")") }
        }
        result.range = left.range.lowerBound..<lastEnd
        return result
    }

    /// Takes the ")" of a bracketed `query`, which then owns what's inside the brackets.
    mutating func closeQuery(_ query: SQLQuery) {
        query.extent = query.range.lowerBound..<(at(")") ? current.range.lowerBound : end)
        if !expect(")") { skip(to: []); accept(")") }
    }

    /// A query starts at token `at`, under any number of brackets.
    func looksLikeQuery(_ start: Int) -> Bool {
        var i = start
        while i < tokens.count, tokens[i].upper == "(" { i += 1 }
        guard i < tokens.count else { return false }
        return ["SELECT", "WITH"].contains(tokens[i].upper) || (["VALUES", "TABLE"].contains(tokens[i].upper) && i + 1 < tokens.count
            && (tokens[i].upper == "TABLE" || tokens[i + 1].upper == "ROW"))
    }

    private mutating func prefix() -> SQLExpr {
        let token = current, start = token.range.lowerBound
        switch token.kind {
        case .number:
            index += 1
            return SQLExpr(kind: .literal, range: token.range, op: "number")
        case .string:
            index += 1
            while current.kind == .string { index += 1 }  // 'a' 'b' is one string
            return SQLExpr(kind: .literal, range: start..<lastEnd, op: "string")
        case .variable:
            index += 1
            return SQLExpr(kind: .variable, range: token.range, op: token.text)
        case .quotedName:
            return nameOrCall()
        case .word:
            return word()
        case .symbol:
            switch token.upper {
            case "(":
                return bracket()
            case "-", "+", "~", "!":
                index += 1
                let operand = expression(Self.unaryPower)
                return SQLExpr(kind: .unary, range: start..<lastEnd, op: token.upper, opRange: token.range, children: [operand])
            case "?":
                index += 1
                return SQLExpr(kind: .parameter, range: token.range)
            case ":" where peek().kind == .word || peek().kind == .number:
                index += 2
                return SQLExpr(kind: .parameter, range: start..<lastEnd)
            case "*":
                index += 1
                return SQLExpr(kind: .star, range: token.range)
            case "{":  // ODBC: { d '2020-01-01' }, { fn NOW() }
                skipBrackets()
                return SQLExpr(kind: .keyword, range: start..<lastEnd)
            default:
                break
            }
        default:
            break
        }
        fail(atEnd ? "Expected a value" : "Expected a value, found \(token.text)")
        return SQLExpr(kind: .invalid, range: token.range)
    }

    private mutating func bracket() -> SQLExpr {
        let start = current.range.lowerBound
        if looksLikeQuery(index + 1) {
            index += 1
            let inner = query()
            closeQuery(inner)
            return SQLExpr(kind: .subquery, range: start..<lastEnd, query: inner)
        }
        index += 1
        var result = SQLExpr(kind: .row, range: start..<start)
        repeat { result.children.append(expression()) } while accept(",")
        if !expect(")") { skip(to: []); accept(")") }
        result.range = start..<lastEnd
        return result
    }

    private mutating func word() -> SQLExpr {
        let token = current, start = token.range.lowerBound, next = peek()
        switch token.upper {
        case "NULL", "TRUE", "FALSE":
            index += 1
            return SQLExpr(kind: .literal, range: token.range, op: token.upper)
        case "NOT":
            index += 1
            let operand = expression(Self.notPower)
            return SQLExpr(kind: .unary, range: start..<lastEnd, op: "NOT", opRange: token.range, children: [operand])
        case "BINARY":
            index += 1
            let operand = expression(Self.unaryPower)
            return SQLExpr(kind: .unary, range: start..<lastEnd, op: "BINARY", opRange: token.range, children: [operand])
        case "EXISTS" where next.upper == "(":
            index += 2
            let inner = query()
            closeQuery(inner)
            return SQLExpr(kind: .exists, range: start..<lastEnd, query: inner)
        case "ANY", "SOME", "ALL":
            if next.upper == "(", looksLikeQuery(index + 2) {
                index += 1
                let inner = bracket()
                return SQLExpr(kind: .unary, range: start..<lastEnd, op: token.upper, opRange: token.range, children: [inner])
            }
        case "CASE":
            return caseExpression()
        case "INTERVAL":
            if let interval = intervalExpression() { return interval }
        case "DEFAULT" where next.upper != "(":
            index += 1
            return SQLExpr(kind: .keyword, range: token.range, op: "DEFAULT")
        case "DATE", "TIME", "TIMESTAMP":
            if next.kind == .string {
                index += 2
                return SQLExpr(kind: .literal, range: start..<lastEnd, op: "date")
            }
        case "NEXT", "PREVIOUS":
            if next.upper == "VALUE", peek(2).upper == "FOR" {  // MariaDB's sequences
                index += 3
                _ = dottedName("a sequence")
                return SQLExpr(kind: .keyword, range: start..<lastEnd)
            }
        case "ROW" where next.upper == "(":
            index += 1
            var row = bracket()
            row.range = start..<lastEnd
            return row
        default:
            break
        }
        if token.upper.hasPrefix("_"), next.kind == .string || next.kind == .number {  // _utf8mb4'text'
            index += 2
            while current.kind == .string { index += 1 }
            return SQLExpr(kind: .literal, range: start..<lastEnd, op: next.kind == .string ? "string" : "number")
        }
        if Self.valueWords.contains(token.upper) {
            index += 1
            if at("(") { skipBrackets() }
            return SQLExpr(kind: .call, range: start..<lastEnd, name: SQLName(parts: [identifier(token)]))
        }
        if SQLWords.reserved.contains(token.upper) {
            guard next.upper == "(", Self.callWords.contains(token.upper) || SQLWords.readOnlyFunctions.contains(token.upper) else {
                fail("Expected a value, found \(token.text)")
                return SQLExpr(kind: .invalid, range: token.range)
            }
            index += 1
            return call(SQLName(parts: [identifier(token)]))
        }
        return nameOrCall()
    }

    /// a, a.b, a.*, a(…), db.f(…).
    private mutating func nameOrCall() -> SQLExpr {
        let start = current.range.lowerBound
        var parts = [identifier(current)]
        index += 1
        while at(".") {
            let next = peek()
            if next.upper == "*" {
                index += 2
                return SQLExpr(kind: .star, range: start..<lastEnd, name: SQLName(parts: parts))
            }
            guard followsDot(next) else {
                index += 1
                fail("Expected a name after the dot\(foundText)")
                break
            }
            parts.append(identifier(next))
            index += 2
        }
        let name = SQLName(parts: parts)
        if at("(") { return call(name) }
        return SQLExpr(kind: .column, range: name.range, name: name)
    }

    private mutating func caseExpression() -> SQLExpr {
        let start = current.range.lowerBound
        index += 1
        var result = SQLExpr(kind: .caseWhen, range: start..<start)
        if !at("WHEN") { result.extra = [expression()] }
        while accept("WHEN") {
            result.children.append(expression())
            expect("THEN", "Expected THEN after WHEN’s condition\(foundText)")
            result.children.append(expression())
        }
        if result.children.isEmpty { fail("Expected WHEN\(foundText)") }
        if accept("ELSE") { result.children.append(expression()) }
        expect("END", "Expected END to close CASE\(foundText)")
        result.range = start..<lastEnd
        return result
    }

    /// INTERVAL 1 DAY, or nil to read INTERVAL(a, b, c) as the function it then is.
    private mutating func intervalExpression() -> SQLExpr? {
        let start = current.range.lowerBound, opening = index
        index += 1
        let errorsBefore = errors
        let value = expression(Self.predicatePower)
        guard at(Self.units) else {
            if peek(-1).upper == ")", tokens[opening + 1].upper == "(" {
                errors = errorsBefore
                index = opening + 1
                return call(SQLName(parts: [identifier(tokens[opening])]))
            }
            fail("Expected a unit such as DAY after INTERVAL’s value\(foundText)")
            return SQLExpr(kind: .interval, range: start..<lastEnd, children: [value])
        }
        let unit = current.upper
        index += 1
        return SQLExpr(kind: .interval, range: start..<lastEnd, op: unit, children: [value])
    }

    // MARK: Calls

    /// The arguments, from a "(" at `index`. Whatever a call holds that isn't plain arguments ends the reading of it
    /// without complaint: `opaque` says so.
    private mutating func call(_ name: SQLName) -> SQLExpr {
        let start = name.range.lowerBound, function = name.parts.count == 1 ? name.last.value.uppercased() : ""
        var result = SQLExpr(kind: .call, range: start..<start, name: name)
        index += 1  // (
        if accept(")") {
            finishCall(&result, start)
            return result
        }
        if at("DISTINCT") || at("DISTINCTROW") {
            index += 1
            result.distinct = true
        } else if at("ALL"), peek().upper != "(" {
            index += 1
        }
        switch function {
        case "CAST", "CONVERT":
            result.children.append(expression())
            // The type or the character set: no value, so no name to resolve.
            if !at(")") { skip(to: []) }
        case "TIMESTAMPDIFF", "TIMESTAMPADD", "EXTRACT", "GET_FORMAT":
            result.children.append(SQLExpr(kind: .keyword, range: current.range, op: current.upper))
            index += 1
            if accept(",") || accept("FROM") { arguments(&result) }
        case "TRIM":
            if at(["LEADING", "TRAILING", "BOTH"]) {
                index += 1
                if at("FROM") { index += 1 }
            }
            arguments(&result)
        case "POSITION":
            result.children.append(expression(Self.predicatePower))
            accept("IN")
            result.children.append(expression())
        case "JSON_TABLE", "XMLTABLE":
            result.opaque = true
            skip(to: [])
        default:
            arguments(&result)
        }
        if !at(")") {
            result.opaque = true
            skip(to: [])
        }
        accept(")")
        finishCall(&result, start)
        return result
    }

    /// Arguments up to the call's ")": commas, and the words that some calls take for them (FROM, FOR, USING, AS).
    private mutating func arguments(_ result: inout SQLExpr) {
        while !atEnd, !at(")") {
            result.children.append(expression())
            if accept(",") { continue }
            if accept("ORDER", "BY") { result.extra += order().map(\.expr) }
            if accept("SEPARATOR") { index += 1 }
            if accept("LIMIT") { result.extra += limit() }  // MariaDB's GROUP_CONCAT(… LIMIT 3)
            guard at(["FROM", "FOR"]) else { break }
            index += 1
            result.opaque = true
        }
    }

    /// What may follow the ")": OVER, WITHIN GROUP, AGAINST.
    private mutating func finishCall(_ result: inout SQLExpr, _ start: Int) {
        if at("AGAINST"), peek().upper == "(" {
            index += 2
            result.extra.append(expression(Self.predicatePower))
            if !at(")") { skip(to: []) }
            accept(")")
        }
        if accept("WITHIN", "GROUP"), at("(") {
            index += 1
            if accept("ORDER", "BY") { result.extra += order().map(\.expr) }
            skip(to: [])
            accept(")")
        }
        if accept("OVER") {
            result.isWindow = true
            if accept("(") {
                result.extra += windowBody()
            } else if isName(current) {
                index += 1
            } else {
                fail("Expected a window’s name or ( after OVER\(foundText)")
            }
        }
        result.range = start..<lastEnd
    }

    /// Inside OVER ( or a WINDOW definition, to just past its ")": the expressions it reads.
    mutating func windowBody() -> [SQLExpr] {
        var found: [SQLExpr] = []
        if isName(current), !at(["PARTITION", "ORDER", "ROWS", "RANGE", "GROUPS"]) { index += 1 }
        if accept("PARTITION", "BY") {
            repeat { found.append(expression()) } while accept(",")
        }
        if accept("ORDER", "BY") { found += order().map(\.expr) }
        skip(to: [])  // ROWS, RANGE: a frame names no columns
        accept(")")
        return found
    }

    /// The items after ORDER BY.
    mutating func order() -> [SQLOrderItem] {
        var items: [SQLOrderItem] = []
        repeat {
            var item = SQLOrderItem(expr: expression())
            if at("ASC") || at("DESC") {
                item.direction = identifier(current)
                index += 1
            }
            items.append(item)
        } while accept(",")
        return items
    }
}
