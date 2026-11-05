// What `SQLParser` builds: plain values, every range in UTF-16 offsets of the whole text, as `SQLToken` and NSTextView
// count. A tree is never missing because the text is wrong or half typed: what couldn't be read is left out and the
// statement's `errors` say where.

/// A name as written: `value` without its quotes.
public struct SQLIdentifier: Equatable, Sendable {
    public var value: String
    public var range: Range<Int>
    public var quoted: Bool
}

/// A dotted name: a, t.a, db.t.a.
public struct SQLName: Equatable, Sendable {
    public var parts: [SQLIdentifier]
    public var range: Range<Int> { parts[0].range.lowerBound..<parts[parts.count - 1].range.upperBound }
    public var last: SQLIdentifier { parts[parts.count - 1] }
    /// The part before the last: a column's table, a table's database.
    public var qualifier: SQLIdentifier? { parts.count > 1 ? parts[parts.count - 2] : nil }
}

public struct SQLSyntaxError: Equatable, Sendable {
    public var range: Range<Int>
    public var message: String
}

public struct SQLExpr: Sendable {
    public enum Kind: Sendable {
        /// `name`: a, t.a, db.t.a.
        case column
        /// `name` is what's before the *, if anything.
        case star
        /// `op`: "number", "string", "date", "NULL", "TRUE", "FALSE".
        case literal
        /// @a, @@a; ? and :a are `.parameter`.
        case variable, parameter
        /// `name`; `children` are its arguments, `extra` its ORDER BY and OVER expressions.
        case call
        /// `op` before `children[0]`: - + ~ ! NOT BINARY, and ANY, SOME, ALL before a subquery.
        case unary
        /// `op` between `children`; AND and OR take any number of them, the rest two.
        case binary
        /// `children[0]` IS `op` (NULL, TRUE, FALSE, UNKNOWN).
        case isTest
        /// `children[0]` IN the others, or IN `query`.
        case inList
        /// `children`: value, low, high.
        case between
        /// `op` (LIKE, REGEXP, RLIKE, SOUNDS LIKE, MEMBER OF), `children`: value, pattern and any ESCAPE.
        case like
        /// `extra`: its operand if any. `children`: when, then, when, then…, and last its ELSE if the count is odd.
        case caseWhen
        /// (a) or (a, b): brackets, and row values.
        case row
        /// `query`, in brackets.
        case subquery
        /// EXISTS `query`.
        case exists
        /// INTERVAL `children[0]` `op`.
        case interval
        /// A word that isn't a value of its own: DAY in EXTRACT, DEFAULT.
        case keyword
        /// Where a value should be and isn't.
        case invalid
    }

    public var kind: Kind
    public var range: Range<Int>
    public var op = ""
    /// Where `op` stands, for those that have one.
    public var opRange: Range<Int>?
    public var name: SQLName?
    public var children: [SQLExpr] = []
    public var extra: [SQLExpr] = []
    public var query: SQLQuery?
    /// NOT IN, NOT LIKE, IS NOT, NOT BETWEEN.
    public var negated = false
    /// COUNT(DISTINCT a).
    public var distinct = false
    /// A call with an OVER.
    public var isWindow = false
    /// A call with syntax in its brackets this doesn't read: its `children` don't tell how many arguments it has.
    public var opaque = false

    /// Calls `visit` on this expression and all those inside it, not going into subqueries.
    public func walk(_ visit: (SQLExpr) -> Void) {
        visit(self)
        for child in children { child.walk(visit) }
        for child in extra { child.walk(visit) }
    }
}

public struct SQLSelectItem: Sendable {
    public var expr: SQLExpr
    public var alias: SQLIdentifier?
    public var range: Range<Int>
}

public struct SQLOrderItem: Sendable {
    public var expr: SQLExpr
    /// ASC or DESC, when written.
    public var direction: SQLIdentifier?
}

public struct SQLJoin: Sendable {
    /// The words as a keyword: "JOIN", "LEFT JOIN", "NATURAL JOIN", "CROSS JOIN", "STRAIGHT_JOIN".
    public var kind: String
    public var range: Range<Int>
    public var on: SQLExpr?
    public var using: [SQLIdentifier] = []
    public var natural: Bool { kind.hasPrefix("NATURAL") }
}

/// A row source of a FROM, UPDATE or DELETE. Nested joins come flat, in order.
public struct SQLTableRef: Sendable {
    public enum Kind: Sendable {
        /// `name`.
        case table
        /// (`query`) alias.
        case derived
        /// JSON_TABLE(…) or { OJ … }: columns nobody here can name.
        case opaque
    }

    public var kind: Kind
    public var range: Range<Int>
    public var name: SQLName?
    public var query: SQLQuery?
    public var alias: SQLIdentifier?
    public var columnAliases: [SQLIdentifier] = []
    public var lateral = false
    /// How it joins what's before it; nil for the first and after a comma.
    public var join: SQLJoin?
    /// Expressions it holds that read earlier tables (JSON_TABLE's first argument).
    public var expressions: [SQLExpr] = []
}

public struct SQLCTE: Sendable {
    public var name: SQLIdentifier
    public var columns: [SQLIdentifier]
    public var query: SQLQuery
    public var range: Range<Int>
}

public enum SQLClause: Sendable {
    case selectList, from, on, whereClause, groupBy, having, window, orderBy, limit, into, set, values, insertColumns, returning, other
}

/// One SELECT, or a block of a UNION.
public struct SQLSelect: Sendable {
    public var range: Range<Int>
    public var distinct = false
    public var items: [SQLSelectItem] = []
    public var from: [SQLTableRef] = []
    public var whereClause: SQLExpr?
    public var groupBy: [SQLExpr] = []
    public var rollup = false
    public var having: SQLExpr?
    /// Every expression in a WINDOW clause.
    public var windows: [SQLExpr] = []
    public var orderBy: [SQLOrderItem] = []
    public var limit: [SQLExpr] = []
    /// A block in brackets: (SELECT …) UNION (SELECT …).
    public var nested: SQLQuery?
    /// VALUES ROW(1, 2), ROW(3, 4).
    public var rows: [[SQLExpr]] = []
    /// TABLE t.
    public var table: SQLTableRef?
    /// Where each clause starts, in order: the last one at or before a place is the clause there.
    public var clauses: [(clause: SQLClause, start: Int)] = []
}

/// A query expression: WITH, then blocks joined by UNION, EXCEPT or INTERSECT. A class, as expressions hold queries.
public final class SQLQuery: @unchecked Sendable {
    public var range: Range<Int>
    /// Its brackets' inside, or the statement: everything that belongs to it, trailing space included.
    public var extent: Range<Int>
    public var ctes: [SQLCTE] = []
    public var recursive = false
    public var blocks: [SQLSelect] = []
    /// UNION, UNION ALL…: one fewer than `blocks`.
    public var setOperators: [String] = []
    /// A union's own ORDER BY and LIMIT.
    public var orderBy: [SQLOrderItem] = []
    public var limit: [SQLExpr] = []

    init(range: Range<Int>) {
        self.range = range
        extent = range
    }
}

public struct SQLAssignment: Sendable {
    public var column: SQLName
    public var value: SQLExpr
}

public struct SQLInsertRow: Sendable {
    public var range: Range<Int>
    public var values: [SQLExpr]
}

/// What INSERT, REPLACE, UPDATE and DELETE hold besides a query.
public struct SQLWrite: Sendable {
    /// INSERT's table, UPDATE's tables, DELETE's FROM.
    public var tables: [SQLTableRef] = []
    /// UPDATE's or DELETE's tables with their joins' conditions.
    public var tablesRange: Range<Int>?
    /// DELETE a, b FROM …: the tables rows go from.
    public var deleteTargets: [SQLName] = []
    public var columns: [SQLIdentifier] = []
    /// INSERT's bracketed column list, brackets included.
    public var columnsRange: Range<Int>?
    public var rows: [SQLInsertRow] = []
    /// VALUES row alias: VALUES (…) AS new (a, b).
    public var rowAlias: SQLIdentifier?
    public var rowAliasColumns: [SQLIdentifier] = []
    public var assignments: [SQLAssignment] = []
    public var onDuplicate: [SQLAssignment] = []
    public var whereClause: SQLExpr?
    public var orderBy: [SQLOrderItem] = []
    public var limit: [SQLExpr] = []
    public var returning: [SQLSelectItem] = []
    /// The word SET, WHERE…
    public var clauses: [(clause: SQLClause, start: Int)] = []
}

public struct SQLColumnDefinition: Sendable {
    public var name: SQLIdentifier
    /// The type as written, upper case: "VARCHAR(20)".
    public var type: String
    public var range: Range<Int>
    public var autoIncrement = false
}

/// A named object a statement makes, changes or drops.
public struct SQLObjectRef: Sendable {
    /// TABLE, VIEW, INDEX, DATABASE, FUNCTION, PROCEDURE, TRIGGER, EVENT…
    public var kind: String
    public var name: SQLName
}

/// One statement. Only what's parsed is filled in: the kinds below `use` are read as far as `verb`.
public struct SQLParsedStatement: Sendable {
    public enum Kind: Sendable {
        case select, insert, replace, update, delete, create, alter, drop, truncate, rename, use, set, call, explain, other
    }

    public var kind: Kind
    /// The first word, upper case.
    public var verb: String
    public var range: Range<Int>
    /// Just after its delimiter: where the next one may begin.
    public var end: Int
    /// The SELECT; under INSERT … SELECT, CREATE VIEW and CREATE TABLE … SELECT too.
    public var query: SQLQuery?
    public var write: SQLWrite?
    /// WITH before an UPDATE or DELETE.
    public var ctes: [SQLCTE] = []
    /// What it makes, changes or drops: DROP TABLE a, b gives two; RENAME TABLE a TO b gives a and b.
    public var objects: [SQLObjectRef] = []
    /// CREATE TABLE's columns.
    public var columns: [SQLColumnDefinition] = []
    /// A routine or trigger's header: its parameters (names only) and where its body starts.
    public var parameters: [SQLIdentifier] = []
    public var bodyStart: Int?
    /// CALL's arguments.
    public var arguments: [SQLExpr] = []
    /// The first syntax error, if any: what follows one is rarely worth reporting. Never one for a statement this
    /// doesn't fully read.
    public var errors: [SQLSyntaxError] = []
    /// Only partly read (a kind this doesn't parse, code in an executable comment, nesting too deep): nothing can be
    /// said about what's missing from it.
    public var shallow = false
}
