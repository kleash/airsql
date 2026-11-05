import Testing
@testable import AirSQLCore

/// Answers SHOW CREATE and the editors' queries from a table of canned rows (by the statement's first words).
final class CannedSource: SchemaQuerying, @unchecked Sendable {
    var answers: [String: [[String?]]]
    private(set) var sent: [String] = []

    init(_ answers: [String: [[String?]]]) { self.answers = answers }

    func rows(_ sql: String) async throws -> [[String?]] {
        sent.append(sql)
        return answers.first { sql.hasPrefix($0.key) }?.value ?? []
    }
}

struct ObjectCodeTests {
    @Test func readsTheHeaderOfEveryKind() throws {
        let view = try #require(CreateHeader("CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW "
                                             + "`paid_orders` AS select 1"))
        #expect(view.kind == .view && !view.orReplace && view.name == "paid_orders" && view.definerAccount == "root@localhost")
        let function = try #require(CreateHeader("create or replace /* c */ definer = 'it''s'@'%' aggregate function if not exists "
                                                 + "shop.`my``fn`(x INT) RETURNS INT RETURN x"))
        #expect(function.kind == .function && function.orReplace && function.database == "shop" && function.name == "my`fn")
        #expect(function.definerAccount == "it's@%")
        let trigger = try #require(CreateHeader("-- note\nCREATE DEFINER=CURRENT_USER() TRIGGER customers_before_insert BEFORE"))
        #expect(trigger.kind == .trigger && trigger.definerAccount == "CURRENT_USER" && trigger.name == "customers_before_insert")
        #expect(CreateHeader("CREATE EVENT e ON SCHEDULE EVERY 1 DAY DO SELECT 1")?.definer == nil)
        for bad in ["SELECT 1", "CREATE TABLE t (id INT)", "CREATE OR VIEW v AS SELECT 1", "CREATE DEFINER VIEW v", "", "CREATE VIEW"] {
            #expect(CreateHeader(bad) == nil, "\(bad)")
        }
    }

    @Test func setsOrRemovesTheDefiner() {
        let code = "CREATE ALGORITHM=MERGE DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `v` AS select 1"
        #expect(ObjectCode.settingDefiner(code, to: nil) == "CREATE ALGORITHM=MERGE SQL SECURITY DEFINER VIEW `v` AS select 1")
        #expect(ObjectCode.settingDefiner(code, to: "`app`@`%`")
                == "CREATE ALGORITHM=MERGE DEFINER=`app`@`%` SQL SECURITY DEFINER VIEW `v` AS select 1")
        let bare = "CREATE ALGORITHM=MERGE SQL SECURITY DEFINER VIEW `v` AS select 1"
        #expect(ObjectCode.settingDefiner(bare, to: "`app`@`%`") == code.replacingOccurrences(of: "`root`@`localhost`", with: "`app`@`%`"))
        #expect(ObjectCode.settingDefiner("CREATE PROCEDURE p() SELECT 1", to: "`a`@`b`") == "CREATE DEFINER=`a`@`b` PROCEDURE p() SELECT 1")
        #expect(ObjectCode.quotedAccount("air`sql@%") == "`air``sql`@`%`")
        #expect(ObjectCode.quotedAccount("odd@name@localhost") == "`odd@name`@`localhost`")
    }

    @Test func replacesInOneStepWhereTheServerCan() throws {
        let mode = ObjectDefinition(code: "", sqlMode: "STRICT_TRANS_TABLES")
        let code = "CREATE DEFINER=`root`@`localhost` FUNCTION `greeting`(p VARCHAR(5)) RETURNS varchar(9)\nRETURN p"
        #expect(try ObjectCode.statements(code, kind: .function, database: "shop", original: "greeting", definition: mode,
                                          server: Servers.mariadb) == [
            "USE `shop`", "SET SESSION sql_mode = 'STRICT_TRANS_TABLES'",
            "CREATE OR REPLACE DEFINER=`root`@`localhost` FUNCTION `greeting`(p VARCHAR(5)) RETURNS varchar(9)\nRETURN p",
        ])
        #expect(try ObjectCode.statements(code, kind: .function, database: "shop", original: "GREETING", definition: mode,
                                          server: Servers.mysql) == [
            "USE `shop`", "SET SESSION sql_mode = 'STRICT_TRANS_TABLES'", "DROP FUNCTION IF EXISTS `shop`.`GREETING`", code,
        ])
        #expect(ObjectCode.dropsFirst(.function, server: Servers.mysql) && !ObjectCode.dropsFirst(.view, server: Servers.mysql))
        let view = "CREATE OR REPLACE VIEW `paid` AS select 1"
        #expect(try ObjectCode.statements(view, kind: .view, database: "shop", original: "paid_orders", definition: nil,
                                          server: Servers.mysql) == ["USE `shop`", view, "DROP VIEW IF EXISTS `shop`.`paid_orders`"])
        let event = ObjectDefinition(code: "", sqlMode: "", timeZone: "+00:00")
        #expect(try ObjectCode.statements("CREATE EVENT e ON SCHEDULE EVERY 1 DAY DO SELECT 1", kind: .event, database: "d", original: nil,
                                          definition: event, server: Servers.mysql) == [
            "USE `d`", "SET SESSION sql_mode = ''", "SET SESSION time_zone = '+00:00'", "CREATE EVENT e ON SCHEDULE EVERY 1 DAY DO SELECT 1",
        ])
    }

    @Test func refusesCodeThatDoesntFitTheEditor() {
        let cases: [(String, ObjectKind)] = [("SELECT 1", .view), ("CREATE PROCEDURE p() SELECT 1", .function),
                                             ("CREATE VIEW other.v AS SELECT 1", .view)]
        for (code, kind) in cases {
            #expect(throws: DesignError.self, "\(code)") {
                try ObjectCode.statements(code, kind: kind, database: "shop", original: "v", definition: nil, server: Servers.mysql)
            }
        }
    }

    @Test func startsNewObjectsFromCodeThatParses() throws {
        for kind in ObjectKind.allCases {
            let code = ObjectCode.template(kind, name: "new `\(kind.rawValue)`", table: "order details")
            let header = try #require(CreateHeader(code), "\(code)")
            #expect(header.kind == kind && header.name == "new `\(kind.rawValue)`")
        }
    }

    @Test func readsTheCodeAndSettingsThatShowCreateGives() async throws {
        let source = CannedSource(["SHOW CREATE EVENT": [["e", "STRICT_ALL_TABLES", "SYSTEM", "CREATE EVENT e ON SCHEDULE AT NOW() DO SELECT 1",
                                                          "utf8mb4", "utf8mb4_bin", "utf8mb4_bin"]],
                                   "SHOW CREATE VIEW": [["v", "CREATE VIEW v AS select 1", "utf8mb4", "utf8mb4_bin"]],
                                   "SHOW CREATE PROCEDURE": [["p", "", nil, "utf8mb4", "utf8mb4_bin", "utf8mb4_bin"]]])
        let event = try await ObjectDefinition.load(.event, database: "d", name: "e`x", from: source)
        #expect(event == ObjectDefinition(code: "CREATE EVENT e ON SCHEDULE AT NOW() DO SELECT 1", sqlMode: "STRICT_ALL_TABLES",
                                          timeZone: "SYSTEM"))
        #expect(source.sent == ["SHOW CREATE EVENT `d`.`e``x`"])
        #expect(try await ObjectDefinition.load(.view, database: "d", name: "v", from: source).sqlMode == nil)
        await #expect(throws: DesignError.self) { try await ObjectDefinition.load(.procedure, database: "d", name: "p", from: source) }
    }

    @Test func readsTableOptionsCollationsAndEngines() async throws {
        let source = CannedSource([
            "SELECT ENGINE, TABLE_COLLATION": [["InnoDB", "utf8mb4_bin", "it's", "41", "Dynamic"]],
            "SELECT CONSTRAINT_NAME": [["price"]],
            "SELECT FULL_COLLATION_NAME": [["utf8mb4_uca1400_ai_ci", "utf8mb4", "Yes"], ["latin1_swedish_ci", "latin1", "Yes"]],
            "SELECT ENGINE, SUPPORT": [["MyISAM", "YES"], ["InnoDB", "DEFAULT"], ["Aria", "YES"]],
        ])
        let (options, checks) = try await EditorQueries.table("sh'op", "t", server: Servers.mariadb, from: source)
        #expect(options == TableOptions(engine: "InnoDB", collation: "utf8mb4_bin", comment: "it's", autoIncrement: 41, rowFormat: "Dynamic"))
        #expect(checks == ["price"])
        #expect(source.sent.first?.contains("TABLE_SCHEMA = 'sh\\'op'") == true)
        #expect(try await EditorQueries.collations(server: Servers.mariadb, from: source).map(\.name)
                == ["latin1_swedish_ci", "utf8mb4_uca1400_ai_ci"])
        #expect(try await EditorQueries.engines(from: source) == ["InnoDB", "Aria", "MyISAM"])
        let old = try await EditorQueries.table("d", "t", server: SchemaServer(version: "10.5.5-MariaDB"), from: source)
        #expect(old.columnChecks == nil)
    }
}

struct DDLScriptTests {
    let server = SchemaServer(version: "11.8.2-MariaDB")
    let mysql = SchemaServer(version: "8.4.0")
    let table = """
        CREATE TABLE `orders` (
          `id` int NOT NULL AUTO_INCREMENT,
          `customer` int NOT NULL,
          PRIMARY KEY (`id`),
          UNIQUE KEY `one` (`customer`),
          KEY `two` (`id`),
          CONSTRAINT `fk` FOREIGN KEY (`customer`) REFERENCES `customers` (`id`)
        ) ENGINE=InnoDB AUTO_INCREMENT=41 DEFAULT CHARSET=utf8mb4
        """

    func item(_ kind: DatabaseObject.Kind, _ name: String, _ code: String, table: String? = nil) -> DDLScript.Item {
        DDLScript.Item(DatabaseObject(kind, "shop", name), code: code, table: table)
    }

    @Test func leavesOutWhatTheOptionsSay() {
        var options = DDLScript.Options()
        options.indexes = false
        options.foreignKeys = false
        options.autoIncrement = false
        options.ifNotExists = true
        options.databaseNames = true
        #expect(DDLScript([item(.table, "orders", table)], options: options, server: server).text == """
            CREATE TABLE IF NOT EXISTS `shop`.`orders` (
              `id` int NOT NULL AUTO_INCREMENT,
              `customer` int NOT NULL,
              PRIMARY KEY (`id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

            """)
    }

    @Test func rewritesObjectsAsEachServerTakes() {
        let view = item(.view, "v", "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `shop`.`v` AS select 1")
        let routine = item(.procedure, "p", "CREATE DEFINER=`root`@`%` PROCEDURE `p`()\nBEGIN\n  SELECT 1;\nEND")
        var options = DDLScript.Options()
        options.skipDefiner = true
        options.orReplace = true
        #expect(DDLScript([view], options: options, server: mysql).text
                == "CREATE OR REPLACE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `v` AS select 1;\n")
        #expect(DDLScript([routine], options: options, server: mysql).text
                == "DELIMITER ;;\nCREATE PROCEDURE `p`()\nBEGIN\n  SELECT 1;\nEND;;\nDELIMITER ;\n", "MySQL can't replace a routine")
        #expect(DDLScript([routine], options: options, server: server).text.contains("CREATE OR REPLACE PROCEDURE `p`()"))
        options.orReplace = false
        options.ifNotExists = true
        let event = item(.event, "e", "CREATE EVENT `e` ON SCHEDULE EVERY 1 DAY DO SELECT 1")
        #expect(DDLScript([event], options: options, server: mysql).text == "CREATE EVENT IF NOT EXISTS `e` ON SCHEDULE EVERY 1 DAY DO SELECT 1;\n")
    }

    @Test func ordersTheScriptAndTurnsKeyChecksOffForTables() {
        let items = [item(.trigger, "t", "CREATE TRIGGER `t` BEFORE INSERT ON `orders` FOR EACH ROW SET @a = 1", table: "orders"),
                     item(.view, "v", "CREATE VIEW `v` AS select 1"), item(.table, "orders", table),
                     item(.table, "b", "CREATE TABLE `b` (\n  `id` int\n)")]
        let text = DDLScript(items, server: server).text
        #expect(text.hasPrefix("SET FOREIGN_KEY_CHECKS = 0;\n\nCREATE TABLE `orders`") && text.hasSuffix("SET FOREIGN_KEY_CHECKS = 1;\n"))
        #expect(text.range(of: "VIEW `v`")!.lowerBound < text.range(of: "TRIGGER `t`")!.lowerBound)
        var options = DDLScript.Options()
        options.triggers = false
        #expect(!DDLScript(items, options: options, server: server).text.contains("TRIGGER"), "only a table's own triggers are optional")
    }

    @Test func filesStayInTheFolderAndDifferByMoreThanCase() {
        let items = [item(.table, "../../etc/passwd", "CREATE TABLE `x` (\n  `a` int\n)"), item(.table, "Foo", "CREATE TABLE `Foo` (\n  `a` int\n)"),
                     item(.table, "foo", "CREATE TABLE `foo` (\n  `a` int\n)"), item(.procedure, "p", "CREATE PROCEDURE `p`() SELECT 1")]
        let script = DDLScript(items, server: server)
        #expect(script.files(.flat).map(\.path) == ["_._.._etc_passwd.sql", "Foo.sql", "foo-2.sql", "p.sql"])
        #expect(script.files(.byKind).last?.path == "procedures/p.sql")
        #expect(script.files(.byDatabase).last?.path == "shop/procedures/p.sql")
        #expect(script.files(.numbered).map(\.path).last == "004_p.sql")
        #expect(script.files(.flat).first?.text.hasSuffix(");\n") == true)
    }

    @Test func readsEachKindsColumn() async throws {
        let source = CannedSource(["SHOW CREATE TABLE": [["t", "CREATE TABLE `t` (\n)"]],
                                   "SHOW CREATE EVENT": [["e", "", "UTC", "CREATE EVENT `e`", "", "", ""]]])
        let items = try await DDLScript.load([DatabaseObject(.table, "shop", "t"), DatabaseObject(.event, "shop", "e")], from: source)
        #expect(items.map(\.code) == ["CREATE TABLE `t` (\n)", "CREATE EVENT `e`"])
    }
}

struct TableOptionsSQLTests {
    let server = SchemaServer(version: "11.8.2-MariaDB")

    func table() -> TableDesign {
        var table = TableDesign(name: "t")
        var id = ColumnDesign(name: "id", type: TypeSpec(name: "int"))
        id.original = "id"
        table.columns = [id]
        return table
    }

    @Test func readsThePartitionClauseOfEitherServer() {
        let mysql = "CREATE TABLE `t` (\n  `id` int\n) ENGINE=InnoDB COMMENT='PARTITION BY nothing'\n/*!50100 PARTITION BY HASH (`id`)\nPARTITIONS 4 */"
        #expect(EditorQueries.partitionClause(mysql, noBackslashEscapes: false) == "PARTITION BY HASH (`id`)\nPARTITIONS 4")
        let mariadb = "CREATE TABLE `t` (\n  `id` int\n) ENGINE=InnoDB\n PARTITION BY RANGE (`id`)\n(PARTITION `p0` VALUES LESS THAN (10) ENGINE = InnoDB)"
        #expect(EditorQueries.partitionClause(mariadb, noBackslashEscapes: false)
                == "PARTITION BY RANGE (`id`)\n(PARTITION `p0` VALUES LESS THAN (10) ENGINE = InnoDB)")
        #expect(EditorQueries.partitionClause("CREATE TABLE `t` (\n  `id` int\n) COMMENT='PARTITION BY x'", noBackslashEscapes: false) == nil)
    }

    @Test func writesPartitionsInCreateAndAStatementOfTheirOwn() throws {
        var new = table()
        new.options.partitioning = "  PARTITION BY HASH (id) PARTITIONS 2\n"
        #expect(try new.statements(database: "d", from: nil, server: server).first?.hasSuffix("\n)\nPARTITION BY HASH (id) PARTITIONS 2") == true)
        var renamed = new
        renamed.name = "u"
        renamed.options.comment = "x"
        let statements = try renamed.statements(database: "d", from: table(), server: server)
        #expect(statements.count == 2 && statements[1] == "ALTER TABLE `d`.`u`\n  PARTITION BY HASH (id) PARTITIONS 2")
        #expect(try table().statements(database: "d", from: new, server: server) == ["ALTER TABLE `d`.`t`\n  REMOVE PARTITIONING"])
        var same = new
        same.options.partitioning = "PARTITION BY HASH (id) PARTITIONS 2"
        #expect(try same.statements(database: "d", from: new, server: server).isEmpty)
    }

    @Test func writesHowAnIndexIsStored() throws {
        var hash = IndexDesign(name: "h", kind: .index, parts: [.init(column: "id")])
        hash.algorithm = "HASH"
        var old = table()
        hash.original = "h"
        old.indexes = [hash]
        var new = old
        new.indexes[0].algorithm = "BTREE"
        #expect(try new.statements(database: "d", from: old, server: server)
                == ["ALTER TABLE `d`.`t`\n  DROP INDEX `h`,\n  ADD INDEX `h` (`id`) USING BTREE"])
        new.indexes[0].kind = .fulltext
        #expect(try new.statements(database: "d", from: old, server: server).first?.contains("USING") == false)
        new.indexes[0].kind = .index
        new.indexes[0].algorithm = "NOPE; DROP TABLE t"
        #expect(throws: DesignError.self) { try new.statements(database: "d", from: old, server: server) }
    }

    @Test func keepsBTREEOnMemoryTablesOnly() {
        var table = SchemaTable(name: "t", kind: .table, engine: "MEMORY")
        table.indexes = [SchemaIndex(name: "a", unique: false, type: "BTREE",
                                     parts: [.init(column: "id", expression: nil, prefixLength: nil, descending: false)], visible: true, comment: "")]
        #expect(TableDesign(table, options: TableOptions(engine: "MEMORY"), server: server).indexes[0].algorithm == "BTREE")
        #expect(TableDesign(table, options: TableOptions(engine: "InnoDB"), server: server).indexes[0].algorithm == nil)
    }
}
