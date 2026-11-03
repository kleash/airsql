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
}
