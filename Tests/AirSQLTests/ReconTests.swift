import CMariaDB
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

    @Test func jsonTrueIsNotOne() {
        func same(_ a: String, _ b: String) -> Bool { ReconTableSQL.same(Array(a.utf8), Array(b.utf8), .json) }
        #expect(!same(#"{"a": true}"#, #"{"a": 1}"#) && !same("[false]", "[0]"))
        #expect(same(#"{"a": 1, "b": [true, null]}"#, #"{"b":[true,null],"a":1.0}"#) && !same("[1, 2]", "[2, 1]"))
    }

    @Test func spellingsNormalise() {
        func column(_ type: String, json: Bool = false) -> SchemaColumn {
            SchemaColumn(name: "c", dataType: "", columnType: type, nullable: true, defaultValue: .null, autoIncrement: false,
                         onUpdate: nil, generated: nil, invisible: false, isJSON: json, charset: nil, collation: nil, comment: "")
        }
        #expect(ReconNormal.type(column("int(11)")) == "int")
        #expect(ReconNormal.type(column("int(6) unsigned zerofill")) != ReconNormal.type(column("int(8) unsigned zerofill")))
        #expect(ReconNormal.type(column("ENUM('A','b')")) == "enum('A','b')")
        #expect(ReconNormal.type(column("geomcollection")) == ReconNormal.type(column("geometrycollection")))
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

    static let mysqlCreate = """
        CREATE TABLE `orders` (
          `id` bigint unsigned NOT NULL AUTO_INCREMENT,
          `customer_id` int NOT NULL,
          `currency` char(3) NOT NULL DEFAULT 'EUR',
          `note``s` varchar(20) DEFAULT 'a,b',
          PRIMARY KEY (`id`),
          UNIQUE KEY `ux` (`customer_id`,`currency`),
          KEY `ix_status` (`currency`) /*!80000 INVISIBLE */,
          CONSTRAINT `fk_customer` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) ON DELETE CASCADE,
          CONSTRAINT `orders_chk_1` CHECK ((`customer_id` > 0))
        ) ENGINE=InnoDB AUTO_INCREMENT=1284 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
        """

    @Test func createTableLinesGiveTheSourcesDefinitions() throws {
        let create = try #require(ReconCreateTable(Self.mysqlCreate))
        #expect(create.definition(.column, "currency") == "`currency` char(3) NOT NULL DEFAULT 'EUR'")
        #expect(create.definition(.column, "note`s") == "`note``s` varchar(20) DEFAULT 'a,b'")
        #expect(create.definition(.index, "PRIMARY") == "PRIMARY KEY (`id`)")
        #expect(create.definition(.index, "ix_status") == "KEY `ix_status` (`currency`) /*!80000 INVISIBLE */")
        #expect(create.definition(.foreignKey, "fk_customer")?.hasSuffix("ON DELETE CASCADE") == true)
        #expect(create.definition(.check, "orders_chk_1") == "CONSTRAINT `orders_chk_1` CHECK ((`customer_id` > 0))")
        let bare = create.withoutForeignKeys
        #expect(!bare.contains("FOREIGN KEY") && !bare.contains("AUTO_INCREMENT=") && bare.contains("AUTO_INCREMENT,"))
        #expect(bare.contains("CHECK ((`customer_id` > 0))\n) ENGINE=InnoDB DEFAULT CHARSET"))
        #expect(create.foreignKeys.count == 1)
    }

    /// A result with one of everything the script handles.
    static func result(mariadb: Bool = false) -> ReconResult {
        var options = ReconOptions()
        options.mode = .both
        var result = ReconResult(source: ReconEnd(name: "Production", database: "shop", version: "8.4.13"),
                                 target: ReconEnd(name: "Staging", database: "shop_stage",
                                                  version: mariadb ? "11.8.9-MariaDB" : "8.4.13"),
                                 options: options)
        var orders = ReconObject(kind: .table, name: "orders", status: .different)
        orders.references = ["customers"]
        orders.parts = [
            ReconPart(kind: .column, name: "currency", change: .added, definition: "`currency` char(3) NOT NULL",
                      after: "total"),
            ReconPart(kind: .column, name: "legacy", change: .dropped),
            ReconPart(kind: .column, name: "code", change: .changed, definition: "`code` varchar(5)", narrowing: true),
            ReconPart(kind: .index, name: "ix", change: .changed, definition: "KEY `ix` (`currency`)"),
            ReconPart(kind: .check, name: "old_check", change: .dropped),
            ReconPart(kind: .foreignKey, name: "fk_customer", change: .changed,
                      definition: "CONSTRAINT `fk_customer` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`)"),
            ReconPart(kind: .options, name: "engine", change: .changed, definition: "ENGINE=InnoDB"),
        ]
        var customers = ReconObject(kind: .table, name: "customers", status: .same)
        var data = ReconTableData(outcome: .different)
        data.key = ["id"]
        data.columns = [ReconColumn(name: "id", kind: .integer), ReconColumn(name: "name", kind: .text)]
        data.missing = [ReconRow([Array("5".utf8), Array("it's".utf8)])]
        data.extra = [ReconRow([Array("6".utf8), nil])]
        data.changed = [ReconRowChange(source: ReconRow([Array("2".utf8), Array("B".utf8)]),
                                       target: ReconRow([Array("2".utf8), Array("b".utf8)]), columns: [1])]
        customers.data = data
        var gifts = ReconObject(kind: .table, name: "gift_cards", status: .onlyInSource)
        gifts.sourceDDL = "CREATE TABLE `gift_cards` (\n  `code` int NOT NULL,\n  PRIMARY KEY (`code`)\n) ENGINE=InnoDB"
        let legacy = ReconObject(kind: .table, name: "legacy", status: .onlyInTarget)
        var view = ReconObject(kind: .view, name: "big_orders", status: .onlyInSource)
        view.sourceDDL = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `big_orders` AS select `shop`.`orders`.`id` AS `id` from `shop`.`orders`"
        var trigger = ReconObject(kind: .trigger, name: "orders_bi", status: .different)
        trigger.sourceDDL = "CREATE DEFINER=`root`@`%` TRIGGER `orders_bi` BEFORE INSERT ON `orders` FOR EACH ROW SET NEW.total = 0"
        result.objects = [orders, customers, gifts, legacy, view, trigger]
        return result
    }

    @Test func scriptRunsInDependencyOrderWithoutDestructiveSteps() {
        let script = Self.result().script()
        #expect(script.first == "USE `shop_stage`" && script[1] == "SET time_zone = '+00:00'")
        func position(_ text: String) -> Int { script.firstIndex { $0.contains(text) } ?? -1 }
        #expect(position("DROP FOREIGN KEY `fk_customer`") < position("CREATE TABLE `gift_cards`"))
        #expect(position("DROP TRIGGER IF EXISTS `orders_bi`") < position("ALTER TABLE `orders`\n  ADD COLUMN"))
        #expect(position("ADD COLUMN `currency` char(3) NOT NULL AFTER `total`") < position("CREATE OR REPLACE ALGORITHM"))
        #expect(position("CREATE OR REPLACE ALGORITHM") < position("ADD CONSTRAINT `fk_customer`"))
        #expect(position("ADD CONSTRAINT `fk_customer`") < position("CREATE TRIGGER `orders_bi`"))
        #expect(position("START TRANSACTION") < position("UPDATE `customers` SET `name` = 'B' WHERE `id` IN (2)"))
        #expect(position("INSERT INTO `customers` (`id`, `name`) VALUES\n(5, 'it\\'s')") < position("COMMIT"))
        #expect(script.contains { $0.contains("DROP INDEX `ix`,\n  ADD KEY `ix` (`currency`)") })
        // DEFINER left out (ignored by default) and the view's database qualifier mapped to the target's.
        #expect(script.contains { $0.hasPrefix("CREATE OR REPLACE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW")
                    && $0.contains("from `shop_stage`.`orders`") })
        #expect(!script.contains { $0.contains("DROP COLUMN") || $0.contains("DELETE") || $0.contains("DROP TABLE")
                    || $0.contains("MODIFY COLUMN `code`") || $0.contains("old_check") })
    }

    @Test func destructiveStepsComeOnlyWhenAskedAndAreMarked() {
        let steps = Self.result(mariadb: true).steps(destructive: true).filter(\.destructive)
        let sql = steps.map(\.sql)
        #expect(sql.allSatisfy { $0.hasPrefix("-- Destructive: ") })
        #expect(sql.contains { $0.contains("DROP COLUMN `legacy`") && $0.contains("MODIFY COLUMN `code` varchar(5)")
                    && $0.contains("DROP CONSTRAINT `old_check`") })
        #expect(sql.contains { $0.hasSuffix("DROP TABLE `legacy`") })
        #expect(steps.contains { $0.sql.hasSuffix("DELETE FROM `customers` WHERE `id` IN (6)") && $0.expectedRows == 1 })
        let script = Self.result().script(destructive: true)
        #expect(script.firstIndex { $0.contains("DELETE FROM") }! < script.firstIndex { $0.contains("INSERT INTO") }!)
        #expect(script.firstIndex { $0.contains("DROP TABLE `legacy`") }! > script.firstIndex { $0.contains("CREATE TRIGGER") }!)
        var structureOnly = Self.result()
        structureOnly.options.mode = .structure
        #expect(!structureOnly.script().contains { $0.hasPrefix("INSERT") || $0 == "START TRANSACTION" })
        var dataOnly = Self.result()
        dataOnly.options.mode = .data
        #expect(dataOnly.steps().allSatisfy { $0.kind == .data })
    }

    /// Each column's part of the encoded row: a NULL flag, then the length and a separator before the value, so
    /// swapped values, NULLs in other columns and separator-like text can't encode alike; long types by their MD5.
    @Test func rowHashEncodesEveryColumnWithItsNullFlagAndLength() {
        let sql = ReconTableSQL(database: "d`b", table: "t`; --", key: [ReconColumn(name: "i`d", kind: .integer)],
                                columns: [ReconColumn(name: "i`d", kind: .integer), ReconColumn(name: "a", kind: .text),
                                          ReconColumn(name: "doc", kind: .json), ReconColumn(name: "img", kind: .blob),
                                          ReconColumn(name: "flags", kind: .bit)],
                                filter: "x > 1 -- note", noBackslashEscapes: false)
        #expect(ReconTableSQL.part(ReconColumn(name: "a", kind: .text))
                == "IFNULL(CONCAT('0', LENGTH(CONVERT(`a` USING utf8mb4)), ':', CONVERT(`a` USING utf8mb4)), '1')")
        #expect(sql.rowHash.hasPrefix("CAST(CONV(LEFT(MD5(CONCAT(IFNULL(CONCAT('0', LENGTH(`i``d`), ':', `i``d`), '1'), "))
        #expect(sql.rowHash.contains("MD5(CONVERT(`doc` USING utf8mb4))") && sql.rowHash.contains("MD5(`img`)")
                    && sql.rowHash.contains("(`flags` + 0)"))
        #expect(sql.rowHash.hasSuffix(")), 16), 16, 10) AS UNSIGNED)"))
        #expect(sql.checksum(after: nil, upTo: nil).hasPrefix("SELECT COUNT(*), SUM(CAST(CONV(LEFT(MD5(CONCAT("))
        #expect(sql.checksum(after: nil, upTo: nil).hasSuffix(" FROM `d``b`.`t``; --` WHERE (\nx > 1 -- note\n)"))
        #expect(sql.boundary(after: [Array("10".utf8)], upTo: nil, rows: 1_000)
                == "SELECT `i``d` FROM `d``b`.`t``; --` WHERE (\nx > 1 -- note\n) AND `i``d` > 10 ORDER BY `i``d` LIMIT 1 OFFSET 999")
    }

    @Test func compositeKeysWalkInKeyOrder() {
        let key = [ReconColumn(name: "a", kind: .integer), ReconColumn(name: "b", kind: .text),
                   ReconColumn(name: "c", kind: .binary)]
        let sql = ReconTableSQL(database: "d", table: "t", key: key, columns: key, filter: "", noBackslashEscapes: false)
        let low = [Array("1".utf8), Array("x'".utf8), [0, 255]], high = [Array("2".utf8), Array("y".utf8), [1]]
        #expect(sql.conditions(after: low, upTo: high)
                == " WHERE (`a` > 1 OR (`a` = 1 AND (`b` > 'x\\'' OR (`b` = 'x\\'' AND `c` > X'00FF'))))"
                    + " AND (`a` < 2 OR (`a` = 2 AND (`b` < 'y' OR (`b` = 'y' AND `c` <= X'01'))))")
        #expect(sql.rows(keys: [low, high]).hasSuffix(" WHERE (`a` = 1 AND `b` = 'x\\'' AND `c` = X'00FF') OR (`a` = 2 AND `b` = 'y' AND `c` = X'01')"))
    }

    @Test func literalsAreQuotedSafely() {
        for value in Hostile.values {
            let bytes = Array(value.utf8)
            #expect(ReconTableSQL.literal(bytes, .text, noBackslashEscapes: false) == SQLQuote.string(value))
            #expect(ReconTableSQL.literal(bytes, .json, noBackslashEscapes: true) == SQLQuote.string(value, noBackslashEscapes: true))
            #expect(ReconTableSQL.literal(bytes, .integer, noBackslashEscapes: false) == SQLQuote.string(value)
                        || ReconTableSQL.isNumber(value))
            #expect(ReconTableSQL.literal(bytes, .blob, noBackslashEscapes: false) == SQLQuote.hex(bytes))
        }
        #expect(ReconTableSQL.literal(nil, .text, noBackslashEscapes: false) == "NULL")
        #expect(ReconTableSQL.literal(Array("18446744073709551615".utf8), .integer, noBackslashEscapes: false)
                == "18446744073709551615")
        #expect(ReconTableSQL.literal(Array("-1.5e-3".utf8), .float, noBackslashEscapes: false) == "-1.5e-3")
        #expect(ReconTableSQL.literal(Array("1; DROP TABLE t".utf8), .decimal, noBackslashEscapes: false)
                == "'1; DROP TABLE t'")
        #expect(ReconTableSQL.literal([0x01, 0x05], .bit, noBackslashEscapes: false) == "b'100000101'")
        for text in ["1", "-1", "+2.5", ".5", "5.", "1e10", "1E-3"] { #expect(ReconTableSQL.isNumber(text), "\(text)") }
        for text in ["", "-", ".", "e5", "1e", "0x10", "1 ", "1,5", "١"] { #expect(!ReconTableSQL.isNumber(text), "\(text)") }
    }

    @Test func valuesCompareAsValuesWhereServersWriteThemDifferently() {
        func same(_ a: String?, _ b: String?, _ kind: ReconColumn.Kind) -> Bool {
            ReconTableSQL.same(a.map { Array($0.utf8) }, b.map { Array($0.utf8) }, kind)
        }
        #expect(same("0.1", "0.10", .float) && same("1e300", "1E+300", .float) && !same("0.1", "0.2", .float))
        #expect(same("1.50", "1.5", .decimal) && same("007", "7", .integer) && !same("1.5", "1.51", .decimal))
        #expect(same("-0", "0.000", .decimal) && same("+12.3", "12.30", .decimal))
        // DECIMAL(65,0) differing in the last digit, past Foundation Decimal's 38 significant digits.
        let big = String(repeating: "9", count: 64)
        #expect(!same(big + "1", big + "2", .decimal) && same(big + "1", big + "1", .decimal))
        #expect(same(#"{"a": 1, "b": [true, null]}"#, #"{"b":[true,null],"a":1}"#, .json))
        #expect(!same(#"{"a": 1}"#, #"{"a": "1"}"#, .json))
        #expect(!same("a", "A", .text) && !same("a", "a ", .text) && !same("", nil, .text) && same(nil, nil, .text))
        #expect(!same("2026-01-01 00:00:00", "2026-01-01 00:00:00.000", .temporal))
    }

    /// A unique NOT NULL key on a generated column can't be the matching key: the data compare drops generated columns,
    /// so the key would end up a different, non-unique column. Such a table falls back to the no-key checksum.
    @Test func matchingKeyIgnoresAKeyOnAGeneratedColumn() {
        func col(_ name: String, generated: Bool = false) -> SchemaColumn {
            SchemaColumn(name: name, dataType: "int", columnType: "int", nullable: false, defaultValue: .null,
                         autoIncrement: false, onUpdate: nil,
                         generated: generated ? .init(expression: "(`a` * 100)", stored: true) : nil,
                         invisible: false, isJSON: false, charset: nil, collation: nil, comment: "")
        }
        func part(_ column: String) -> SchemaIndex.Part {
            .init(column: column, expression: nil, prefixLength: nil, descending: false)
        }
        var table = SchemaTable(name: "t", kind: .table, engine: "InnoDB")
        table.columns = [col("a"), col("b"), col("code", generated: true)]
        table.indexes = [SchemaIndex(name: "uk", unique: true, type: "BTREE", parts: [part("code")], visible: true, comment: "")]
        #expect(Recon.matchingKey(table, table) == nil)
        // A unique NOT NULL key on a plain column is still chosen.
        table.indexes.append(SchemaIndex(name: "uk2", unique: true, type: "BTREE", parts: [part("a")], visible: true, comment: ""))
        #expect(Recon.matchingKey(table, table) == ["a"])
    }

    /// A row two servers put in different chunks (their key collations order differently) still meets its other half,
    /// and only rows whose hashes differ are compared further.
    @Test func tallyMatchesRowsAcrossChunks() {
        var tally = ReconTally()
        func key(_ text: String) -> [[UInt8]] { [Array(text.utf8)] }
        let first = tally.add(source: [(key("a"), 1), (key("b"), 2), (key("c"), 3)], target: [(key("a"), 1), (key("b"), 9)])
        #expect(first == [key("b")])
        #expect(tally.sourceOnly.keys.sorted { $0[0].lexicographicallyPrecedes($1[0]) } == [key("c")])
        let second = tally.add(source: [(key("d"), 4)], target: [(key("c"), 3), (key("e"), 5)])
        #expect(second.isEmpty && tally.sourceOnly.keys.map { $0 } == [key("d")] && tally.targetOnly.keys.map { $0 } == [key("e")])
        let third = tally.add(source: [(key("e"), 6)], target: [])
        #expect(third == [key("e")] && tally.count == 1)
    }

    @Test func reportsEscapeWhatTheyWrite() {
        var result = Self.result()
        let index = result.objects.firstIndex { $0.name == "customers" }!
        result.objects[index].data?.missing.append(ReconRow([Array("7".utf8), Array("=HYPERLINK(\"x\"), <b>|".utf8)]))
        let csv = ReconReport.text(result, format: .csv)
        #expect(csv.hasPrefix("kind,object,status,difference,item,detail\r\n"))
        #expect(csv.contains("table,customers,different data,missing row,id='5',only in Production; name='it's'\r\n"))
        #expect(csv.contains(",missing row,id='7',\"only in Production; name='=HYPERLINK(\"\"x\"\"), <b>|'\"\r\n"))
        #expect(csv.contains("changed row,id='2',name: 'b' → 'B'"))
        let html = ReconReport.text(result, format: .html)
        #expect(html.contains("&lt;b&gt;") && !html.contains("<b>|"))
        let markdown = ReconReport.text(result, format: .markdown)
        #expect(markdown.contains("<b>\\|") && markdown.contains("## Table orders: different structure"))
        #expect(ReconReport.summary(result).first { $0.label == "only in Staging" }?.value == "1")
        #expect(ReconReport.summary(result).map(\.label).prefix(2) == ["tables match", "table differs in structure"])
    }

    @Test func aChosenPairReadsTheSourceUnderTheTargetsName() {
        let view = "CREATE ALGORITHM=UNDEFINED DEFINER=`view`@`%` SQL SECURITY DEFINER VIEW `shop`.`a` AS select 1"
        #expect(ReconNormal.renamed(view, .view, to: "b`c").hasSuffix("VIEW `shop`.`b``c` AS select 1"))
        #expect(ReconNormal.renamed("CREATE DEFINER=`p`@`%` PROCEDURE `p`()\nBEGIN END", .procedure, to: "q")
                == "CREATE DEFINER=`p`@`%` PROCEDURE `q`()\nBEGIN END")
        #expect(ReconNormal.renamed("no such thing", .trigger, to: "q") == "no such thing")
    }

    /// In one database the script must replace the target and leave the source alone.
    @Test func aPairsScriptWritesOnlyTheTarget() {
        var view = ReconObject(kind: .view, name: "a", targetName: "b", status: .different)
        view.sourceDDL = "CREATE VIEW `shop`.`a` AS select 1"
        var routine = ReconObject(kind: .procedure, name: "p", targetName: "q", status: .different)
        routine.sourceDDL = "CREATE PROCEDURE `p`()\nSELECT 1"
        let end = ReconEnd(name: "Local", database: "shop", version: "11.8.9-MariaDB")
        let script = ReconResult(source: end, target: end, options: ReconOptions(), objects: [view, routine]).steps().map(\.sql)
        #expect(script == ["DROP PROCEDURE IF EXISTS `q`", "CREATE OR REPLACE VIEW `shop`.`b` AS select 1",
                           "CREATE PROCEDURE `q`()\nSELECT 1"])
    }

    @Test func aPairOfDefinitionsComparesWithoutItsNames() async throws {
        let schema = try await Self.fixture(SchemaFixtures.mariadb118)
        let structure = Self.structure(schema, schema)
        #expect(structure.definition(.view, name: "a", targetName: "b", source: "CREATE VIEW `airsql_fixture`.`a` AS select 1",
                                     target: "CREATE VIEW `airsql_fixture`.`b` AS select 1")?.status == .same)
        let different = structure.definition(.view, name: "a", targetName: "b", source: "CREATE VIEW `a` AS select 1",
                                             target: "CREATE VIEW `b` AS select 2")
        #expect(different?.status == .different && different?.targetName == "b")
    }

    @Test func aPairsForeignKeysMatchByWhatTheyDo() async throws {
        var (server, database): (SchemaServer, SchemaDatabase) = try await Self.fixture(SchemaFixtures.mariadb118)
        _ = server
        let key = SchemaForeignKey(name: "fk_a", columns: ["c"], referencedDatabase: "airsql_fixture", referencedTable: "t",
                                   referencedColumns: ["id"], onUpdate: "RESTRICT", onDelete: "CASCADE")
        var other = key
        other.name = "fk_b"
        var (left, right) = (try #require(database.tables.first { $0.kind == .table }), try #require(database.tables.first { $0.kind == .table }))
        left.foreignKeys = [key]
        right.foreignKeys = [other]
        database.tables = [left]
        var options = ReconOptions()
        #expect(Self.structure((server, database), (server, database), options: options).compare(left, right).count == 2)
        options.only = ReconPair(kind: .table, source: left.name, target: right.name)
        #expect(Self.structure((server, database), (server, database), options: options).compare(left, right).isEmpty)
    }

    @Test func thePairsTablesAreTheOnlyOnes() async throws {
        let schema = try await Self.fixture(SchemaFixtures.mariadb118)
        let tables = schema.1.tables.filter { $0.kind == .table }.map(\.name)
        var options = ReconOptions()
        options.only = ReconPair(kind: .table, source: tables[0], target: tables[1])
        let (pairs, onlyInTarget) = Self.structure(schema, schema, options: options).tablePairs()
        #expect(pairs.map(\.source.name) == [tables[0]] && pairs.map { $0.target?.name } == [tables[1]] && onlyInTarget.isEmpty)
        options.only = ReconPair(kind: .view, source: "v", target: "w")
        #expect(Self.structure(schema, schema, options: options).tablePairs().pairs.isEmpty)
    }

    @Test func aDefinitionsIgnoreRulesCount() async throws {
        let schema = try await Self.fixture(SchemaFixtures.mariadb118)
        func status(_ rules: (inout ReconIgnoreRules) -> Void, _ left: String, _ right: String) -> ReconObject.Status? {
            var options = ReconOptions()
            rules(&options.ignore)
            return Self.structure(schema, schema, options: options).definition(.view, name: "a", source: left, target: right)?.status
        }
        let upper = "CREATE VIEW `a` AS SELECT 'Text'", lower = "create view `A` as select 'Text'"
        #expect(status({ _ in }, upper, lower) == .different)
        #expect(status({ $0.letterCase = true }, upper, lower) == .same)
        #expect(status({ $0.letterCase = true }, upper, "CREATE VIEW `a` AS SELECT 'TEXT'") == .different, "quoted text keeps its case")
        #expect(status({ $0.letterCase = true; $0.whitespace = false }, upper, lower) == .same)
        #expect(status({ _ in }, upper, "CREATE VIEW `a` AS SELECT 2") == .different)
        #expect(status({ $0.definitions = true }, upper, "CREATE VIEW `a` AS SELECT 2") == .same)
        #expect(status({ $0.definitions = true }, upper, "") == .different, "unread isn't the same")
    }

    @Test func columnOrderCanBeIgnored() async throws {
        let schema = try await Self.fixture(SchemaFixtures.mariadb118)
        let table = try #require(schema.1.tables.first { $0.kind == .table && $0.columns.count > 1 })
        var swapped = table
        swapped.columns.swapAt(0, 1)
        #expect(!Self.structure(schema, schema).compare(table, swapped).isEmpty)
        var options = ReconOptions()
        options.ignore.columnOrder = true
        #expect(Self.structure(schema, schema, options: options).compare(table, swapped).isEmpty)
    }

    @Test func untickedObjectsLeaveTheScript() {
        var kept = ReconObject(kind: .view, name: "kept", status: .different), skipped = kept
        kept.sourceDDL = "CREATE VIEW `kept` AS select 1"
        skipped.name = "skipped"
        skipped.targetName = "skipped"
        skipped.sourceDDL = "CREATE VIEW `skipped` AS select 1"
        skipped.leftOut = true
        let end = ReconEnd(name: "Local", database: "shop", version: "8.4.13")
        #expect(ReconResult(source: end, target: end, options: ReconOptions(), objects: [kept, skipped]).steps().map(\.object) == ["kept"])
    }

    @Test func databasesPairByName() {
        func text(_ pairs: [(source: String?, target: String?)]) -> [String] { pairs.map { "\($0.source ?? "-")/\($0.target ?? "-")" } }
        #expect(text(Recon.paired(["a", "Shop"], ["shop", "z"], caseless: true)) == ["a/-", "Shop/shop", "-/z"])
        #expect(text(Recon.paired(["Shop"], ["shop"], caseless: false)) == ["Shop/-", "-/shop"])
        #expect(text(Recon.paired(["Sales", "sales"], ["sales"], caseless: true)) == ["Sales/-", "sales/sales"], "the exact name first")
    }

    /// A server's result: the pairs in the summary and the report, each difference named within its database, and no script.
    @Test func aServerResultReportsItsPairs() {
        let left = ReconEnd(name: "Production", database: "", version: "8.4.13"), right = ReconEnd(name: "Staging", database: "", version: "8.4.13")
        var inner = ReconResult(source: ReconEnd(name: "Production", database: "shop", version: "8.4.13"),
                                target: ReconEnd(name: "Staging", database: "shop", version: "8.4.13"), options: ReconOptions())
        var orders = ReconObject(kind: .table, name: "orders", status: .different)
        orders.parts = [ReconPart(kind: .column, name: "currency", change: .added, detail: "added")]
        inner.objects = [orders]
        var result = ReconResult(source: left, target: right, options: ReconOptions(), objects: [
            ReconObject(kind: .database, name: "shop", status: .different), ReconObject(kind: .database, name: "same", status: .same),
            ReconObject(kind: .database, name: "gone", status: .onlyInTarget)])
        result.databases["shop"] = inner
        #expect(result.isServer && result.steps(destructive: true).isEmpty && result.script().isEmpty)
        let summary = ReconReport.summary(result)
        #expect(summary.count == 6 && summary.map(\.value) == ["1", "1", "0", "1", "0", "1"])
        #expect(summary[0].label == "database matches")
        #expect(ReconReport.text(result, format: .csv).contains("table,shop.orders,different structure,structure,column currency,added"))
        let markdown = ReconReport.text(result, format: .markdown)
        #expect(markdown.contains("## Database shop: different") && markdown.contains("shop.orders: column currency"))
        #expect(markdown.contains("Production (8.4.13) → Staging (8.4.13)"))
        // Compared again on its own, the pair matches, and the server's list says so.
        inner.objects = [ReconObject(kind: .table, name: "orders", status: .same)]
        result.update(pair: "shop", with: inner)
        #expect(result.object(.database, "shop")?.status == .same)
    }

    @Test func linesAlignSideBySide() {
        let rows = ReconLines.aligned("a\nb\nc\nd", "a\nc\nx\nd")
        #expect(rows.map { "\($0.left ?? "-")\($0.right ?? "-")" } == ["aa", "b-", "cc", "-x", "dd"])
        #expect(ReconLines.aligned("", "").count == 1)
        // Lines in each other's place are one changed line, as far as both sides have lines.
        #expect(ReconLines.aligned("a\nb\nc\nz", "a\nx\nz").map { "\($0.left ?? "-")\($0.right ?? "-")" } == ["aa", "bx", "c-", "zz"])
    }

    @Test func spaceCanBeLeftOutOfTheLines() {
        let rows = ReconLines.aligned("  a  b\nc", "a b\nd", ignoringSpace: true)
        #expect(rows.map(\.left) == ["  a  b", "c"] && rows.map(\.right) == ["a b", "d"])
        #expect(!ReconLines.differs(rows[0], ignoringSpace: true) && ReconLines.differs(rows[0]) && ReconLines.differs(rows[1], ignoringSpace: true))
    }

    @Test func unifiedLinesGoAsTheScriptDoes() {
        let lines = ReconLines.unified(ReconLines.aligned("a\nnew\nz", "a\nold\nz\ngone"))
        #expect(lines.map { $0.mark + $0.line } == [" a", "-old", "+new", " z", "-gone"])
    }

    @Test func changedWordsAreTheOnesNotShared() {
        func marked(_ text: String, _ ranges: [NSRange]) -> [String] { ranges.map { (text as NSString).substring(with: $0) } }
        let left = "`status` = 'paid', é😀 x", right = "`state` = 'paid', é😀 yy"
        let changes = ReconLines.changedWords(left, right)
        #expect(marked(left, changes.left) == ["status", "x"] && marked(right, changes.right) == ["state", "yy"])
        #expect(ReconLines.changedWords("a  b", "a b", ignoringSpace: true).left.isEmpty)
        #expect(marked("a  b", ReconLines.changedWords("a  b", "a b").left) == ["  "])
        // Too long to diff word by word: the whole line.
        let long = (1...3000).map(String.init).joined(separator: " ")
        #expect(ReconLines.changedWords(long, long + " x").left == [NSRange(location: 0, length: (long as NSString).length)])
    }
}

/// A result compared with another result in memory (Compare With…), and the diff as the grid shows it.
struct ReconResultsTests {
    /// A result of `columns` (the first as the primary key when `keyed`) holding `rows`; nil cells are NULL.
    static func store(_ columns: [(String, enum_field_types)], keyed: Bool = true, _ rows: [[String?]]) -> ResultStore {
        let store = ResultStore(columns: columns.enumerated().map { index, column in
            ResultStore.Column(name: column.0, originalTable: "t", type: column.1, flags: keyed && index == 0 ? UInt32(PRI_KEY_FLAG) : 0)
        })
        for row in rows { store.append(row.map { $0.map { Array($0.utf8) } }) }
        return store
    }

    static let ints = MYSQL_TYPE_LONG, text = MYSQL_TYPE_VAR_STRING, money = MYSQL_TYPE_NEWDECIMAL, json = MYSQL_TYPE_JSON

    /// Matched on the key: rows only in the first are missing, only in the second extra, and changed rows name the
    /// cells that differ, values compared as the data compare compares them (2.50 = 2.5, JSON by value, NULL ≠ "").
    /// Columns go by name in the first's order; those only one side has aren't compared.
    @Test func resultsCompareOnTheirKey() {
        let first = Self.store([("id", Self.ints), ("name", Self.text), ("price", Self.money), ("tags", Self.json), ("extra", Self.text)], [
            ["1", "pen", "2.50", #"{"a": 1, "b": 2}"#, "x"], ["2", "ink", "4.00", nil, "y"], ["3", "pad", "1.00", "[]", "z"],
            ["5", "", "9.99", nil, nil],
        ])
        let second = Self.store([("PRICE", Self.money), ("id", Self.ints), ("name", Self.text), ("tags", Self.json)], [
            ["2.5", "1", "pen", #"{"b":2,"a":1}"#], ["4.10", "2", "INK", nil], ["7.00", "4", "cap", nil], ["9.99", "5", nil, nil],
        ])
        let data = ReconTableData.compare(first, second, key: ["id"])
        #expect(data.outcome == .different && data.key == ["id"] && data.columns.map(\.name) == ["id", "name", "price", "tags"])
        #expect(data.columns.map(\.kind) == [.integer, .text, .decimal, .json])
        #expect(data.missing.map { $0.text(0, kind: .integer) } == ["3"])
        #expect(data.extra.map { $0.text(0, kind: .integer) } == ["4"])
        #expect(data.changed.map { $0.source.text(0, kind: .integer) ?? "" } == ["2", "5"])
        #expect(data.changed.map(\.columns) == [[1, 2], [1]])
        #expect(data.sourceRows == 4 && data.targetRows == 4)
        // The diff in the grid: added, removed, then changed rows, the first's values with both in a changed cell's note.
        let diff = DiffSource(data, names: ("Result 2", "Result 1"))
        #expect(diff.rowCount == 4 && (0..<4).map { diff.mark($0, 1) } == [.inserted, .deleted, .edited, .edited])
        #expect(diff.mark(2, 0) == .none && diff.value(1, 1) == "cap" && diff.cell(3, 1) == .text(""))
        #expect(diff.note(2, 1) == "Result 1 has INK; Result 2 has ink" && diff.note(3, 1) == "Result 1 has NULL; Result 2 has ")
        #expect(diff.note(0, 1) == nil && diff.note(2, 3) == nil)
        #expect(diff.columns.map(\.isKey) == [true, false, false, false] && diff.columns[2].kind == .number)
    }

    /// Without a key, rows match on every value (so a changed row is missing and extra); rows sharing a key pair up in
    /// their order; a key column only one side has, or no shared columns, is said rather than compared.
    @Test func resultsMatchOnEveryColumnOrSayWhyNot() {
        let first = Self.store([("a", Self.text), ("b", Self.text)], keyed: false, [["x", "1"], ["x", "1"], ["y", "2"]])
        let second = Self.store([("a", Self.text), ("b", Self.text)], keyed: false, [["y", "3"], ["x", "1"]])
        let whole = ReconTableData.compare(first, second, key: [])
        #expect(whole.key.isEmpty && whole.changed.isEmpty)
        #expect(whole.missing.map { $0.text(1, kind: .text) } == ["1", "2"] && whole.extra.map { $0.text(1, kind: .text) } == ["3"])
        let byA = ReconTableData.compare(first, second, key: ["A"])
        #expect(byA.key == ["a"] && byA.missing.count == 1 && byA.changed.map(\.columns) == [[1]] && byA.extra.isEmpty)
        #expect(ReconTableData.compare(first, first, key: ["a"]).outcome == .same)
        #expect(ReconTableData.compare(first, second, key: ["c"]).outcome
                == .notCompared("“c” isn't a column of both, so rows can't be matched on it."))
        #expect(ReconTableData.compare(first, Self.store([("z", Self.text)], [["1"]]), key: []).outcome
                == .notCompared("The two have no columns of the same name."))
    }

    /// A long value shows its first 1,000 characters (a BLOB its first 500 bytes as hex), never cut in a key column;
    /// copying takes all of it.
    @Test func longValuesAreShortenedOnScreenOnly() {
        var data = ReconTableData(outcome: .different)
        data.key = ["k"]
        data.columns = [ReconColumn(name: "k", kind: .text), ReconColumn(name: "body", kind: .longText),
                        ReconColumn(name: "blob", kind: .blob)]
        let long = String(repeating: "é", count: 3_000), key = String(repeating: "k", count: 1_500)
        data.missing = [ReconRow([Array(key.utf8), Array(long.utf8), Array(repeating: 0xAB, count: 2_000)])]
        let diff = DiffSource(data, names: ("a", "b"))
        #expect(diff.cell(0, 0) == .text(key) && diff.cell(0, 1) == .text(String(repeating: "é", count: 1_000) + "…"))
        #expect(diff.cell(0, 2) == .text("0x" + String(repeating: "AB", count: 500) + "…"))
        #expect(diff.value(0, 1) == long && diff.value(0, 2)?.count == 4_002 && diff.columns[2].kind == .binary)
    }
}
