import Testing
@testable import AirSQLCore

/// The navigator's statements, with hostile names and values: every name stays one quoted name.
struct NavigatorSQLTests {
    let orders = DatabaseObject(.table, "shop", "orders")

    @Test func databaseStatements() {
        #expect(NavigatorSQL.createDatabase("shop", charset: "utf8mb4", collation: "utf8mb4_unicode_ci")
                == "CREATE DATABASE `shop` CHARACTER SET `utf8mb4` COLLATE `utf8mb4_unicode_ci`")
        #expect(NavigatorSQL.createDatabase("shop", charset: nil, collation: "") == "CREATE DATABASE `shop`")
        #expect(NavigatorSQL.dropDatabase("my`db") == "DROP DATABASE `my``db`")
    }

    @Test func tableStatements() {
        #expect(NavigatorSQL.rename(orders, to: "old orders") == "RENAME TABLE `shop`.`orders` TO `shop`.`old orders`")
        #expect(NavigatorSQL.truncate([orders, DatabaseObject(.table, "shop", "items")])
                == ["TRUNCATE TABLE `shop`.`orders`", "TRUNCATE TABLE `shop`.`items`"])
        #expect(NavigatorSQL.move([orders], to: "archive") == "RENAME TABLE `shop`.`orders` TO `archive`.`orders`")
        #expect(NavigatorSQL.changeEngine(orders, to: "InnoDB") == "ALTER TABLE `shop`.`orders` ENGINE = `InnoDB`")
        #expect(NavigatorSQL.convert(orders, charset: "utf8mb4", collation: "utf8mb4_bin")
                == "ALTER TABLE `shop`.`orders` CONVERT TO CHARACTER SET `utf8mb4` COLLATE `utf8mb4_bin`")
        #expect(NavigatorSQL.maintenance(.optimize, [orders, DatabaseObject(.table, "shop", "items")])
                == "OPTIMIZE TABLE `shop`.`orders`, `shop`.`items`")
        #expect(NavigatorSQL.showCreate(DatabaseObject(.event, "shop", "nightly")) == "SHOW CREATE EVENT `shop`.`nightly`")
    }

    @Test func dropsTriggersBeforeTablesAndTablesTogether() {
        let objects = [orders, DatabaseObject(.view, "shop", "v"), DatabaseObject(.trigger, "shop", "t1"),
                       DatabaseObject(.table, "shop", "items"), DatabaseObject(.procedure, "shop", "p")]
        #expect(NavigatorSQL.drop(objects) == ["DROP TRIGGER `shop`.`t1`", "DROP PROCEDURE `shop`.`p`", "DROP VIEW `shop`.`v`",
                                               "DROP TABLE `shop`.`orders`, `shop`.`items`"])
    }

    @Test func copiesTheDefinitionThenTheRowsOfTheColumnsGiven() {
        #expect(NavigatorSQL.copyTable(orders, to: "archive", name: "orders_2026", columns: nil, where: "id > 5")
                == ["CREATE TABLE `archive`.`orders_2026` LIKE `shop`.`orders`"])
        #expect(NavigatorSQL.copyTable(orders, to: "archive", name: "o", columns: ["id", "total"], where: "  id > 5 \n")
                == ["CREATE TABLE `archive`.`o` LIKE `shop`.`orders`",
                    "INSERT INTO `archive`.`o` (`id`, `total`) SELECT `id`, `total` FROM `shop`.`orders` WHERE id > 5"])
        #expect(NavigatorSQL.copyTable(orders, to: "s", name: "o", columns: ["id"], where: " ").last
                == "INSERT INTO `s`.`o` (`id`) SELECT `id` FROM `shop`.`orders`")
    }

    @Test func hostileNamesStayOneName() {
        for name in Hostile.names {
            let object = DatabaseObject(.table, name, name)
            let quoted = SQLQuote.identifier(name)
            #expect(NavigatorSQL.dropDatabase(name) == "DROP DATABASE " + quoted)
            #expect(NavigatorSQL.drop([object]) == ["DROP TABLE \(quoted).\(quoted)"])
            #expect(NavigatorSQL.rename(object, to: name) == "RENAME TABLE \(quoted).\(quoted) TO \(quoted).\(quoted)")
            #expect(NavigatorSQL.countContaining("x", in: object, columns: [name], noBackslashEscapes: false)
                    == "SELECT COUNT(*) FROM \(quoted).\(quoted) WHERE \(quoted) LIKE '%x%' ESCAPE '!'")
        }
    }

    @Test func findTextMatchesOnlyTheTextItself() {
        #expect(NavigatorSQL.containsPattern("50%_off!") == "%50!%!_off!!%")
        #expect(NavigatorSQL.contains("it's", columns: ["a", "b"], noBackslashEscapes: false)
                == "`a` LIKE '%it\\'s%' ESCAPE '!' OR `b` LIKE '%it\\'s%' ESCAPE '!'")
        #expect(NavigatorSQL.contains("C:\\x", columns: ["a"], noBackslashEscapes: true) == "`a` LIKE '%C:\\x%' ESCAPE '!'")
        for value in Hostile.values {
            let pattern = NavigatorSQL.containsPattern(value)
            #expect(NavigatorSQL.contains(value, columns: ["c"], noBackslashEscapes: false)
                    == "`c` LIKE \(SQLQuote.string(pattern)) ESCAPE '!'")
        }
    }

    /// What the navigator reads (on the schema session, or Find Text's and the process list's own) passes the read-only
    /// check, whatever the names, so the agents' gate never asks about it.
    @Test(arguments: [false, true])
    func itsReadsAreReadOnly(noBackslashEscapes: Bool) {
        var reads = [NavigatorSQL.characterSets, NavigatorSQL.collations, NavigatorSQL.serverCharset, NavigatorSQL.engines,
                     NavigatorSQL.processList(mariaDB: true), NavigatorSQL.processList(mariaDB: false)]
        for name in Hostile.names {
            let process = ServerProcess(id: 7, user: name, host: name, database: name, command: "Query", time: 1, state: nil,
                                        info: name, queryID: 9)
            reads += DatabaseObject.Kind.allCases.map { NavigatorSQL.showCreate(DatabaseObject($0, name, name)) }
            reads += [NavigatorSQL.stillRunning(process, noBackslashEscapes: noBackslashEscapes),
                      NavigatorSQL.stillConnected(process, noBackslashEscapes: noBackslashEscapes),
                      NavigatorSQL.countContaining(name, in: DatabaseObject(.table, name, name), columns: [name, "b"],
                                                   noBackslashEscapes: noBackslashEscapes)]
        }
        for sql in reads {
            #expect(ReadOnlyClassifier.classify(sql, noBackslashEscapes: noBackslashEscapes) == .readOnly, "\(sql)")
        }
    }

    @Test func processListAndKill() {
        #expect(NavigatorSQL.processList(mariaDB: true).contains("QUERY_ID FROM information_schema.PROCESSLIST"))
        #expect(!NavigatorSQL.processList(mariaDB: false).contains("QUERY_ID"))
        let rows: [[String?]] = [["12", "app", "10.0.0.5:5050", nil, "Query", "3", "Sending data", "SELECT 1", "77"],
                                 ["x", "bad", "", nil, "", "", nil, nil, nil], ["13", "app", "h", "shop", "Sleep", "9", "", nil]]
        let processes = NavigatorSQL.processes(rows)
        #expect(processes.map(\.id) == [12, 13])
        #expect(processes[0].queryID == 77 && processes[0].info == "SELECT 1" && processes[1].state == nil)
        #expect(NavigatorSQL.killQuery(processes[0]) == "KILL QUERY ID 77")
        #expect(NavigatorSQL.killQuery(processes[1]) == "KILL QUERY 13")
        #expect(NavigatorSQL.killConnection(processes[1]) == "KILL CONNECTION 13")
        #expect(NavigatorSQL.stillRunning(processes[0], noBackslashEscapes: false)
                == "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID = 12 AND INFO = 'SELECT 1' AND QUERY_ID = 77")
        var hostile = processes[1]
        hostile.user = "x'; KILL 1; --"
        #expect(NavigatorSQL.stillConnected(hostile, noBackslashEscapes: true)
                == "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID = 13 AND USER = 'x''; KILL 1; --' AND HOST = 'h'")
    }

    /// Generate SELECT, INSERT and UPDATE from the cached tables: the server's own columns (auto-increment, generated) left
    /// out of what is written, the key naming the row, `?` for each value to fill in.
    @Test func generatesStatementsFromTheCachedColumns() async throws {
        let snapshot = try await SchemaTests.loaded(SchemaFixtures.mariadb118).0.snapshot
        func table(_ name: String) throws -> (DatabaseObject, SchemaTable) {
            (DatabaseObject(.table, "airsql_fixture", name), try #require(snapshot.table("airsql_fixture", name)))
        }
        let (orders, ordersTable) = try table("orders")
        #expect(NavigatorSQL.select(orders, ordersTable.columns)
                == "SELECT `id`, `customer_id`, `region`, `number`, `total`, `parent_id`\nFROM `airsql_fixture`.`orders`;")
        #expect(NavigatorSQL.select(orders, []) == "SELECT *\nFROM `airsql_fixture`.`orders`;")
        #expect(NavigatorSQL.insert(orders, ordersTable.columns)
                == "INSERT INTO `airsql_fixture`.`orders` (`customer_id`, `region`, `number`, `total`, `parent_id`)\nVALUES (?, ?, ?, ?, ?);")
        #expect(NavigatorSQL.update(orders, ordersTable) == "UPDATE `airsql_fixture`.`orders`\n"
                + "SET `customer_id` = ?, `region` = ?, `number` = ?, `total` = ?, `parent_id` = ?\nWHERE `id` = ?;")
        let (customers, customersTable) = try table("customers")
        let insert = NavigatorSQL.insert(customers, customersTable.columns)
        #expect(insert.hasPrefix("INSERT INTO `airsql_fixture`.`customers` (`email`, `name`,") && insert.contains("`secret`"))
        #expect(!insert.contains("`id`") && !insert.contains("`email_domain`") && !insert.contains("`name_upper`"))
        #expect(!NavigatorSQL.update(customers, customersTable).contains("`name_upper` ="))
        let (lines, linesTable) = try table("order_lines")
        #expect(NavigatorSQL.update(lines, linesTable)
                == "UPDATE `airsql_fixture`.`order_lines`\nSET `qty` = ?\nWHERE `region` = ? AND `number` = ? AND `line` = ?;")
        // No key names a row: the condition is the person's to write.
        let (log, logTable) = try table("log")
        #expect(NavigatorSQL.update(log, logTable) == "UPDATE `airsql_fixture`.`log`\nSET `at` = ?, `message` = ?\nWHERE ?;")
        let (weird, weirdTable) = try table("we`ird 'name' ✓")
        #expect(NavigatorSQL.select(weird, weirdTable.columns)
                == "SELECT `col ``1`, `naïve \"x\"`\nFROM `airsql_fixture`.`we``ird 'name' ✓`;")
    }

    /// Run…: a CALL with `?` for each IN value (named and typed beside it), OUT and INOUT values in user variables read
    /// back; a function in a SELECT. A name can't end the comment it is put in.
    @Test func runsRoutinesWithTheirParametersToFillIn() {
        let procedure = DatabaseObject(.procedure, "fixture", "customer_orders")
        #expect(NavigatorSQL.run(procedure, [.init(mode: "IN", name: "p_customer", type: "int"),
                                             .init(mode: "OUT", name: "p_count", type: "int")])
                == "CALL `fixture`.`customer_orders`(? /* p_customer int */, @`p_count`);\nSELECT @`p_count`;")
        #expect(NavigatorSQL.run(procedure, [.init(mode: "INOUT", name: "total", type: "decimal(12,2)")])
                == "SET @`total` = ? /* total decimal(12,2) */;\nCALL `fixture`.`customer_orders`(@`total`);\nSELECT @`total`;")
        #expect(NavigatorSQL.run(procedure, []) == "CALL `fixture`.`customer_orders`();")
        #expect(NavigatorSQL.run(DatabaseObject(.function, "fixture", "greeting"), [.init(mode: "IN", name: "p_name", type: "varchar(50)")])
                == "SELECT `fixture`.`greeting`(? /* p_name varchar(50) */);")
        let hostile = NavigatorSQL.run(procedure, [.init(mode: "IN", name: "a */ DROP TABLE t; /*", type: "int"),
                                                   .init(mode: "OUT", name: "b`; DROP TABLE t; --", type: "int")])
        #expect(hostile == "CALL `fixture`.`customer_orders`(? /* a * / DROP TABLE t; /* int */, @`b``; DROP TABLE t; --`);"
                + "\nSELECT @`b``; DROP TABLE t; --`;")
        #expect(NavigatorSQL.parameters(DatabaseObject(.function, "it's", "f"), noBackslashEscapes: false)
                == "SELECT PARAMETER_MODE, PARAMETER_NAME, DTD_IDENTIFIER FROM information_schema.PARAMETERS WHERE SPECIFIC_SCHEMA = "
                + "'it\\'s' AND SPECIFIC_NAME = 'f' AND ROUTINE_TYPE = 'FUNCTION' AND ORDINAL_POSITION > 0 ORDER BY ORDINAL_POSITION")
    }
}
