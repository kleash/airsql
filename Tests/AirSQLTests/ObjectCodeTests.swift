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
