import Foundation

/// What a name in the text stands for. Two names mean the same thing when their `key`s are equal.
public struct SQLSymbol: Equatable, Sendable {
    public enum Kind: Sendable {
        /// `declaration` nil: objects of the server.
        case database, table, column, routine
        /// Declared in the text, at `declaration`: `FROM t a`, `WITH c AS`, `SELECT 1 AS x`, a derived table's alias.
        case tableAlias, cte, selectAlias
    }

    public var kind: Kind
    public var name: String
    /// A table's or routine's database; a column's table's.
    public var database: String?
    /// A column's table.
    public var table: String?
    public var declaration: Range<Int>?

    public var key: String {
        let place = declaration.map { "\($0.lowerBound)" } ?? "\(database ?? "")/\(table ?? "")"
        return "\(kind) \(place) \(name)".lowercased()
    }
    /// Declared in the text, so the text alone can rename it.
    public var isLocal: Bool { declaration != nil }
}

/// A name in the text and what it stands for.
public struct SQLReference: Sendable {
    public var range: Range<Int>
    public var symbol: SQLSymbol
    /// This is where it's declared.
    public var isDeclaration = false
}

/// A column a row source offers.
public struct SQLColumnInfo: Sendable {
    public var name: String
    /// The column's type, when it comes from the schema.
    public var type: String?
    public var schema: SchemaColumn?
    public var symbol: SQLSymbol
}

/// A table, CTE or derived table visible in a scope.
public struct SQLRowSource: Sendable {
    public enum Kind: Sendable { case table, cte, derived, opaque }

    public var kind: Kind
    /// What it's called here: its alias, else its name; "" for a derived table without one.
    public var name: String
    /// The table or CTE's own name.
    public var objectName: String?
    public var database: String?
    public var range: Range<Int>
    /// The whole of what's known, which `complete` says is everything or not.
    public var columns: [SQLColumnInfo] = []
    /// It has these columns and no others, as far as can be known: a name it lacks is one to report.
    public var complete = false
    public var table: SchemaTable?
    public var symbol: SQLSymbol?

    func has(_ name: String) -> SQLColumnInfo? {
        columns.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
}

/// What one SELECT block, or a write, can see.
public final class SQLScope: @unchecked Sendable {
    public let parent: SQLScope?
    /// Everything that belongs to this block.
    public var extent: Range<Int>
    public internal(set) var sources: [SQLRowSource] = []
    /// What the block outputs: names ORDER BY, HAVING and GROUP BY may use.
    public internal(set) var outputs: [SQLColumnInfo] = []
    /// CTEs declared here.
    public internal(set) var ctes: [SQLRowSource] = []
    public internal(set) var clauses: [(clause: SQLClause, start: Int)] = []
    var merged = Set<String>()
    /// A name this can't follow may be in force here, so what's missing isn't reported.
    var open = false

    init(parent: SQLScope?, extent: Range<Int>) {
        self.parent = parent
        self.extent = extent
    }

    /// CTEs seen from here, nearest first.
    public var visibleCTEs: [SQLRowSource] { ctes.reversed() + (parent?.visibleCTEs ?? []) }

    /// Every source seen from here: those of this block, then those a correlated subquery sees.
    public var visibleSources: [SQLRowSource] { sources + (parent?.visibleSources ?? []) }

    /// The clause `offset` is in.
    public func clause(at offset: Int) -> SQLClause? { clauses.last { $0.start <= offset }?.clause }

    func cte(_ name: String) -> SQLRowSource? {
        visibleCTEs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// A name that's wrong, found while resolving: `SQLNameCheck` and the inspections say it.
public struct SQLNameIssue: Sendable {
    public enum Kind: Sendable {
        case unknownTable(database: String)
        /// `place`: "“orders”" or "the tables this statement uses".
        case unknownColumn(place: String)
        /// `name.` isn't a table of this statement.
        case unknownQualifier
        case unknownRoutine(database: String)
        /// In these sources (by their names here).
        case ambiguous(sources: [String])
    }

    public var kind: Kind
    public var range: Range<Int>
    public var name: String
    /// Names that could have been meant.
    public var candidates: [String] = []
    /// The one table a column should have been in, when there's just one.
    public var table: SQLRowSource?
    /// Which statement.
    public var statement: Int
}

/// A script read and resolved: `SQLParser`'s trees, what each name stands for and what's wrong with the names. Works
/// without a schema too: then aliases, CTEs and their columns still resolve, and nothing is reported.
public struct SQLAnalysis: Sendable {
    public var statements: [SQLParsedStatement] = []
    /// By position.
    public var references: [SQLReference] = []
    public var issues: [SQLNameIssue] = []
    public var scopes: [SQLScope] = []
    public var text = ""
    public var snapshot: SchemaSnapshot?
    /// The current database at each statement: USE moves it.
    public var databases: [String?] = []
    /// Where each statement's scopes start in `scopes`.
    var firstScopes: [Int] = []

    /// `text` read with what `snapshot` knows. `changed`: `SQLNameCheck.changedNames` of what the session has run.
    public init(_ text: String, snapshot: SchemaSnapshot?, database: String?, changed: Set<String> = [], noBackslashEscapes: Bool = false) {
        self = SQLParser.withDeepStack {
            var resolver = SQLResolver(text: text, snapshot: snapshot, database: database, changed: changed, noBackslashEscapes: noBackslashEscapes)
            return resolver.run()
        }
    }

    init() {}

    /// The name at `offset`, or just before it (a caret at a name's end).
    public func reference(at offset: Int) -> SQLReference? {
        var low = 0, high = references.count
        while low < high {
            let middle = (low + high) / 2
            if references[middle].range.upperBound < offset { low = middle + 1 } else { high = middle }
        }
        return low < references.count && references[low].range.lowerBound <= offset ? references[low] : nil
    }

    /// Every place that means `symbol`, declaration included.
    public func usages(of symbol: SQLSymbol) -> [SQLReference] {
        let key = symbol.key
        return references.filter { $0.symbol.key == key }
    }

    /// The innermost scope around `offset`.
    public func scope(at offset: Int) -> SQLScope? {
        guard let index = statementIndex(at: offset) else { return nil }
        let first = firstScopes[index], last = index + 1 < firstScopes.count ? firstScopes[index + 1] : scopes.count
        // The last of equals: a query's block comes after the shell that holds its CTEs.
        return scopes[first..<last].reversed().filter { $0.extent.lowerBound <= offset && offset <= $0.extent.upperBound }
            .min { $0.extent.count < $1.extent.count }
    }

    /// The statement `offset` is in or that goes on to it: the last one that starts at or before it, up to its
    /// delimiter when it has one.
    public func statement(at offset: Int) -> SQLParsedStatement? { statementIndex(at: offset).map { statements[$0] } }

    private func statementIndex(at offset: Int) -> Int? {
        var low = 0, high = statements.count
        while low < high {
            let middle = (low + high) / 2
            if statements[middle].range.lowerBound <= offset { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let found = statements[low - 1]
        return found.end > found.range.upperBound && offset > found.end ? nil : low - 1
    }
}

/// Walks the trees of a script: builds each scope, then resolves every name in it from the inside out.
struct SQLResolver {
    let snapshot: SchemaSnapshot?
    let utf16: [UInt16]
    var database: String?
    var changed: Set<String>
    var result = SQLAnalysis()
    /// Past a routine's body split on its `;` the tables and the current database are anyone's guess.
    var silent = false
    var statementIndex = 0
    /// Where the statement's text ends, and where what follows it stops belonging to it.
    var statementEnd = (written: 0, extended: 0)

    init(text: String, snapshot: SchemaSnapshot?, database: String?, changed: Set<String>, noBackslashEscapes: Bool) {
        self.snapshot = snapshot
        self.database = database
        self.changed = changed
        utf16 = Array(text.utf16)
        result.text = text
        result.snapshot = snapshot
        result.statements = SQLParser.parse(text, noBackslashEscapes: noBackslashEscapes)
        for statement in result.statements where [.create, .alter, .drop, .rename].contains(statement.kind) {
            self.changed.formUnion(statement.objects.flatMap(\.name.parts).map { $0.value.lowercased() })
            self.changed.formUnion(SQLNameCheck.changedNames(in: string(statement.range), noBackslashEscapes: noBackslashEscapes))
        }
    }

    func string(_ range: Range<Int>) -> String { String(decoding: utf16[range], as: UTF16.self) }

    mutating func run() -> SQLAnalysis {
        for (index, statement) in result.statements.enumerated() {
            statementIndex = index
            result.databases.append(database)
            result.firstScopes.append(result.scopes.count)
            resolve(statement)
            if ["CALL", "EXECUTE", "DECLARE"].contains(statement.verb) || (statement.verb == "BEGIN" && string(statement.range).uppercased().contains("NOT ATOMIC"))
                || (statement.kind == .create && statement.bodyStart != nil) {
                silent = true
            }
        }
        result.references.sort { $0.range.lowerBound < $1.range.lowerBound }
        return result
    }

    mutating func issue(_ kind: SQLNameIssue.Kind, _ range: Range<Int>, _ name: String, candidates: [String] = [], table: SQLRowSource? = nil) {
        guard !silent, canReport else { return }
        result.issues.append(SQLNameIssue(kind: kind, range: range, name: name, candidates: candidates, table: table, statement: statementIndex))
    }

    /// A statement half typed or with code in an executable comment is one nothing can be said of.
    var canReport: Bool {
        let statement = result.statements[statementIndex]
        return statement.errors.isEmpty && !(statement.shallow && statement.kind != .create) && snapshot != nil
    }

    func newScope(_ parent: SQLScope?, _ extent: Range<Int>) -> SQLScope {
        SQLScope(parent: parent, extent: extent)
    }

    mutating func reference(_ range: Range<Int>, _ symbol: SQLSymbol, isDeclaration: Bool = false) {
        result.references.append(SQLReference(range: range, symbol: symbol, isDeclaration: isDeclaration))
    }

    // MARK: Statements

    private mutating func resolve(_ statement: SQLParsedStatement) {
        // A statement with no delimiter goes on to the next one: the space after it is where someone goes on typing.
        let next = statementIndex + 1 < result.statements.count ? result.statements[statementIndex + 1].range.lowerBound : utf16.count
        statementEnd = (statement.range.upperBound, statement.end > statement.range.upperBound ? statement.end : next)
        let extent = statement.range.lowerBound..<statementEnd.extended
        let root = newScope(nil, extent)
        result.scopes.append(root)
        declare(statement.ctes, in: root)
        if statement.kind == .use, let name = statement.objects.first?.name.last {
            database = name.value
            reference(name.range, SQLSymbol(kind: .database, name: name.value))
        }
        if let write = statement.write { resolve(write, statement, root) }
        if let query = statement.query { _ = visit(query, root) }
        objects(statement, root)
        for argument in statement.arguments { resolve(argument, root) }
    }

    /// The objects a DDL statement or CALL names.
    private mutating func objects(_ statement: SQLParsedStatement, _ scope: SQLScope) {
        guard statement.kind != .use else { return }
        for object in statement.objects {
            let name = object.name
            let place = name.qualifier?.value ?? database
            switch object.kind {
            case "TABLE", "VIEW":
                if let qualifier = name.qualifier { reference(qualifier.range, SQLSymbol(kind: .database, name: qualifier.value)) }
                reference(name.last.range, SQLSymbol(kind: .table, name: schemaName(place, name.last.value), database: place))
            case "PROCEDURE", "FUNCTION":
                routine(name, known: statement.kind == .call)
            case "DATABASE":
                reference(name.last.range, SQLSymbol(kind: .database, name: name.last.value))
            default:
                break
            }
        }
    }

    /// A routine's name; `known`: it must exist, as CALL's must.
    private mutating func routine(_ name: SQLName, known: Bool) {
        let place = name.qualifier?.value ?? database
        if let qualifier = name.qualifier { reference(qualifier.range, SQLSymbol(kind: .database, name: qualifier.value)) }
        let found = place.flatMap { snapshot?.database($0) }
        let routine = found?.routines.first { $0.name.caseInsensitiveCompare(name.last.value) == .orderedSame }
        reference(name.last.range, SQLSymbol(kind: .routine, name: routine?.name ?? name.last.value, database: place))
        if known, routine == nil, let found, found.detailsLoaded, !changed.contains(name.last.value.lowercased()) {
            issue(.unknownRoutine(database: found.name), name.last.range, name.last.value,
                  candidates: found.routines.map(\.name))
        }
    }

    /// The name as the schema has it, so references agree whatever case each is typed in.
    private func schemaName(_ database: String?, _ name: String) -> String {
        database.flatMap { snapshot?.table($0, name)?.name } ?? name
    }

    private mutating func resolve(_ write: SQLWrite, _ statement: SQLParsedStatement, _ scope: SQLScope) {
        scope.clauses = write.clauses
        addSources(write.tables, scope)
        for target in write.deleteTargets {
            // A name of DELETE's list: an alias of the tables that follow, or one of them.
            if let source = scope.sources.first(where: { $0.name.caseInsensitiveCompare(target.last.value) == .orderedSame }), let symbol = source.symbol {
                reference(target.last.range, symbol)
            }
        }
        let tableScope = scope
        if statement.write?.columnsRange != nil, let table = scope.sources.first {
            for column in write.columns { resolveColumn(column.value, column.range, in: [table], scope, canSayWhich: true) }
        }
        for row in write.rows {
            for value in row.values { resolve(value, tableScope) }
        }
        // ON DUPLICATE KEY sees the row alias, or under a SELECT that query's tables.
        let conflict = newScope(scope, scope.extent)
        conflict.open = statement.query != nil
        if let alias = write.rowAlias, let table = scope.sources.first {
            var source = table
            source.name = alias.value
            source.symbol = SQLSymbol(kind: .tableAlias, name: alias.value, declaration: alias.range)
            reference(alias.range, source.symbol!, isDeclaration: true)
            if !write.rowAliasColumns.isEmpty {
                source.columns = write.rowAliasColumns.map {
                    let symbol = SQLSymbol(kind: .selectAlias, name: $0.value, declaration: $0.range)
                    reference($0.range, symbol, isDeclaration: true)
                    return SQLColumnInfo(name: $0.value, symbol: symbol)
                }
                source.complete = true
            }
            conflict.sources.append(source)
        }
        for assignment in write.assignments {
            resolveTarget(assignment.column, scope)
            resolve(assignment.value, scope)
        }
        for assignment in write.onDuplicate {
            resolveTarget(assignment.column, scope)
            resolve(assignment.value, conflict)
        }
        if let condition = write.whereClause { resolve(condition, scope) }
        for item in write.orderBy { resolve(item.expr, scope) }
        for value in write.limit { resolve(value, scope) }
        for item in write.returning { resolve(item.expr, scope) }
    }

    /// The left of an assignment.
    private mutating func resolveTarget(_ column: SQLName, _ scope: SQLScope) {
        resolve(SQLExpr(kind: .column, range: column.range, name: column), scope)
    }

    // MARK: Queries

    /// Resolves `query` under `parent` and returns what it outputs.
    mutating func visit(_ query: SQLQuery, _ parent: SQLScope) -> (columns: [SQLColumnInfo], complete: Bool) {
        if query.extent.upperBound >= statementEnd.written { query.extent = query.extent.lowerBound..<statementEnd.extended }
        let shell = newScope(parent, query.extent)
        result.scopes.append(shell)
        declare(query.ctes, in: shell, recursive: query.recursive)
        var outputs: (columns: [SQLColumnInfo], complete: Bool) = ([], false)
        for (index, block) in query.blocks.enumerated() {
            let last = index == query.blocks.count - 1
            let start = index == 0 ? query.extent.lowerBound : block.range.lowerBound
            let end = last ? query.extent.upperBound : block.range.upperBound
            let found = visit(block, shell, max(start, 0)..<max(start, end))
            if index == 0 { outputs = found }
        }
        // A union's own ORDER BY reads its output's names.
        if !query.orderBy.isEmpty || !query.limit.isEmpty {
            let scope = newScope(shell, query.extent)
            scope.outputs = outputs.columns
            scope.open = true
            for item in query.orderBy { resolve(item.expr, scope, aliases: true) }
            for value in query.limit { resolve(value, scope) }
        }
        return outputs
    }

    private mutating func visit(_ block: SQLSelect, _ parent: SQLScope, _ extent: Range<Int>) -> (columns: [SQLColumnInfo], complete: Bool) {
        if let nested = block.nested {
            let found = visit(nested, parent)
            let scope = newScope(parent, nested.range)
            scope.outputs = found.columns
            scope.open = true
            for item in block.orderBy { resolve(item.expr, scope, aliases: true) }
            return found
        }
        let scope = newScope(parent, extent)
        scope.clauses = block.clauses
        result.scopes.append(scope)
        if let table = block.table { addSources([table], scope) }
        addSources(block.from, scope)
        for row in block.rows {
            for value in row { resolve(value, scope) }
        }
        var outputs: [SQLColumnInfo] = [], complete = block.rows.isEmpty
        for item in block.items {
            resolve(item.expr, scope)
            if case .star = item.expr.kind {
                let qualifier = item.expr.name?.last.value
                let chosen = scope.sources.filter { source in qualifier.map { source.name.caseInsensitiveCompare($0) == .orderedSame } ?? true }
                for source in chosen {
                    outputs += source.columns.filter { $0.schema?.invisible != true }
                    complete = complete && source.complete
                }
                if chosen.isEmpty { complete = false }
            } else {
                outputs.append(output(of: item))
            }
        }
        scope.outputs = outputs
        if let condition = block.whereClause { resolve(condition, scope) }
        for value in block.groupBy { resolve(value, scope, aliases: true) }
        if let having = block.having { resolve(having, scope, aliases: true) }
        for value in block.windows { resolve(value, scope) }
        for item in block.orderBy { resolve(item.expr, scope, aliases: true) }
        for value in block.limit { resolve(value, scope) }
        return (outputs, complete)
    }

    /// A select item as a column of what its query outputs.
    private mutating func output(of item: SQLSelectItem) -> SQLColumnInfo {
        if let alias = item.alias {
            let symbol = SQLSymbol(kind: .selectAlias, name: alias.value, declaration: alias.range)
            reference(alias.range, symbol, isDeclaration: true)
            var info = SQLColumnInfo(name: alias.value, symbol: symbol)
            if case .column = item.expr.kind, let found = columnInfo[item.expr.range.lowerBound] {
                info.type = found.type
                info.schema = found.schema
            }
            return info
        }
        if case .column = item.expr.kind, let name = item.expr.name {
            if let found = columnInfo[item.expr.range.lowerBound] { return found }
            return SQLColumnInfo(name: name.last.value, symbol: SQLSymbol(kind: .selectAlias, name: name.last.value, declaration: name.last.range))
        }
        let text = string(item.expr.range)
        return SQLColumnInfo(name: text, symbol: SQLSymbol(kind: .selectAlias, name: text, declaration: item.expr.range))
    }

    private mutating func declare(_ ctes: [SQLCTE], in scope: SQLScope, recursive: Bool = false) {
        for cte in ctes {
            let symbol = SQLSymbol(kind: .cte, name: cte.name.value, declaration: cte.name.range)
            reference(cte.name.range, symbol, isDeclaration: true)
            var source = SQLRowSource(kind: .cte, name: cte.name.value, objectName: cte.name.value, range: cte.range, symbol: symbol)
            source.columns = cte.columns.map {
                let symbol = SQLSymbol(kind: .selectAlias, name: $0.value, declaration: $0.range)
                reference($0.range, symbol, isDeclaration: true)
                return SQLColumnInfo(name: $0.value, symbol: symbol)
            }
            source.complete = !cte.columns.isEmpty
            if recursive {
                // Its own name is visible inside it; until its columns are known, only what it declares.
                scope.ctes.append(source)
                let found = visit(cte.query, scope)
                scope.ctes.removeLast()
                if cte.columns.isEmpty {
                    source.columns = found.columns
                    source.complete = found.complete
                }
            } else {
                let found = visit(cte.query, scope)
                if cte.columns.isEmpty {
                    source.columns = found.columns
                    source.complete = found.complete
                }
            }
            scope.ctes.append(source)
        }
    }

    private mutating func addSources(_ tables: [SQLTableRef], _ scope: SQLScope) {
        for ref in tables {
            scope.sources.append(source(ref, scope))
        }
        // Joins read what's in the scope, whichever side a column is on.
        for (index, ref) in tables.enumerated() {
            guard let join = ref.join else { continue }
            for column in join.using {
                scope.merged.insert(column.value.lowercased())
                let sides = Array(scope.sources[0...index])
                if sides.allSatisfy(\.complete), let symbol = sides.lazy.compactMap({ $0.has(column.value)?.symbol }).first {
                    reference(column.range, symbol)
                }
            }
            if join.natural {
                for column in scope.sources[index].columns where scope.sources[0..<index].contains(where: { $0.has(column.name) != nil }) {
                    scope.merged.insert(column.name.lowercased())
                }
            }
            if let condition = join.on { resolve(condition, scope) }
        }
        for ref in tables {
            for expr in ref.expressions { resolve(expr, scope) }
        }
    }

    private mutating func source(_ ref: SQLTableRef, _ scope: SQLScope) -> SQLRowSource {
        var source: SQLRowSource
        switch ref.kind {
        case .opaque:
            source = SQLRowSource(kind: .opaque, name: ref.alias?.value ?? "", range: ref.range)
        case .derived:
            source = SQLRowSource(kind: .derived, name: ref.alias?.value ?? "", range: ref.range)
            let found = visit(ref.query!, ref.lateral ? scope : scope.parent ?? scope)
            source.columns = found.columns
            source.complete = found.complete
            if !ref.columnAliases.isEmpty {
                source.columns = ref.columnAliases.map {
                    let symbol = SQLSymbol(kind: .selectAlias, name: $0.value, declaration: $0.range)
                    reference($0.range, symbol, isDeclaration: true)
                    return SQLColumnInfo(name: $0.value, symbol: symbol)
                }
                source.complete = true
            }
        case .table:
            source = table(ref.name!, ref, scope)
        }
        if let alias = ref.alias {
            let symbol = SQLSymbol(kind: .tableAlias, name: alias.value, declaration: alias.range)
            source.name = alias.value
            source.symbol = symbol
            reference(alias.range, symbol, isDeclaration: true)
        }
        return source
    }

    private mutating func table(_ name: SQLName, _ ref: SQLTableRef, _ scope: SQLScope) -> SQLRowSource {
        let written = name.last.value
        if name.parts.count == 1, let cte = scope.cte(written) {
            reference(name.last.range, cte.symbol!)
            var source = cte
            source.range = ref.range
            return source
        }
        let place = name.qualifier?.value ?? database
        if let qualifier = name.qualifier { reference(qualifier.range, SQLSymbol(kind: .database, name: qualifier.value)) }
        let symbol = SQLSymbol(kind: .table, name: schemaName(place, written), database: place.flatMap { snapshot?.database($0)?.name ?? $0 })
        reference(name.last.range, symbol)
        var source = SQLRowSource(kind: .table, name: written, objectName: symbol.name, database: symbol.database, range: ref.range, symbol: symbol)
        guard let place, let found = snapshot?.database(place) else { return source }
        source.table = snapshot?.table(place, written)
        if let table = source.table {
            source.columns = table.columns.map {
                SQLColumnInfo(name: $0.name, type: $0.columnType, schema: $0,
                              symbol: SQLSymbol(kind: .column, name: $0.name, database: found.name, table: table.name))
            }
        }
        // What can't be trusted to be complete: temporary and new tables, system schemas, the Sequence engine's tables.
        let lower = written.lowercased()
        guard found.detailsLoaded, !["information_schema", "performance_schema"].contains(found.name.lowercased()), Self.isASCII(written),
              !changed.contains(lower), lower != "dual", !(snapshot?.server?.flavour == .mariadb && written.hasPrefix("seq_"))
        else { return source }
        if let table = source.table {
            source.complete = !table.columns.isEmpty
        } else {
            issue(.unknownTable(database: found.name), name.last.range, written, candidates: found.tables.map(\.name))
        }
        return source
    }

    /// The server's collations fold accents and other scripts in ways a plain comparison doesn't.
    static func isASCII(_ name: String) -> Bool { name.utf16.allSatisfy { $0 < 128 } }

    // MARK: Expressions

    /// Words that aren't columns: keywords, functions that need no brackets, and columns no list shows.
    static let notColumns: Set<String> = SQLWords.reserved.union(SQLCompletion.keywords).union(SQLFunction.all.map { $0.name.uppercased() })
        .union(["TRUE", "FALSE", "UNKNOWN", "SQL_CACHE", "SQL_NO_CACHE", "SQL_BUFFER_RESULT", "QUICK", "ROWNUM", "SYSDATE",
                "_ROWID", "MY_ROW_ID", "ROW_START", "ROW_END", "NEXT", "PREVIOUS", "LASTVAL", "NEXTVAL", "CURRENT_ROLE", "USER"])

    mutating func resolve(_ expr: SQLExpr, _ scope: SQLScope, aliases: Bool = false) {
        switch expr.kind {
        case .column:
            if let name = expr.name { resolve(column: name, scope, aliases: aliases) }
        case .star:
            if let name = expr.name, let qualifier = name.parts.last { resolve(qualifier: qualifier, scope) }
        case .call:
            if let name = expr.name, name.parts.count > 1 || !isBuiltIn(name.last.value) { routine(name, known: false) }
        default:
            break
        }
        for child in expr.children { resolve(child, scope, aliases: aliases) }
        for child in expr.extra { resolve(child, scope, aliases: aliases) }
        if let query = expr.query { _ = visit(query, scope) }
    }

    private func isBuiltIn(_ name: String) -> Bool {
        let upper = name.uppercased()
        return SQLWords.readOnlyFunctions.contains(upper) || Self.notColumns.contains(upper)
    }

    /// `name.`: its source in this or an outer scope.
    @discardableResult private mutating func resolve(qualifier: SQLIdentifier, _ scope: SQLScope) -> SQLRowSource? {
        var current: SQLScope? = scope, open = false, seen: [String] = []
        while let here = current {
            if let found = here.sources.first(where: { $0.name.caseInsensitiveCompare(qualifier.value) == .orderedSame }) {
                if let symbol = found.symbol { reference(qualifier.range, symbol) }
                return found
            }
            open = open || here.open || here.sources.contains { $0.kind == .opaque }
            seen += here.sources.map(\.name)
            current = here.parent
        }
        if !open, !seen.isEmpty, Self.isASCII(qualifier.value) { issue(.unknownQualifier, qualifier.range, qualifier.value, candidates: seen) }
        return nil
    }

    private mutating func resolve(column name: SQLName, _ scope: SQLScope, aliases: Bool) {
        let column = name.last
        switch name.parts.count {
        case 1:
            resolveBare(column, scope, aliases: aliases)
        case 2:
            // Sequences read as s.nextval in Oracle mode.
            guard !["NEXTVAL", "CURRVAL"].contains(column.value.uppercased()) else { return }
            guard let source = resolve(qualifier: name.qualifier!, scope) else { return }
            resolveColumn(column.value, column.range, in: [source], scope, canSayWhich: true)
        default:
            let table = name.qualifier!.value, place = name.parts[name.parts.count - 3].value
            reference(name.parts[name.parts.count - 3].range, SQLSymbol(kind: .database, name: place))
            let sources = scope.visibleSources.filter {
                $0.kind == .table && $0.objectName?.caseInsensitiveCompare(table) == .orderedSame && $0.database?.caseInsensitiveCompare(place) == .orderedSame
            }
            guard !sources.isEmpty else { return }
            if let symbol = sources[0].symbol, symbol.kind == .table { reference(name.qualifier!.range, symbol) }
            resolveColumn(column.value, column.range, in: [sources[0]], scope, canSayWhich: true)
        }
    }

    private mutating func resolveColumn(_ name: String, _ range: Range<Int>, in sources: [SQLRowSource], _ scope: SQLScope, canSayWhich: Bool) {
        if let found = sources.lazy.compactMap({ $0.has(name) }).first {
            reference(range, found.symbol)
            columnInfo[range.lowerBound] = found
        } else if sources.allSatisfy(\.complete), Self.isASCII(name) {
            issue(.unknownColumn(place: "“\(sources[0].objectName ?? sources[0].name)”"), range, name, candidates: sources.flatMap(\.columns).map(\.name),
                  table: sources.count == 1 ? sources[0] : nil)
        }
    }

    private mutating func resolveBare(_ column: SQLIdentifier, _ scope: SQLScope, aliases: Bool) {
        var current: SQLScope? = scope, open = false, sourcesSeen: [SQLRowSource] = []
        var first = true
        while let here = current {
            if aliases, first, let found = here.outputs.first(where: { $0.name.caseInsensitiveCompare(column.value) == .orderedSame }) {
                reference(column.range, found.symbol)
                columnInfo[column.range.lowerBound] = found
                return
            }
            first = false
            let matches = here.sources.filter { $0.has(column.value) != nil }
            if matches.count > 1, !here.merged.contains(column.value.lowercased()) {
                issue(.ambiguous(sources: matches.map(\.name)), column.range, column.value)
                return
            }
            if let match = matches.first, let found = match.has(column.value) {
                reference(column.range, found.symbol)
                columnInfo[column.range.lowerBound] = found
                return
            }
            open = open || here.open || here.sources.contains { !$0.complete }
            sourcesSeen += here.sources
            current = here.parent
        }
        guard !open, !sourcesSeen.isEmpty, Self.isASCII(column.value), column.quoted || !Self.notColumns.contains(column.value.uppercased()) else { return }
        let place = sourcesSeen.count == 1 ? "“\(sourcesSeen[0].objectName ?? sourcesSeen[0].name)”" : "the tables this statement uses"
        issue(.unknownColumn(place: place), column.range, column.value, candidates: sourcesSeen.flatMap(\.columns).map(\.name),
              table: sourcesSeen.count == 1 ? sourcesSeen[0] : nil)
    }

    /// What each resolved column in the text is, by where it starts: what an item's output takes from.
    var columnInfo: [Int: SQLColumnInfo] = [:]
}
