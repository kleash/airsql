import Foundation
import Testing
@testable import AirSQLCore

/// Compare and reconcile without a server: normalisation across flavours, structure differences, SHOW CREATE TABLE
/// lines, the sync script's order and destructive steps, the hashing SQL, literals, value comparison and matching.
struct ReconTests {
    /// The recorded fixture schema (SchemaFixtures.swift) of a server, details and statistics loaded.
    static func fixture(_ recording: String) async throws -> (SchemaServer, SchemaDatabase) {
        let cache = SchemaCache(source: ReplaySource(recording))
        try await cache.load()
        try await cache.loadStatistics("airsql_fixture")
        let snapshot = cache.snapshot
        return (try #require(snapshot.server), try #require(snapshot.database("airsql_fixture")))
    }

    static func structure(_ left: (SchemaServer, SchemaDatabase), _ right: (SchemaServer, SchemaDatabase),
                          options: ReconOptions = ReconOptions()) -> ReconStructure {
        ReconStructure(source: left.1, target: right.1, sourceServer: left.0, targetServer: right.0, options: options)
    }

    static let recordings = ["mariadb118": SchemaFixtures.mariadb118, "mariadb105": SchemaFixtures.mariadb105,
                             "mysql84": SchemaFixtures.mysql84, "mysql97": SchemaFixtures.mysql97,
                             "mysql57": SchemaFixtures.mysql57]

    /// The same schema read from MariaDB and MySQL compares the same once their spellings are normalised (types,
    /// defaults, JSON, checks, generated columns, foreign key rules), collations ignored as by default, except for
    /// what only one flavour has: MariaDB's system-versioned table, MySQL's functional index and NOT ENFORCED check,
    /// and descending keys before MariaDB 10.8.
    @Test(arguments: [("mariadb118", "mysql84", ["audit only in source", "customers.email_lower: only in the target",
                                                  "orders.total_small: changed"]),
                      ("mysql84", "mariadb105", ["audit only in target", "customers.created_desc: changed",
                                                 "customers.email_lower: added", "orders.total_small: changed"]),
                      ("mysql97", "mysql84", [])])
    func sameSchemaOnEveryFlavourMatches(_ left: String, _ right: String, _ expected: [String]) async throws {
        let source = try await Self.fixture(try #require(Self.recordings[left]))
        let target = try await Self.fixture(try #require(Self.recordings[right]))
        let structure = Self.structure(source, target)
        let (pairs, onlyInTarget) = structure.tablePairs()
        var differences = onlyInTarget.map { "\($0.name) only in target" }
        for (table, other) in pairs {
            guard let other else {
                differences.append("\(table.name) only in source")
                continue
            }
            differences += structure.compare(table, other).map { "\(table.name).\($0.name): \($0.detail)" }
        }
        #expect(differences.sorted() == expected.sorted())
    }

    @Test func noticesEachKindOfStructuralChange() async throws {
        let (server, database) = try await Self.fixture(SchemaFixtures.mariadb118)
        var changed = database
        let index = try #require(changed.tables.firstIndex { $0.name == "orders" })
        var orders = changed.tables[index]
        let original = orders
        orders.columns.removeLast()
        orders.columns[0].columnType = "smallint(6)"
        orders.columns[0].dataType = "smallint"
        orders.indexes.append(SchemaIndex(name: "ix_extra", unique: false, type: "BTREE",
                                          parts: [.init(column: orders.columns[1].name, expression: nil, prefixLength: nil,
                                                        descending: false)], visible: true, comment: ""))
        if !orders.foreignKeys.isEmpty { orders.foreignKeys[0].onDelete = "CASCADE" }
        orders.comment = "changed"
        changed.tables[index] = orders
        let structure = Self.structure((server, database), (server, changed))
        let parts = structure.compare(original, orders)
        let kinds = parts.map { "\($0.kind) \($0.change)" }
        #expect(kinds.contains("column added"), "\(kinds)")
        #expect(kinds.contains("column changed"))
        #expect(kinds.contains("index dropped"))
        #expect(kinds.contains("options changed"))
        #expect(original.foreignKeys.isEmpty || kinds.contains("foreignKey changed"))
        // The target's smallint becomes the source's wider type: no data can be lost.
        let widened = try #require(parts.first { $0.kind == .column && $0.change == .changed })
        #expect(!widened.narrowing && widened.detail.hasPrefix("type smallint"))
    }

    @Test func narrowingChangesAreDestructive() {
        func column(_ type: String, nullable: Bool = true) -> SchemaColumn {
            SchemaColumn(name: "c", dataType: String(type.prefix { $0.isLetter }), columnType: type, nullable: nullable,
                         defaultValue: .null, autoIncrement: false, onUpdate: nil, generated: nil, invisible: false,
                         isJSON: false, charset: nil, collation: nil, comment: "")
        }
        let narrows = ReconStructure.narrows
        #expect(!narrows(column("int(11)"), column("bigint(20)")))
        #expect(narrows(column("bigint"), column("int")))
        #expect(!narrows(column("int unsigned"), column("bigint")))
        #expect(narrows(column("int"), column("int unsigned")))
        #expect(!narrows(column("varchar(10)"), column("varchar(20)")))
        #expect(narrows(column("varchar(20)"), column("varchar(10)")))
        #expect(!narrows(column("varchar(200)"), column("text")))
        #expect(narrows(column("text"), column("varchar(200)")))
        #expect(!narrows(column("decimal(10,2)"), column("decimal(12,3)")))
        #expect(narrows(column("decimal(10,2)"), column("decimal(10,3)")))
        #expect(narrows(column("int"), column("int", nullable: false)))
        #expect(narrows(column("varchar(10)"), column("int")))
        #expect(!narrows(column("float"), column("double")))
    }

    @Test func checksPairUpByClauseAndJSONChecksDontCount() {
        func table(_ checks: [SchemaCheck], json: Bool) -> SchemaTable {
            var table = SchemaTable(name: "t", kind: .table, engine: "InnoDB")
            table.columns = [SchemaColumn(name: "doc", dataType: json ? "longtext" : "json", columnType: json ? "longtext" : "json",
                                          nullable: true, defaultValue: .null, autoIncrement: false, onUpdate: nil,
                                          generated: nil, invisible: false, isJSON: true, charset: nil, collation: nil,
                                          comment: "")]
            table.checks = checks
            return table
        }
        let mysql = table([SchemaCheck(name: "t_chk_1", clause: "(`total` >= 0)", enforced: true)], json: false)
        let mariadb = table([SchemaCheck(name: "CONSTRAINT_1", clause: "`total` >= 0", enforced: true),
                             SchemaCheck(name: "doc", clause: "json_valid(`doc`)", enforced: true)], json: true)
        var source = SchemaDatabase(name: "a", charset: "utf8mb4", collation: "utf8mb4_bin")
        source.tables = [mysql]
        var target = source
        target.tables = [mariadb]
        let structure = ReconStructure(source: source, target: target, sourceServer: SchemaServer(version: "8.4.13"),
                                       targetServer: SchemaServer(version: "11.8.9-MariaDB"), options: ReconOptions())
        #expect(structure.compare(mysql, mariadb).isEmpty)
    }

    @Test func spellingsNormalise() {
        func column(_ type: String, json: Bool = false) -> SchemaColumn {
            SchemaColumn(name: "c", dataType: "", columnType: type, nullable: true, defaultValue: .null, autoIncrement: false,
                         onUpdate: nil, generated: nil, invisible: false, isJSON: json, charset: nil, collation: nil, comment: "")
        }
        #expect(ReconNormal.type(column("int(11)")) == "int")
        #expect(ReconNormal.type(column("int(10) unsigned zerofill")) == "int unsigned zerofill")
        #expect(ReconNormal.type(column("tinyint(1)")) == "tinyint")
        #expect(ReconNormal.type(column("year(4)")) == "year")
        #expect(ReconNormal.type(column("longtext", json: true)) == "json")
        #expect(ReconNormal.type(column("varchar(20)")) == "varchar(20)")
        #expect(ReconNormal.expression("CURRENT_TIMESTAMP") == ReconNormal.expression("current_timestamp()"))
        #expect(ReconNormal.expression("CURRENT_TIMESTAMP(3)") == ReconNormal.expression("current_timestamp(3)"))
        #expect(ReconNormal.expression("now()") == "current_timestamp")
        #expect(ReconNormal.expression("(upper(_utf8mb4'a'))") == ReconNormal.expression("upper('a')"))
        #expect(ReconNormal.expression("(`a` > 0) and (`b` > 0)") == "(`a`>0)and(`b`>0)")
        #expect(ReconNormal.expression("'A  B'") == "'A  B'")
        #expect(ReconNormal.charset("utf8") == "utf8mb3")
        #expect(ReconNormal.charset("utf8_general_ci") == "utf8mb3_general_ci")
        #expect(ReconNormal.rule("NO ACTION") == ReconNormal.rule("restrict"))
    }

    @Test func whitespaceCompactsOutsideQuotesAndComments() {
        #expect(ReconNormal.compact("select  a ,\n\tb   from t", lowercase: false) == "select a,b from t")
        #expect(ReconNormal.compact("select 'a  b', \"c  d\", `e  f`", lowercase: false) == "select'a  b',\"c  d\",`e  f`")
        #expect(ReconNormal.compact("select 'it''s  x' ,  'a\\'  b'", lowercase: false) == "select'it''s  x','a\\'  b'")
        // A line comment keeps its line break: what follows it isn't inside the comment.
        #expect(ReconNormal.compact("a -- note\nb", lowercase: false) != ReconNormal.compact("a -- note b", lowercase: false))
        #expect(ReconNormal.compact("a /* x  y */  b", lowercase: false) == "a/* x  y */b")
        #expect(ReconNormal.compact("SELECT X", lowercase: true) == "select x")
        #expect(ReconNormal.compact("a--1", lowercase: false) == "a--1")
    }

    @Test func definersAndOwnDatabaseNamesAreNoise() {
        let mysql = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `v` AS select `shop`.`t`.`id` AS `id` from `shop`.`t`"
        #expect(ReconNormal.definerRemoved(mysql)
                == "CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `v` AS select `shop`.`t`.`id` AS `id` from `shop`.`t`")
        #expect(ReconNormal.definerRemoved("CREATE DEFINER=`we``ird user`@`local host` PROCEDURE `p`() BEGIN END")
                == "CREATE PROCEDURE `p`() BEGIN END")
        let rules = ReconIgnoreRules()
        let other = mysql.replacingOccurrences(of: "`root`@`%`", with: "`deploy`@`10.0.0.%`")
            .replacingOccurrences(of: "`shop`", with: "`staging`")
        #expect(ReconNormal.definition(mysql, database: "shop", rules: rules)
                == ReconNormal.definition(other, database: "staging", rules: rules))
        var strict = rules
        strict.definer = false
        #expect(ReconNormal.definition(mysql, database: "shop", rules: strict)
                != ReconNormal.definition(other, database: "staging", rules: strict))
        #expect(ReconNormal.qualifiersMapped("from `shop`.`t`", from: "shop", to: "shop`2") == "from `shop``2`.`t`")
    }
}
