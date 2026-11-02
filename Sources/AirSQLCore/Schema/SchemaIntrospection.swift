import Foundation

/// Which rows an introspection query reads: every database (`databases(nil)`), some databases, or named objects
/// (tables, routines, triggers or events) in one database.
enum SchemaScope: Equatable {
    case databases([String]?)
    case objects(database: String, names: [String])
}

/// A table of a database: the key of details read across databases.
struct TableKey: Hashable {
    var database: String
    var table: String
}

/// The details of one table, as the detail queries read them.
struct TableDetails: Equatable {
    var columns: [SchemaColumn] = []
    var indexes: [SchemaIndex] = []
    var foreignKeys: [SchemaForeignKey] = []
    var checks: [SchemaCheck] = []
}

/// The introspection SQL for one server, and the parsers of what it returns.
///
/// Only information_schema, so a user sees what their privileges allow. MariaDB and MySQL 5.7 fill information_schema
/// by reading every table's definition, and for some columns by opening the table itself (`EXPLAIN` says
/// Open_full_table): table statistics, CARDINALITY, foreign keys and checks. So the names-first queries use only
/// columns that don't open tables, CARDINALITY is never read, and statistics are read for one database at a time. A
/// query that names one database (`= 'db'`), or one database and some tables, reads only those on MariaDB; a query
/// that joins two such tables reads the second one in full, so foreign keys and their rules are two queries, joined
/// here (as MySQL's checks and their tables are: joining those views is slow on MySQL 8).
struct SchemaIntrospection {
    let server: SchemaServer

    static let serverSQL = "SELECT VERSION(), @@lower_case_table_names, @@SESSION.sql_mode"

    // MARK: Names

    func databasesSQL(_ names: [String]?) -> String {
        "SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA"
            + filter(.databases(names), schema: "SCHEMA_NAME", name: "SCHEMA_NAME")
    }

    /// TABLE_TYPE, ENGINE and TABLE_COMMENT come from the table's definition only (MariaDB: Open_frm_only).
    func tablesSQL(_ scope: SchemaScope) -> String {
        "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_COMMENT FROM information_schema.TABLES"
            + filter(scope, schema: "TABLE_SCHEMA", name: "TABLE_NAME")
    }

    func routinesSQL(_ scope: SchemaScope) -> String {
        "SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE, DTD_IDENTIFIER, ROUTINE_COMMENT "
            + "FROM information_schema.ROUTINES" + filter(scope, schema: "ROUTINE_SCHEMA", name: "ROUTINE_NAME")
    }

    /// The scope's names are trigger names, or with `byTable` the tables they belong to.
    func triggersSQL(_ scope: SchemaScope, byTable: Bool = false) -> String {
        "SELECT TRIGGER_SCHEMA, TRIGGER_NAME, EVENT_OBJECT_TABLE, ACTION_TIMING, EVENT_MANIPULATION, ACTION_ORDER "
            + "FROM information_schema.TRIGGERS"
            + filter(scope, schema: "TRIGGER_SCHEMA", name: byTable ? "EVENT_OBJECT_TABLE" : "TRIGGER_NAME")
    }

    func eventsSQL(_ scope: SchemaScope) -> String {
        "SELECT EVENT_SCHEMA, EVENT_NAME, STATUS, EVENT_COMMENT FROM information_schema.EVENTS"
            + filter(scope, schema: "EVENT_SCHEMA", name: "EVENT_NAME")
    }

    // MARK: Details

    func columnsSQL(_ scope: SchemaScope) -> String {
        "SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, DATA_TYPE, COLUMN_TYPE, IS_NULLABLE, "
            + "COLUMN_DEFAULT, EXTRA, GENERATION_EXPRESSION, CHARACTER_SET_NAME, COLLATION_NAME, COLUMN_COMMENT "
            + "FROM information_schema.COLUMNS" + filter(scope, schema: "TABLE_SCHEMA", name: "TABLE_NAME")
    }

    /// Without CARDINALITY, which opens every table on MariaDB.
    func indexesSQL(_ scope: SchemaScope) -> String {
        let visible: String, expression: String
        switch server.flavour {
        case .mysql:
            visible = server.atLeast(8) ? "IS_VISIBLE" : "'YES'"
            expression = server.atLeast(8, 0, 13) ? "EXPRESSION" : "NULL"
        case .mariadb:
            visible = server.atLeast(10, 6) ? "IF(IGNORED = 'YES', 'NO', 'YES')" : "'YES'"
            expression = "NULL"
        }
        return "SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, SUB_PART, "
            + "COLLATION, INDEX_TYPE, INDEX_COMMENT, \(visible), \(expression) FROM information_schema.STATISTICS"
            + filter(scope, schema: "TABLE_SCHEMA", name: "TABLE_NAME")
    }

    func foreignKeysSQL(_ scope: SchemaScope) -> String {
        "SELECT TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, COLUMN_NAME, ORDINAL_POSITION, REFERENCED_TABLE_SCHEMA, "
            + "REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE "
            + "WHERE REFERENCED_TABLE_NAME IS NOT NULL"
            + filter(scope, schema: "TABLE_SCHEMA", name: "TABLE_NAME", joiner: "AND")
    }

    func foreignKeyRulesSQL(_ scope: SchemaScope) -> String {
        "SELECT CONSTRAINT_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, UPDATE_RULE, DELETE_RULE "
            + "FROM information_schema.REFERENTIAL_CONSTRAINTS"
            + filter(scope, schema: "CONSTRAINT_SCHEMA", name: "TABLE_NAME")
    }

    /// The statements that read check constraints (`checks(_:)` reads what they return): none on MySQL before 8.0.16,
    /// which parses CHECK and ignores it. MySQL's check view has no table name (check names are unique per database),
    /// so the tables come from TABLE_CONSTRAINTS, read on its own: joining the two views rebuilds TABLE_CONSTRAINTS for
    /// every row, which took 30 s to 2 min on MySQL 8.4 for a database of 4,400 checks.
    func checksSQL(_ scope: SchemaScope) -> [String] {
        switch server.flavour {
        case .mysql:
            guard server.atLeast(8, 0, 16) else { return [] }
            var database = scope
            if case .objects(let name, _) = scope { database = .databases([name]) }
            return ["SELECT CONSTRAINT_SCHEMA, CONSTRAINT_NAME, CHECK_CLAUSE FROM information_schema.CHECK_CONSTRAINTS"
                        + filter(database, schema: "CONSTRAINT_SCHEMA", name: "CONSTRAINT_NAME"),
                    "SELECT TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, ENFORCED "
                        + "FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_TYPE = 'CHECK'"
                        + filter(scope, schema: "TABLE_SCHEMA", name: "TABLE_NAME", joiner: "AND")]
        case .mariadb:
            return ["SELECT CONSTRAINT_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, CHECK_CLAUSE, 'YES' "
                        + "FROM information_schema.CHECK_CONSTRAINTS"
                        + filter(scope, schema: "CONSTRAINT_SCHEMA", name: "TABLE_NAME")]
        }
    }

    // MARK: Statistics

    /// MySQL 8 caches table statistics in information_schema for a day (`information_schema_stats_expiry`), so a
    /// database view would show yesterday's row counts; the schema session reads them fresh. (The variable can't be
    /// set with a SET_VAR hint.)
    var statisticsSetupSQL: String? {
        server.flavour == .mysql && server.atLeast(8, 0, 3) ? "SET SESSION information_schema_stats_expiry = 0" : nil
    }

    /// Opens every table it names (MariaDB, MySQL 5.7: Open_full_table), so one database at a time.
    func statisticsSQL(_ database: String, tables: [String]? = nil) -> String {
        "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, DATA_FREE, AUTO_INCREMENT, "
            + "CREATE_TIME, UPDATE_TIME, TABLE_COLLATION, ROW_FORMAT, CREATE_OPTIONS FROM information_schema.TABLES"
            + filter(tables.map { .objects(database: database, names: $0) } ?? .databases([database]),
                     schema: "TABLE_SCHEMA", name: "TABLE_NAME")
    }

    // MARK: SQL text

    /// A WHERE clause (or its continuation) for a scope; `schema` and `name` are the columns with the database and the
    /// object name. One value is compared with `=`, which MariaDB uses to read only that database or table.
    private func filter(_ scope: SchemaScope, schema: String, name: String, joiner: String = "WHERE") -> String {
        switch scope {
        case .databases(nil): return ""
        case .databases(let names?): return " \(joiner) \(schema)\(oneOf(names))"
        case .objects(let database, let names):
            return " \(joiner) \(schema) = \(literal(database)) AND \(name)\(oneOf(names))"
        }
    }

    private func oneOf(_ values: [String]) -> String {
        if values.count == 1 { return " = " + literal(values[0]) }
        return " IN (" + (values.isEmpty ? "NULL" : values.map(literal).joined(separator: ", ")) + ")"
    }

    /// A name as a string literal: quotes doubled, and backslashes doubled unless the session has NO_BACKSLASH_ESCAPES.
    func literal(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "'", with: "''")
        if !server.noBackslashEscapes { text = text.replacingOccurrences(of: "\\", with: "\\\\") }
        return "'" + text + "'"
    }

    // MARK: Parsing

    static func server(_ rows: [[String?]]) -> SchemaServer? {
        guard let row = rows.first, let version = row.at(0) else { return nil }
        return SchemaServer(version: version, lowerCaseTableNames: row.at(1).flatMap { Int($0) } ?? 0,
                            sqlMode: row.at(2) ?? "")
    }

    static func databases(_ rows: [[String?]]) -> [SchemaDatabase] {
        rows.compactMap { row in
            guard let name = row.at(0) else { return nil }
            return SchemaDatabase(name: name, charset: row.at(1) ?? "", collation: row.at(2) ?? "")
        }
    }

    static func tables(_ rows: [[String?]]) -> [String: [SchemaTable]] {
        var result: [String: [SchemaTable]] = [:]
        for row in rows {
            guard let database = row.at(0), let name = row.at(1) else { continue }
            let kind: SchemaTable.Kind
            switch row.at(2) {
            case "BASE TABLE", "SYSTEM VERSIONED": kind = .table
            case "VIEW", "SYSTEM VIEW": kind = .view
            case "SEQUENCE": kind = .sequence
            default: continue // a session's temporary tables (MariaDB 11.2+)
            }
            // A view's comment is "VIEW", or on MariaDB the error that a broken view gives.
            var table = SchemaTable(name: name, kind: kind, engine: kind == .view ? nil : row.at(3),
                                    comment: kind == .view ? "" : row.at(4) ?? "")
            table.systemVersioned = row.at(2) == "SYSTEM VERSIONED"
            result[database, default: []].append(table)
        }
        return result
    }

    static func routines(_ rows: [[String?]]) -> [String: [SchemaRoutine]] {
        var result: [String: [SchemaRoutine]] = [:]
        for row in rows {
            // MariaDB's Oracle-mode packages aren't listed.
            guard let database = row.at(0), let name = row.at(1),
                  let kind = SchemaRoutine.Kind(rawValue: row.at(2)?.lowercased() ?? "") else { continue }
            let returns = kind == .function ? row.at(3) : nil
            result[database, default: []].append(
                SchemaRoutine(name: name, kind: kind, returns: returns, comment: row.at(4) ?? ""))
        }
        return result
    }

    static func triggers(_ rows: [[String?]]) -> [String: [SchemaTrigger]] {
        var result: [String: [SchemaTrigger]] = [:]
        for row in rows {
            guard let database = row.at(0), let name = row.at(1), let table = row.at(2) else { continue }
            result[database, default: []].append(
                SchemaTrigger(name: name, table: table, timing: row.at(3) ?? "", event: row.at(4) ?? "",
                              order: row.at(5).flatMap { Int($0) } ?? 1))
        }
        return result
    }

    static func events(_ rows: [[String?]]) -> [String: [SchemaEvent]] {
        var result: [String: [SchemaEvent]] = [:]
        for row in rows {
            guard let database = row.at(0), let name = row.at(1) else { continue }
            result[database, default: []].append(
                SchemaEvent(name: name, status: row.at(2) ?? "", comment: row.at(3) ?? ""))
        }
        return result
    }

    /// Check rows (database, table, name, clause, enforced) from what the `checksSQL` statements returned.
    static func checks(_ results: [[[String?]]]) -> [[String?]] {
        guard results.count == 2 else { return results.first ?? [] } // MariaDB's has them all
        var clauses: [String: String?] = [:]
        for row in results[0] {
            if let database = row.at(0), let name = row.at(1) { clauses[database + "\u{0}" + name] = row.at(2) }
        }
        return results[1].compactMap { row in
            guard let database = row.at(0), let name = row.at(2), let clause = clauses[database + "\u{0}" + name] else {
                return nil
            }
            return [database, row.at(1), name, clause, row.at(3)]
        }
    }

    /// Details by table from the rows of the column, index, foreign key, foreign key rule and check queries.
    func details(columns: [[String?]], indexes: [[String?]], foreignKeys: [[String?]], foreignKeyRules: [[String?]],
                 checks: [[String?]]) -> [TableKey: TableDetails] {
        var result: [TableKey: TableDetails] = [:]
        var positions: [TableKey: [(Int, SchemaColumn)]] = [:]
        for row in columns {
            guard let key = Self.key(row), let column = column(row) else { continue }
            positions[key, default: []].append((row.at(3).flatMap { Int($0) } ?? 0, column))
        }
        for (key, columns) in positions {
            result[key, default: TableDetails()].columns = columns.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var parts: [TableKey: [String: [(Int, SchemaIndex.Part)]]] = [:]
        var indexInfo: [TableKey: [String: SchemaIndex]] = [:]
        for row in indexes {
            guard let key = Self.key(row), let name = row.at(2) else { continue }
            let part = SchemaIndex.Part(column: row.at(5), expression: row.at(11).map(unescapedExpression),
                                        prefixLength: row.at(6).flatMap { Int($0) }, descending: row.at(7) == "D")
            parts[key, default: [:]][name, default: []].append((row.at(4).flatMap { Int($0) } ?? 0, part))
            if indexInfo[key]?[name] == nil {
                indexInfo[key, default: [:]][name] = SchemaIndex(
                    name: name, unique: row.at(3) == "0", type: row.at(8) ?? "", parts: [],
                    visible: row.at(10) != "NO", comment: row.at(9) ?? "")
            }
        }
        for (key, indexes) in indexInfo {
            result[key, default: TableDetails()].indexes = indexes.values.map { index in
                var index = index
                index.parts = (parts[key]?[index.name] ?? []).sorted { $0.0 < $1.0 }.map(\.1)
                return index
            }.sorted { $0.name < $1.name }
        }

        var rules: [TableKey: [String: (String, String)]] = [:]
        for row in foreignKeyRules {
            guard let key = Self.key(row), let name = row.at(2) else { continue }
            rules[key, default: [:]][name] = (row.at(3) ?? "RESTRICT", row.at(4) ?? "RESTRICT")
        }
        var keyColumns: [TableKey: [String: [(Int, String, String)]]] = [:]
        var references: [TableKey: [String: (String, String)]] = [:]
        for row in foreignKeys {
            guard let key = Self.key(row), let name = row.at(2), let column = row.at(3),
                  let database = row.at(5), let table = row.at(6) else { continue }
            keyColumns[key, default: [:]][name, default: []].append(
                (row.at(4).flatMap { Int($0) } ?? 0, column, row.at(7) ?? ""))
            references[key, default: [:]][name] = (database, table)
        }
        for (key, keys) in keyColumns {
            result[key, default: TableDetails()].foreignKeys = keys.map { name, columns in
                let columns = columns.sorted { $0.0 < $1.0 }
                let (database, table) = references[key]?[name] ?? ("", "")
                let (onUpdate, onDelete) = rules[key]?[name] ?? ("RESTRICT", "RESTRICT")
                return SchemaForeignKey(name: name, columns: columns.map(\.1), referencedDatabase: database,
                                        referencedTable: table, referencedColumns: columns.map(\.2),
                                        onUpdate: onUpdate, onDelete: onDelete)
            }.sorted { $0.name < $1.name }
        }

        for row in checks {
            guard let key = Self.key(row), let name = row.at(2), let clause = row.at(3) else { continue }
            result[key, default: TableDetails()].checks.append(
                SchemaCheck(name: name, clause: unescapedExpression(clause), enforced: row.at(4) != "NO"))
        }
        for key in result.keys {
            result[key]?.checks.sort { $0.name < $1.name }
            if server.flavour == .mariadb, let checks = result[key]?.checks, !checks.isEmpty {
                markJSON(&result[key]!.columns, checks: checks)
            }
        }
        return result
    }

    /// Statistics by table name, for the tables of `database`.
    static func statistics(_ rows: [[String?]], database: String) -> [String: TableStatistics] {
        var result: [String: TableStatistics] = [:]
        for row in rows where row.at(0) == database {
            guard let name = row.at(1) else { continue }
            result[name] = TableStatistics(
                rows: row.at(2).flatMap { Int($0) }, dataLength: row.at(3).flatMap { Int($0) },
                indexLength: row.at(4).flatMap { Int($0) }, dataFree: row.at(5).flatMap { Int($0) },
                autoIncrement: row.at(6).flatMap { UInt64($0) }, createTime: row.at(7), updateTime: row.at(8),
                collation: row.at(9), rowFormat: row.at(10), createOptions: row.at(11))
        }
        return result
    }

    /// The database and table in a row's first two values.
    static func key(_ row: [String?]) -> TableKey? {
        guard let database = row.at(0), let table = row.at(1) else { return nil }
        return TableKey(database: database, table: table)
    }

    // MARK: Columns

    func column(_ row: [String?]) -> SchemaColumn? {
        guard let name = row.at(2) else { return nil }
        let dataType = row.at(4) ?? "", nullable = row.at(6) == "YES", extra = row.at(8) ?? ""
        let words = extra.lowercased().split { $0 == " " || $0 == "," }
        var generated: SchemaColumn.Generated?
        if let expression = row.at(9), !expression.isEmpty { // MySQL: "" for other columns, MariaDB: NULL
            generated = .init(expression: unescapedExpression(expression),
                              stored: words.contains("stored") || words.contains("persistent"))
        }
        var onUpdate: String?
        if let range = extra.range(of: "on update ", options: .caseInsensitive) {
            onUpdate = extra[range.upperBound...].split { $0 == " " || $0 == "," }.first.map(String.init)
        }
        let defaultValue = generated == nil
            ? columnDefault(row.at(7), dataType: dataType, nullable: nullable, extra: extra) : .none
        return SchemaColumn(
            name: name, dataType: dataType, columnType: row.at(5) ?? dataType, nullable: nullable,
            defaultValue: defaultValue,
            autoIncrement: words.contains("auto_increment"), onUpdate: onUpdate, generated: generated,
            invisible: words.contains("invisible"), isJSON: dataType.lowercased() == "json",
            charset: row.at(10), collation: row.at(11), comment: row.at(12) ?? "")
    }

    /// A column's default from COLUMN_DEFAULT, which MySQL and MariaDB show differently.
    func columnDefault(_ raw: String?, dataType: String, nullable: Bool, extra: String) -> SchemaDefault {
        let type = dataType.lowercased()
        switch server.flavour {
        case .mariadb:
            // NULL for no default, "NULL" for DEFAULT NULL, strings and dates quoted, numbers bare, other SQL as is
            // (current_timestamp(), uuid(), b'101', x'6162').
            guard let raw else { return .none }
            if raw == "NULL" { return .null }
            if let text = Self.unquoted(raw) { return .value(text) }
            return Self.isNumber(raw) ? .value(raw) : .expression(raw)
        case .mysql:
            // NULL for both no default and DEFAULT NULL; constants as their bare text; expressions (8.0.13+) marked
            // DEFAULT_GENERATED, except bits (b'101'), binary strings in 8.0 (0x6162) and, in 5.7, CURRENT_TIMESTAMP.
            guard let raw else { return nullable ? .null : .none }
            if extra.range(of: "DEFAULT_GENERATED", options: .caseInsensitive) != nil {
                return .expression(unescapedExpression(raw))
            }
            if (type == "timestamp" || type == "datetime") && raw.uppercased().hasPrefix("CURRENT_TIMESTAMP")
                || type == "bit" && raw.hasPrefix("b'")
                || (type == "binary" || type == "varbinary") && raw.hasPrefix("0x") && server.atLeast(8) {
                return .expression(raw)
            }
            return .value(raw)
        }
    }

    /// MariaDB's JSON is LONGTEXT with a `json_valid(`column`)` check (the column's own check, possibly with more).
    private func markJSON(_ columns: inout [SchemaColumn], checks: [SchemaCheck]) {
        for index in columns.indices where columns[index].dataType.lowercased() == "longtext" {
            let call = "json_valid(`" + columns[index].name.replacingOccurrences(of: "`", with: "``") + "`)"
            columns[index].isJSON = checks.contains { $0.clause.range(of: call, options: .caseInsensitive) != nil }
        }
    }

    /// MySQL 8 shows expressions (generated columns, expression defaults, checks, functional key parts) escaped once
    /// more than SHOW CREATE TABLE does: `_utf8mb4\'a\'` for `_utf8mb4'a'`. Undo that; other servers show plain SQL.
    func unescapedExpression(_ text: String) -> String {
        guard server.flavour == .mysql, server.atLeast(8), text.contains("\\") else { return text }
        var result = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\\", let escaped = scalars.next() else {
                result.append(scalar)
                continue
            }
            result.append(Self.unescaped(escaped))
        }
        return String(result)
    }

    /// The text of `raw` when it is one single-quoted SQL string (MariaDB's defaults: `'it''s'`, `'C:\\tmp'`), else
    /// nil.
    static func unquoted(_ raw: String) -> String? {
        let scalars = Array(raw.unicodeScalars)
        guard scalars.count >= 2, scalars[0] == "'" else { return nil }
        var text = String.UnicodeScalarView()
        var index = 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\", index + 1 < scalars.count {
                text.append(unescaped(scalars[index + 1]))
                index += 2
            } else if scalar == "'" {
                if index + 1 < scalars.count, scalars[index + 1] == "'" {
                    text.append("'")
                    index += 2
                } else {
                    return index == scalars.count - 1 ? String(text) : nil
                }
            } else {
                text.append(scalar)
                index += 1
            }
        }
        return nil
    }

    /// What a backslash escape in a string literal stands for.
    private static func unescaped(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar {
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "0": return "\0"
        case "b": return "\u{8}"
        case "Z": return "\u{1A}"
        default: return scalar
        }
    }

    static func isNumber(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { "0123456789+-.eE".contains($0) } && Double(text) != nil
    }
}

fileprivate extension Array where Element == String? {
    /// The value at `index`, or nil past the end.
    func at(_ index: Int) -> String? { indices.contains(index) ? self[index] : nil }
}
