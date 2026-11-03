import Foundation
import Testing
@testable import AirSQLCore

/// The Liquibase writer (plan §3: unit tests against golden files): changesets and their attributes, dependency order,
/// rollbacks, ids, the three sources (a schema, a compare, a previewed change), and the formatted SQL reader that
/// checks what AirSQL writes as Liquibase reads it. Golden files are in Tests/Golden; AIRSQL_GOLDEN=1 writes them anew.
struct LiquibaseTests {
    static let date = Date(timeIntervalSince1970: 1_793_620_800)  // 2026-11-02 12:00 UTC

    static var settings: LiquibaseSettings {
        var settings = LiquibaseSettings()
        settings.author = "deploy"
        return settings
    }

    /// A shop as MariaDB's SHOW CREATE writes it, with the hard cases: a table whose name holds SQL, a table that
    /// points at itself, views reading views, a routine whose comment Liquibase would read as a --rollback line, a
    /// sequence, a trigger and an event.
    static let shop = LiquibaseSchema(database: "shop", objects: [
        .init(kind: .table, name: "orders", create: """
            CREATE TABLE `orders` (
              `id` bigint(20) NOT NULL AUTO_INCREMENT,
              `customer_id` int(11) NOT NULL,
              `total` decimal(12,2) NOT NULL DEFAULT 0.00,
              `note` varchar(200) DEFAULT NULL /*!80023 INVISIBLE */,
              PRIMARY KEY (`id`),
              KEY `fk_orders_customer` (`customer_id`),
              CONSTRAINT `fk_orders_customer` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) ON DELETE CASCADE
            ) ENGINE=InnoDB AUTO_INCREMENT=42 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci
            """, references: ["customers"]),
        .init(kind: .table, name: "customers", create: """
            CREATE TABLE `customers` (
              `id` int(11) NOT NULL,
              `name` varchar(50) NOT NULL,
              `referred_by` int(11) DEFAULT NULL,
              PRIMARY KEY (`id`),
              KEY `fk_referrer` (`referred_by`),
              CONSTRAINT `fk_referrer` FOREIGN KEY (`referred_by`) REFERENCES `customers` (`id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci
            """),
        .init(kind: .table, name: "x`; DROP TABLE nothing; --", create: """
            CREATE TABLE `x``; DROP TABLE nothing; --` (
              `id` int(11) NOT NULL,
              PRIMARY KEY (`id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci
            """),
        .init(kind: .sequence, name: "invoice_numbers", create: """
            CREATE SEQUENCE `invoice_numbers` start with 1000 minvalue 1 maxvalue 9223372036854775806 increment by 1 cache 1000 \
            nocycle ENGINE=InnoDB
            """),
        .init(kind: .view, name: "big_spenders", create: """
            CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `big_spenders` AS select `t`.`customer_id` \
            AS `customer_id` from `order_totals` `t` where `t`.`total` > 1000
            """),
        .init(kind: .view, name: "order_totals", create: """
            CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `order_totals` AS select `orders`.`customer_id` \
            AS `customer_id`,sum(`orders`.`total`) AS `total` from `orders` group by `orders`.`customer_id`
            """),
        .init(kind: .function, name: "refund_total", create: """
            CREATE DEFINER=`root`@`%` FUNCTION `refund_total`(p_order BIGINT) RETURNS decimal(12,2)
                READS SQL DATA
            BEGIN
              DECLARE t DECIMAL(12,2);
              -- rollback nothing here: this only reads
              SELECT total INTO t FROM orders WHERE id = p_order;
              IF t IS NULL THEN RETURN 0; END IF;
              RETURN t;
            END
            """),
        .init(kind: .procedure, name: "touch", create: "CREATE DEFINER=`root`@`%` PROCEDURE `touch`()\nSELECT 1"),
        .init(kind: .trigger, name: "orders_bi", create: """
            CREATE DEFINER=`root`@`%` TRIGGER `orders_bi` BEFORE INSERT ON `orders` FOR EACH ROW BEGIN
              IF NEW.total < 0 THEN SET NEW.total = 0; END IF;
            END
            """),
        .init(kind: .event, name: "nightly", create: """
            CREATE DEFINER=`root`@`%` EVENT `nightly` ON SCHEDULE EVERY 1 DAY STARTS '2037-01-01 00:00:00' ON COMPLETION NOT \
            PRESERVE DISABLE DO DELETE FROM orders WHERE total = 0
            """),
        .init(kind: .procedure, name: "secret", create: ""),
    ])

    // MARK: Golden files

    static let goldenFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Golden")

    /// `text` matches the golden file `name` (written when it is missing or AIRSQL_GOLDEN=1).
    func golden(_ name: String, _ text: String) throws {
        let url = Self.goldenFolder.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["AIRSQL_GOLDEN"] == "1" || !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: Self.goldenFolder, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            Issue.record("Wrote the golden file \(name): check it, then run the tests again")
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(text == expected, "\(name) differs from its golden file")
    }

    /// The changelog of `pieces` (rows left out: they come from a server), checked by reading it back.
    func changelog(_ pieces: [LiquibasePiece], _ settings: LiquibaseSettings = settings) throws -> String {
        let changesets = Liquibase.numbered(pieces.compactMap { piece -> LiquibaseChangeset? in
            if case .changeset(let changeset) = piece { return changeset }
            return nil
        }, settings: settings, date: Self.date)
        let text = Liquibase.changelog(changesets, delimiter: settings.delimiter)
        let read = try LiquibaseChangelog(text)
        #expect(read.changesets.map(\.id) == changesets.map(\.id))
        for (written, back) in zip(changesets, read.changesets) {
            #expect(back.statements == written.statements.map(Liquibase.guarded), "\(written.id)")
            #expect(back.rollbackStatements == written.rollback, "\(written.id)")
            #expect(back.author == "deploy")
        }
        return text
    }

    @Test func schemaChangelogMatchesItsGoldenFile() throws {
        try golden("liquibase-shop.sql", changelog(Self.shop.pieces(.structure, rows: [], settings: Self.settings)))
        var slashes = Self.settings
        slashes.delimiter = .slashes
        slashes.stripDefiner = false
        slashes.rollback = false
        try golden("liquibase-shop-slashes.sql", changelog(Self.shop.pieces(.structure, rows: [], settings: slashes,
                                                                              preconditions: true), slashes))
    }

    @Test func schemaPiecesRunInDependencyOrder() {
        let pieces = Self.shop.pieces(.both, rows: ["orders", "customers"], settings: Self.settings)
        let order = pieces.map { piece -> String in
            if case .rows(let table) = piece { return "rows " + table }
            return piece.object
        }
        #expect(order == ["invoice_numbers", "customers", "orders", "x`; DROP TABLE nothing; --", "rows customers", "rows orders",
                          "fk_referrer", "fk_orders_customer", "refund_total", "touch", "order_totals", "big_spenders",
                          "orders_bi", "nightly"])
        #expect(Self.shop.pieces(.data, rows: ["orders", "customers"], settings: Self.settings)
                == [.rows(table: "customers"), .rows(table: "orders")])
    }

    // MARK: Changesets

    @Test func attributesOnlyWhereNeeded() throws {
        var plain = LiquibaseChangeset(object: "t", statements: ["CREATE TABLE `t` (`a` int);", "INSERT INTO `t` VALUES (1)"],
                                       rollback: ["DROP TABLE `t`"], comment: "Make t\nand fill it")
        plain.author = "me"
        plain.id = "1"
        #expect(try plain.checkedText() == """
            --changeset me:1
            --comment: Make t and fill it
            CREATE TABLE `t` (`a` int);
            INSERT INTO `t` VALUES (1);
            --rollback DROP TABLE `t`;

            """)
        var routine = LiquibaseChangeset(object: "p", statements: ["CREATE PROCEDURE `p`() BEGIN SELECT 1; SELECT 2; END"])
        routine.author = "me"
        routine.id = "2"
        #expect(try routine.checkedText().hasPrefix("--changeset me:2 splitStatements:false\nCREATE PROCEDURE"))
        #expect(try routine.checkedText(.slashes) == "--changeset me:2 endDelimiter://\nCREATE PROCEDURE `p`() BEGIN SELECT 1; SELECT 2; END\n//\n")
        routine.statements.insert("DROP PROCEDURE IF EXISTS `p`", at: 0)
        #expect(try routine.checkedText().hasPrefix("--changeset me:2 endDelimiter://\nDROP PROCEDURE IF EXISTS `p`\n//\nCREATE"))
        var commented = LiquibaseChangeset(object: "t", statements: ["CREATE TABLE `t` (`a` int /*!80023 INVISIBLE */)"])
        commented.author = "me"
        commented.id = "3"
        #expect(try commented.checkedText().hasPrefix("--changeset me:3 stripComments:false\n"))
    }

    @Test func commentsLiquibaseWouldObeyBecomeHashComments() throws {
        let body = "CREATE PROCEDURE `p`()\nBEGIN\n  -- rollback the order: done by the caller\n  SELECT '-- rollback kept';\nEND"
        #expect(Liquibase.guarded(body) == body.replacingOccurrences(of: "  -- rollback the order", with: "  # rollback the order"))
        #expect(Liquibase.guarded("SELECT 1 -- changeset in a comment after code") == "SELECT 1 -- changeset in a comment after code")
        #expect(Liquibase.guarded("-- changeset a:b\nSELECT 1") == "# changeset a:b\nSELECT 1")
    }

    @Test func rollbacksThatCanBeWritten() {
        let cases: [(String, String?)] = [
            ("CREATE TABLE `t` (`a` int)", "DROP TABLE `t`"),
            ("CREATE TABLE IF NOT EXISTS `t` (`a` int)", nil),
            ("CREATE TEMPORARY TABLE t (a int)", nil),
            ("CREATE ALGORITHM=UNDEFINED DEFINER=`u`@`%` SQL SECURITY DEFINER VIEW `v` AS select 1", "DROP VIEW `v`"),
            ("CREATE OR REPLACE VIEW `v` AS select 1", nil),
            ("CREATE DEFINER=`root`@`localhost` PROCEDURE `shop`.`p`() SELECT 1", "DROP PROCEDURE `shop`.`p`"),
            ("create function f() returns int return 1", "DROP FUNCTION f"),
            ("CREATE TRIGGER `t1` BEFORE INSERT ON `t` FOR EACH ROW SET NEW.a = 1", "DROP TRIGGER `t1`"),
            ("CREATE EVENT e ON SCHEDULE EVERY 1 DAY DO SELECT 1", "DROP EVENT e"),
            ("CREATE UNIQUE INDEX `ix` ON `t` (`a`)", "DROP INDEX `ix` ON `t`"),
            ("ALTER TABLE `t` ADD COLUMN `c` int NULL AFTER `b`, ADD KEY `ix_c` (`c`)",
             "ALTER TABLE `t` DROP INDEX `ix_c`, DROP COLUMN `c`"),
            ("ALTER TABLE `orders`\n  ADD CONSTRAINT `fk` FOREIGN KEY (`c`) REFERENCES `customers` (`id`)",
             "ALTER TABLE `orders` DROP FOREIGN KEY `fk`"),
            ("ALTER TABLE t ADD CONSTRAINT `chk` CHECK (a > 0)", "ALTER TABLE t DROP CONSTRAINT `chk`"),
            ("ALTER TABLE t ADD UNIQUE KEY `u` (a, b)", "ALTER TABLE t DROP INDEX `u`"),
            ("ALTER TABLE t ADD PRIMARY KEY (a)", nil),
            ("ALTER TABLE t ADD COLUMN c int, MODIFY COLUMN d bigint", nil),
            ("ALTER TABLE t ADD UNIQUE (a)", nil),
            ("RENAME TABLE `a` TO `b`, `c` TO `d`", "RENAME TABLE `d` TO `c`, `b` TO `a`"),
            ("DROP TABLE `t`", nil),
            ("INSERT INTO t VALUES (1)", nil),
        ]
        for (statement, rollback) in cases { #expect(Liquibase.rollback(statement) == rollback, "\(statement)") }
    }

    @Test func idsFollowThePatternAndStayUnique() {
        var settings = Self.settings
        let sets = ["customers", "x`; DROP TABLE nothing; --", "טבלה", ""].map { LiquibaseChangeset(object: $0, statements: ["SELECT 1"]) }
        #expect(Liquibase.numbered(sets, settings: settings, first: 7, date: Self.date).map(\.id)
                == ["20261102-007-customers", "20261102-008-x___DROP_TABLE_nothing__--", "20261102-009-טבלה", "20261102-010-change"])
        settings.ids = "{object}"
        settings.author = " a:b "
        let numbered = Liquibase.numbered(Array(sets.prefix(1)) + Array(sets.prefix(1)), settings: settings, taken: ["customers"],
                                          date: Self.date)
        #expect(numbered.map(\.id) == ["customers-2", "customers-3"])
        #expect(numbered.allSatisfy { $0.author == "ab" })
        #expect(Liquibase.master(["a.sql", "b \"c\".sql"]) == """
            databaseChangeLog:
              - include:
                  file: "a.sql"
                  relativeToChangelogFile: true
              - include:
                  file: "b \\"c\\".sql"
                  relativeToChangelogFile: true

            """)
    }

    // MARK: Sources

    @Test func aPreviewedChangeBecomesOnePortableChangeset() throws {
        let editor = ChangeSQL(title: "Replace procedure shop.p", statements: [
            "USE `shop`", "SET SESSION sql_mode = 'STRICT_TRANS_TABLES'", "DROP PROCEDURE IF EXISTS `shop`.`p`",
            "CREATE PROCEDURE `p`() BEGIN SELECT '`shop`.`kept`'; END",
        ], connection: UUID())
        let routine = Liquibase.changeset(editor)
        #expect(routine.statements == [Liquibase.sessionSave, "SET SESSION sql_mode = 'STRICT_TRANS_TABLES'", "DROP PROCEDURE IF EXISTS `p`",
                                       "CREATE PROCEDURE `p`() BEGIN SELECT '`shop`.`kept`'; END", Liquibase.sessionTail])
        #expect(routine.rollback.isEmpty && routine.comment == "Replace procedure shop.p" && routine.object == "p")
        let table = Liquibase.changeset(ChangeSQL(title: "Change table shop.orders", statements: [
            "ALTER TABLE `shop`.`orders`\n  ADD COLUMN `paid` tinyint(1) NOT NULL DEFAULT 0 AFTER `total`;",
            "ALTER TABLE `shop`.`orders`\n  ADD CONSTRAINT `fk_x` FOREIGN KEY (`x`) REFERENCES `shop`.`x` (`id`)",
        ], connection: UUID()))
        #expect(table.statements.first == "ALTER TABLE `orders`\n  ADD COLUMN `paid` tinyint(1) NOT NULL DEFAULT 0 AFTER `total`")
        #expect(table.rollback == ["ALTER TABLE `orders` DROP FOREIGN KEY `fk_x`", "ALTER TABLE `orders` DROP COLUMN `paid`"])
        let grid = Liquibase.changeset(ChangeSQL(title: "Apply 2 changes", statements: [
            "START TRANSACTION", "UPDATE `t` SET `a` = 'x' WHERE `id` = 1", "commit"], connection: UUID()))
        #expect(grid.statements == ["UPDATE `t` SET `a` = 'x' WHERE `id` = 1"] && grid.rollback.isEmpty)
        // The console's statements, typed without backticks: the database leaves those names too, but not other names.
        let console = Liquibase.changeset(title: "Query 1", statements: [
            "CREATE TABLE IF NOT EXISTS shop.notes (id INT PRIMARY KEY)", "INSERT INTO shop.notes VALUES (1)",
            "UPDATE event SET event.n = shop.f(1)"])
        #expect(console.statements == ["CREATE TABLE IF NOT EXISTS notes (id INT PRIMARY KEY)", "INSERT INTO notes VALUES (1)",
                                       "UPDATE event SET event.n = f(1)"])
        #expect(console.object == "notes")
        #expect(Liquibase.changeset(title: "Query 1", statements: ["UPDATE event SET event.n = 1"]).object == "event")
        #expect(Liquibase.changeset(title: "Query 1", statements: ["CREATE TABLE shop.t (id INT)"]).rollback == ["DROP TABLE t"])
        var numbered = Liquibase.numbered([grid], settings: Self.settings, first: 4, date: Self.date)[0]
        numbered.statements.append("UPDATE t SET begin = 1")  // an unquoted BEGIN keeps Liquibase from splitting there
        #expect(throws: LiquibaseChangelog.Problem.self) { try numbered.checkedText() }
    }

    @Test func aCompareBecomesChangesetsPerStepAndTableRun() throws {
        var customers = ReconObject(kind: .table, name: "customers", status: .onlyInSource)
        customers.sourceDDL = "CREATE TABLE `customers` (\n  `id` int(11) NOT NULL,\n  PRIMARY KEY (`id`)\n) ENGINE=InnoDB"
        var data = ReconTableData(outcome: .different)
        data.key = ["id"]
        data.columns = [ReconColumn(name: "id", kind: .integer), ReconColumn(name: "name", kind: .text)]
        data.missing = (1...150).map { ReconRow([Array("\($0)".utf8), Array("it's \($0)".utf8)]) }
        customers.data = data
        var view = ReconObject(kind: .view, name: "v", status: .onlyInSource)
        view.sourceDDL = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `v` AS select 1 AS `1`"
        let gone = ReconObject(kind: .procedure, name: "old", status: .onlyInTarget)
        let result = ReconResult(source: ReconEnd(name: "Dev", database: "shop", version: "11.8.9-MariaDB"),
                                 target: ReconEnd(name: "Prod", database: "shop", version: "11.8.9-MariaDB"),
                                 options: ReconOptions(), objects: [customers, view, gone])
        let safe = Liquibase.changesets(result, destructive: false)
        #expect(safe.map(\.object) == ["customers", "v", "customers"])
        #expect(safe[0].rollback == ["DROP TABLE `customers`"] && safe[1].rollback.isEmpty)
        #expect(safe[2].statements.count == 2 + 2 + 1)  // the session settings, two INSERTs of 100 and 50 rows, the settings back
        let all = Liquibase.changesets(result, destructive: true)
        #expect(all.first?.comment == "Destructive: drops it" && all.first?.statements == ["DROP PROCEDURE IF EXISTS `old`"])
        try golden("liquibase-recon.sql", changelog(Liquibase.changesets(result, destructive: true).map { .changeset($0) }))
    }

    // MARK: Reading changelogs

    @Test func readsChangelogsAsLiquibaseDoes() throws {
        let text = """
            --liquibase formatted sql
            -- Written by hand; comment lines that aren't --comment are fine out here

            --changeset Ann Lee:"id one" runOnChange:true
            --comment: first
            CREATE TABLE a (x int);
            INSERT INTO a VALUES (';'), ("--rollback"); INSERT INTO a VALUES (2);
            --rollback DROP TABLE a;
            --changeset bob:2 endDelimiter:// stripComments:false
            CREATE PROCEDURE p() BEGIN SELECT 1; END//
            CREATE PROCEDURE q() BEGIN /* keep */ SELECT 2; END
            //
            /* liquibase rollback
            DROP PROCEDURE p;
            DROP PROCEDURE q;
            */
            --changeset bob:3 splitStatements:false
            --preconditions onFail:MARK_RAN
            --precondition-sql-check expectedResult:0 SELECT COUNT(*) FROM t
            CREATE TRIGGER t1 BEFORE INSERT ON a FOR EACH ROW BEGIN SET NEW.x = 1; END
            """
        let read = try LiquibaseChangelog(text).changesets
        #expect(read.map(\.author) == ["Ann Lee", "bob", "bob"] && read.map(\.id) == ["id one", "2", "3"])
        #expect(read[0].runOnChange && read[0].comment == "first")
        #expect(read[0].statements == ["CREATE TABLE a (x int)", "INSERT INTO a VALUES (';'), (\"--rollback\")", "INSERT INTO a VALUES (2)"])
        #expect(read[0].rollbackStatements == ["DROP TABLE a"])
        #expect(read[1].statements == ["CREATE PROCEDURE p() BEGIN SELECT 1; END", "CREATE PROCEDURE q() BEGIN /* keep */ SELECT 2; END"])
        #expect(read[1].rollbackStatements == ["DROP PROCEDURE p", "DROP PROCEDURE q"])
        #expect(read[2].preconditions && read[2].statements.count == 1)
        #expect(LiquibaseChangelog.split("SELECT 1 /*!80023 x */, 2 -- c\n; SELECT 3", splitStatements: true, stripComments: true,
                                         endDelimiter: nil) == ["SELECT 1 , 2", "SELECT 3"])
    }

    @Test func refusesWhatLiquibaseRefuses() {
        let bad: [(String, Int)] = [
            ("CREATE TABLE a (x int);", 1),
            ("--liquibase formatted sql\n--comment: outside\n--changeset a:1\nSELECT 1;", 2),
            ("--liquibase formatted sql\n--changeset a:1\n--changeset a:2\nSELECT 1;", 2),
            ("--liquibase formatted sql\n--changeset a: 1\nSELECT 1;", 2),
            ("--liquibase formatted sql\n--changeset a:1\nSELECT 1;\n-rollback x", 4),
            ("--liquibase formatted sql\n--changeset a:1\nSELECT 1;\n--changeset a:1\nSELECT 2;", 4),
            ("--liquibase formatted sql\n--changeset a:1\n--precondition-table-missing x\nSELECT 1;", 3),
            ("--liquibase formatted sql\n--changeset a:1\nSELECT 1; -- property of the shop\n-- property tax\n", 4),
        ]
        for (text, line) in bad {
            #expect(throws: LiquibaseChangelog.Problem.self, "\(text)") { try LiquibaseChangelog(text) }
            #expect((try? LiquibaseChangelog(text)) == nil)
            do { _ = try LiquibaseChangelog(text) } catch let problem as LiquibaseChangelog.Problem {
                #expect(problem.line == line, "\(text)")
            } catch {}
        }
    }
}
