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
        #expect(same(#"{"a": 1, "b": [true, null]}"#, #"{"b":[true,null],"a":1}"#, .json))
        #expect(!same(#"{"a": 1}"#, #"{"a": "1"}"#, .json))
        #expect(!same("a", "A", .text) && !same("a", "a ", .text) && !same("", nil, .text) && same(nil, nil, .text))
        #expect(!same("2026-01-01 00:00:00", "2026-01-01 00:00:00.000", .temporal))
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
    }

    @Test func linesAlignSideBySide() {
        let rows = ReconLines.aligned("a\nb\nc\nd", "a\nc\nx\nd")
        #expect(rows.map { "\($0.left ?? "-")\($0.right ?? "-")" } == ["aa", "b-", "cc", "-x", "dd"])
        #expect(ReconLines.aligned("", "").count == 1)
    }
}
