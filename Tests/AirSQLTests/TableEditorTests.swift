import Testing
@testable import AirSQLCore

/// Servers for the generators: MariaDB 11.4, MySQL 8.4 and 5.7.
enum Servers {
    static let mariadb = SchemaServer(version: "11.4.13-MariaDB")
    static let mysql = SchemaServer(version: "8.4.13")
    static let mysql57 = SchemaServer(version: "5.7.44")
}

/// A cached column, as the schema cache reads it.
func cachedColumn(_ name: String, _ columnType: String, nullable: Bool = false, defaultValue: SchemaDefault = .none,
                  autoIncrement: Bool = false, collation: String? = nil, comment: String = "") -> SchemaColumn {
    let dataType = String(columnType.prefix { $0 != "(" && $0 != " " })
    return SchemaColumn(name: name, dataType: dataType, columnType: columnType, nullable: nullable, defaultValue: defaultValue,
                        autoIncrement: autoIncrement, onUpdate: nil, generated: nil, invisible: false,
                        isJSON: dataType == "json", charset: collation.map(TableSQL.charset), collation: collation,
                        comment: comment)
}

/// The mockup's orders table (docs/dev/mockups.html, screen 10), as the cache reads it.
func ordersTable() -> SchemaTable {
    var table = SchemaTable(name: "orders", kind: .table, engine: "InnoDB")
    table.columns = [
        cachedColumn("id", "bigint(20) unsigned", autoIncrement: true),
        cachedColumn("customer_id", "int(10) unsigned"),
        cachedColumn("status", "enum('paid','shipped','refunded')", defaultValue: .value("paid"), collation: "utf8mb4_unicode_ci"),
        cachedColumn("total", "decimal(12,2)"),
        cachedColumn("shipped_on", "datetime", nullable: true, defaultValue: .null),
    ]
    table.indexes = [
        SchemaIndex(name: "PRIMARY", unique: true, type: "BTREE", parts: [.init(column: "id", expression: nil, prefixLength: nil,
                                                                                 descending: false)], visible: true, comment: ""),
        SchemaIndex(name: "by_customer", unique: false, type: "BTREE",
                    parts: [.init(column: "customer_id", expression: nil, prefixLength: nil, descending: false)], visible: true,
                    comment: ""),
    ]
    table.foreignKeys = [SchemaForeignKey(name: "orders_customer", columns: ["customer_id"], referencedDatabase: "shop",
                                          referencedTable: "customers", referencedColumns: ["id"], onUpdate: "RESTRICT",
                                          onDelete: "CASCADE")]
    table.checks = [SchemaCheck(name: "total_positive", clause: "`total` >= 0", enforced: true)]
    return table
}

struct TableEditorTests {
    let options = TableOptions(engine: "InnoDB", collation: "utf8mb4_unicode_ci")

    func design(_ server: SchemaServer = Servers.mariadb) -> TableDesign {
        TableDesign(ordersTable(), options: options, server: server)
    }

    func alter(_ change: (inout TableDesign) -> Void, on server: SchemaServer = Servers.mariadb) throws -> [String] {
        let before = design(server)
        var after = before
        change(&after)
        return try after.statements(database: "shop", from: before, server: server)
    }

    // MARK: Types

    @Test func splitsColumnTypes() {
        #expect(TypeSpec(columnType: "int(10) unsigned zerofill") == TypeSpec(name: "int", length: "10", unsigned: true, zerofill: true))
        #expect(TypeSpec(columnType: "decimal(12,2)") == TypeSpec(name: "decimal", length: "12,2"))
        #expect(TypeSpec(columnType: "enum('a','b''c',')(')") == TypeSpec(name: "enum", length: "'a','b''c',')('"))
        #expect(TypeSpec(columnType: "json") == TypeSpec(name: "json"))
        #expect(TypeSpec(columnType: "bigint unsigned") == TypeSpec(name: "bigint", unsigned: true))
        #expect(TypeSpec(columnType: "TIMESTAMP(3)") == TypeSpec(name: "timestamp", length: "3"))
    }

    @Test func writesTypesAndRefusesWhatNoServerTakes() throws {
        #expect(try TypeSpec(name: "decimal", length: " 12, 2 ", unsigned: true).sql(noBackslashEscapes: false) == "decimal(12,2) unsigned")
        #expect(try TypeSpec(name: "varchar", length: "255", unsigned: true).sql(noBackslashEscapes: false) == "varchar(255)")
        #expect(try TypeSpec(name: "enum", length: "'it''s', 'a\\'b'").sql(noBackslashEscapes: false) == "enum('it\\'s','a\\'b')")
        #expect(try TypeSpec(name: "set", length: "'a\\b'").sql(noBackslashEscapes: true) == "set('a\\b')")
        for bad in [TypeSpec(name: "varchar"), TypeSpec(name: "int", length: "10); DROP TABLE t; --"),
                    TypeSpec(name: "int; DROP TABLE t"), TypeSpec(name: "enum", length: "'a',"), TypeSpec(name: "enum", length: "a"),
                    TypeSpec(name: "enum"), TypeSpec(name: "date", length: "3")] {
            #expect(throws: DesignError.self, "\(bad)") { try bad.sql(noBackslashEscapes: false) }
        }
        for value in Hostile.values {
            let type = TypeSpec(name: "enum", length: SQLQuote.string(value))
            #expect(try TypeSpec.values(type.length, noBackslashEscapes: false) == [value])
            #expect(try type.sql(noBackslashEscapes: false) == "enum(" + SQLQuote.string(value) + ")")
        }
    }

    @Test func listsEachFlavoursTypes() {
        func names(_ version: String) -> [String] { ColumnTypes.all(for: SchemaServer(version: version)).map(\.name) }
        #expect(names("10.5.29-MariaDB").contains("inet6") && !names("10.5.29-MariaDB").contains("uuid"))
        #expect(names("11.4.13-MariaDB").contains("uuid") && names("11.4.13-MariaDB").contains("inet4"))
        #expect(!names("11.4.13-MariaDB").contains("vector") && names("11.8.9-MariaDB").contains("vector"))
        #expect(names("9.7.4").contains("vector") && !names("8.4.13").contains("vector") && !names("8.4.13").contains("inet6"))
        #expect(names("8.4.13").contains("geomcollection") && names("5.7.44").contains("geometrycollection"))
        #expect(ColumnTypes.type("VARCHAR")?.length == .required && ColumnTypes.type("int")?.integer == true)
    }

    // MARK: ALTER

    @Test func nothingChangedIsNoStatement() throws {
        #expect(try alter { _ in }.isEmpty)
        #expect(try alter({ _ in }, on: Servers.mysql).isEmpty)
    }

    @Test func addsAndRenamesColumnsAsTheMockupShows() throws {
        let statements = try alter { table in
            var currency = ColumnDesign(name: "currency", type: TypeSpec(name: "char", length: "3"))
            currency.nullable = false
            currency.defaultValue = .value("EUR")
            currency.collation = "utf8mb4_unicode_ci"
            currency.comment = "ISO 4217"
            table.columns.insert(currency, at: 4)
            table.renameColumn(at: 5, to: "shipped_at")
        }
        #expect(statements == ["""
            ALTER TABLE `shop`.`orders`
              ADD COLUMN `currency` char(3) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'EUR' \
            COMMENT 'ISO 4217' AFTER `total`,
              CHANGE COLUMN `shipped_on` `shipped_at` datetime NULL DEFAULT NULL
            """])
    }

    @Test func positionsOnlyTheColumnsThatMoved() throws {
        // total moves to the front: only it gets a position; the others keep theirs.
        #expect(try alter { $0.columns.insert($0.columns.remove(at: 3), at: 0) } == ["""
            ALTER TABLE `shop`.`orders`
              MODIFY COLUMN `total` decimal(12,2) NOT NULL FIRST
            """])
        // id moves to the end: one column moved, not four.
        let toEnd = try alter { $0.columns.append($0.columns.remove(at: 0)) }
        #expect(toEnd.count == 1 && toEnd[0].hasSuffix("MODIFY COLUMN `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT AFTER `shipped_on`"))
        // A dropped column and a swap.
        let swapped = try alter { table in
            table.removeColumn(at: 4)
            table.columns.swapAt(1, 2)
        }
        #expect(swapped == ["""
            ALTER TABLE `shop`.`orders`
              DROP COLUMN `shipped_on`,
              MODIFY COLUMN `customer_id` int(10) unsigned NOT NULL AFTER `status`
            """])
    }

    @Test func changesIndexesByDroppingAndAddingOrRenaming() throws {
        #expect(try alter { $0.indexes[1].name = "customer" } == ["""
            ALTER TABLE `shop`.`orders`
              RENAME INDEX `by_customer` TO `customer`
            """])
        let changed = try alter { table in
            table.indexes[1].kind = .unique
            table.indexes[0].parts.append(.init(column: "customer_id"))
            table.indexes.append(IndexDesign(name: "by_status", kind: .index, parts: [.init(column: "status", prefixLength: 3,
                                                                                            descending: true)]))
        }
        #expect(changed == ["""
            ALTER TABLE `shop`.`orders`
              DROP PRIMARY KEY,
              DROP INDEX `by_customer`,
              ADD PRIMARY KEY (`id`, `customer_id`),
              ADD UNIQUE INDEX `by_customer` (`customer_id`),
              ADD INDEX `by_status` (`status`(3) DESC)
            """])
        // A renamed column renames itself in its keys on the server: no index or foreign key changes.
        #expect(try alter { $0.renameColumn(at: 1, to: "buyer_id") } == ["""
            ALTER TABLE `shop`.`orders`
              CHANGE COLUMN `customer_id` `buyer_id` int(10) unsigned NOT NULL
            """])
    }

    @Test func dropsAChangedForeignKeyInAStatementOfItsOwn() throws {
        #expect(try alter { $0.foreignKeys[0].onDelete = "SET NULL" } == [
            "ALTER TABLE `shop`.`orders`\n  DROP FOREIGN KEY `orders_customer`",
            "ALTER TABLE `shop`.`orders`\n  ADD CONSTRAINT `orders_customer` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) "
                + "ON DELETE SET NULL ON UPDATE RESTRICT",
        ])
        let other = try alter { table in
            table.foreignKeys = [ForeignKeyDesign(name: "", columns: ["customer_id"], referencedDatabase: "crm",
                                                  referencedTable: "people", referencedColumns: ["id"])]
        }
        #expect(other.last?.hasSuffix("ADD FOREIGN KEY (`customer_id`) REFERENCES `crm`.`people` (`id`) ON DELETE RESTRICT "
                                      + "ON UPDATE RESTRICT") == true)
        #expect(throws: DesignError.self) { try alter { $0.foreignKeys[0].onDelete = "CASCADE; DROP TABLE t" } }
    }

    @Test func changesChecksAsEachFlavourWritesThem() throws {
        #expect(try alter { $0.checks[0].clause = "`total` > 0" } == ["""
            ALTER TABLE `shop`.`orders`
              DROP CONSTRAINT `total_positive`,
              ADD CONSTRAINT `total_positive` CHECK (`total` > 0)
            """])
        #expect(try alter({ $0.checks[0].clause = "`total` > 0" }, on: Servers.mysql).first?.contains("DROP CHECK `total_positive`") == true)
        #expect(try alter({ $0.checks[0].enforced = false }, on: Servers.mysql) == ["""
            ALTER TABLE `shop`.`orders`
              ALTER CHECK `total_positive` NOT ENFORCED
            """])
        #expect(try alter({ $0.checks.append(CheckDesign(name: "", clause: "`id` > 0")) }) == ["""
            ALTER TABLE `shop`.`orders`
              ADD CHECK (`id` > 0)
            """])
    }

    @Test func keepsMariaDBColumnChecksWithTheirColumn() throws {
        var table = ordersTable()
        table.checks.append(SchemaCheck(name: "total", clause: "`total` < 1000000", enforced: true))
        table.columns.append(SchemaColumn(name: "meta", dataType: "longtext", columnType: "longtext", nullable: true,
                                          defaultValue: .null, autoIncrement: false, onUpdate: nil, generated: nil, invisible: false,
                                          isJSON: true, charset: "utf8mb4", collation: "utf8mb4_bin", comment: ""))
        table.checks.append(SchemaCheck(name: "meta", clause: "json_valid(`meta`)", enforced: true))
        let before = TableDesign(table, options: options, columnChecks: ["total", "meta"], server: Servers.mariadb)
        #expect(before.checks.map(\.name) == ["total_positive"])
        #expect(before.columns[3].check == "`total` < 1000000" && before.columns[5].type.name == "json" && before.columns[5].check == nil)
        var after = before
        after.columns[3].type.length = "14,2"
        after.columns[5].comment = "Anything"
        #expect(try after.statements(database: "shop", from: before, server: Servers.mariadb) == ["""
            ALTER TABLE `shop`.`orders`
              MODIFY COLUMN `total` decimal(14,2) NOT NULL CHECK (`total` < 1000000),
              MODIFY COLUMN `meta` json NULL DEFAULT NULL COMMENT 'Anything'
            """])
    }

    @Test func writesDefaultsForEachServer() throws {
        func defaultSQL(_ type: String, _ value: SchemaDefault, nullable: Bool = true, on server: SchemaServer) throws -> String? {
            var column = ColumnDesign(name: "c", type: TypeSpec(columnType: type))
            column.nullable = nullable
            column.defaultValue = value
            return try TableSQL(server: server, database: "d").defaultSQL(column)
        }
        #expect(try defaultSQL("decimal(5,2)", .value("0.00"), on: Servers.mysql) == "0.00")
        #expect(try defaultSQL("varchar(5)", .value("0"), on: Servers.mysql) == "'0'")
        #expect(try defaultSQL("int", .value("1; DROP TABLE t"), on: Servers.mysql) == "'1; DROP TABLE t'")
        #expect(try defaultSQL("char(3)", .value("it's"), on: Servers.mariadb) == "'it\\'s'")
        #expect(try defaultSQL("datetime", .null, nullable: false, on: Servers.mariadb) == nil)
        #expect(try defaultSQL("timestamp(3)", .expression("CURRENT_TIMESTAMP(3)"), on: Servers.mysql) == "CURRENT_TIMESTAMP(3)")
        #expect(try defaultSQL("char(36)", .expression("uuid()"), on: Servers.mysql) == "(uuid())")
        #expect(try defaultSQL("char(36)", .expression("uuid()"), on: Servers.mariadb) == "(uuid())")
        #expect(try defaultSQL("bit(3)", .expression("b'101'"), on: Servers.mysql) == "b'101'")
        #expect(try defaultSQL("datetime", .expression("CURRENT_TIMESTAMP"), on: Servers.mysql57) == "CURRENT_TIMESTAMP")
        var server = Servers.mariadb
        server.noBackslashEscapes = true
        #expect(try defaultSQL("char(3)", .value("a\\'b"), on: server) == "'a\\''b'")
    }

    @Test func changesTableOptionsAndName() throws {
        #expect(try alter { table in
            table.options = TableOptions(engine: "Aria", collation: "utf8mb4_bin", comment: "Orders, paid or not", autoIncrement: 1000,
                                         rowFormat: "dynamic")
            table.name = "sales"
        } == ["""
            ALTER TABLE `shop`.`orders`
              ENGINE=Aria,
              DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin,
              COMMENT='Orders, paid or not',
              AUTO_INCREMENT=1000,
              ROW_FORMAT=DYNAMIC,
              RENAME TO `shop`.`sales`
            """])
        for bad in [TableOptions(engine: "InnoDB; DROP TABLE t"), TableOptions(collation: "x y"), TableOptions(rowFormat: "FAST")] {
            #expect(throws: DesignError.self) { try alter { $0.options = bad } }
        }
    }

    // MARK: CREATE

    @Test func createsATable() throws {
        let table = design(Servers.mysql)
        #expect(try table.statements(database: "shop", from: nil, server: Servers.mysql) == ["""
            CREATE TABLE `shop`.`orders` (
              `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
              `customer_id` int(10) unsigned NOT NULL,
              `status` enum('paid','shipped','refunded') CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'paid',
              `total` decimal(12,2) NOT NULL,
              `shipped_on` datetime NULL DEFAULT NULL,
              PRIMARY KEY (`id`),
              INDEX `by_customer` (`customer_id`),
              CONSTRAINT `orders_customer` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) ON DELETE CASCADE ON UPDATE RESTRICT,
              CONSTRAINT `total_positive` CHECK (`total` >= 0)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            """])
    }

    @Test func refusesDesignsNoServerTakes() {
        let cases: [(inout TableDesign) -> Void] = [
            { $0.name = "" }, { $0.name = "trailing " }, { $0.name = String(repeating: "n", count: 65) },
            { $0.columns[1].name = "ID" }, { $0.columns = [] }, { $0.columns[3].autoIncrement = true },
            { $0.indexes[1].parts = [] }, { $0.indexes[1].parts = [.init(column: "nope")] }, { $0.indexes[1].name = "PRIMARY"; $0.indexes[1].kind = .primary },
            { $0.foreignKeys[0].referencedColumns = [] }, { $0.checks[0].clause = " " }, { $0.columns[2].collation = "x'y" },
            { $0.columns[0].name = "id 😀" }, { $0.columns[0].comment = "🐬" }, { $0.options.comment = "🐬" },
            { $0.columns[2].type.length = "'😀'" }, { $0.columns[2].defaultValue = .value("😀") }, { $0.indexes[1].name = "🐬" },
        ]
        for change in cases {
            #expect(throws: DesignError.self) { try alter(change) }
        }
    }

    @Test func quotesHostileNamesAndValuesEverywhere() throws {
        for name in Hostile.names where !name.trimmingCharacters(in: .whitespaces).isEmpty && !name.unicodeScalars.contains(where: { $0.value > 0xFFFF }) {
            var table = TableDesign(name: name)
            var column = ColumnDesign(name: name, type: TypeSpec(name: "enum", length: SQLQuote.string(name)))
            column.comment = name
            column.defaultValue = .value(name)
            table.columns = [column]
            table.indexes = [IndexDesign(name: name, kind: .unique, parts: [.init(column: name)])]
            table.foreignKeys = [ForeignKeyDesign(name: name, columns: [name], referencedDatabase: name, referencedTable: name,
                                                  referencedColumns: [name])]
            table.checks = [CheckDesign(name: name, clause: "1")]
            table.options.comment = name
            let sql = try table.statements(database: name + "db", from: nil, server: Servers.mariadb).joined()
            let quoted = SQLQuote.identifier(name), text = SQLQuote.string(name)
            // What is left once every quoted name and value is taken out has none of the hostile text in it.
            let rest = sql.replacingOccurrences(of: SQLQuote.identifier(name + "db"), with: "")
                .replacingOccurrences(of: quoted, with: "").replacingOccurrences(of: text, with: "")
            #expect(!rest.contains(name) || name.count < 3, "\(name): \(rest)")
            // As read from the server, then renamed with a column changed.
            table.columns[0].original = name
            table.indexes[0].original = name
            table.foreignKeys[0].original = name
            table.checks[0].original = name
            var renamed = table
            let newName = String(name.prefix(60)) + "2"
            renamed.name = newName
            renamed.columns[0].comment = ""
            let alter = try renamed.statements(database: name + "db", from: table, server: Servers.mysql).joined()
            #expect(alter.contains("RENAME TO " + SQLQuote.identifier(name + "db", newName)))
            let left = alter.replacingOccurrences(of: SQLQuote.identifier(name + "db"), with: "")
                .replacingOccurrences(of: SQLQuote.identifier(newName), with: "")
                .replacingOccurrences(of: quoted, with: "").replacingOccurrences(of: text, with: "")
            #expect(!left.contains(name) || name.count < 3, "\(name): \(left)")
        }
    }

    // MARK: Cell text

    @Test func writesAndReadsTheCellsText() throws {
        #expect(EditorText.names(["id", "order date", "a`b"]) == "id, `order date`, `a``b`")
        #expect(EditorText.names(from: " id , `order date`,`a``b`, ,x") == ["id", "order date", "a`b", "x"])
        let parts: [IndexDesign.Part] = [.init(column: "email", prefixLength: 10), .init(column: "made at", descending: true),
                                         .init(column: nil, expression: "lower(`name`), 1", descending: false)]
        #expect(EditorText.parts(parts) == "email(10), `made at` DESC, (lower(`name`), 1)")
        #expect(try EditorText.parts(from: EditorText.parts(parts)) == parts)
        #expect(try EditorText.parts(from: "`f(1)`, b asc") == [.init(column: "f(1)"), .init(column: "b")])
        #expect(throws: DesignError.self) { try EditorText.parts(from: "email(x)") }
        for (value, numeric, text) in [(SchemaDefault.none, false, ""), (.null, false, "NULL"), (.value("0.00"), true, "0.00"),
                                       (.value("0"), false, "'0'"), (.value("it's"), false, "'it\\'s'"),
                                       (.expression("CURRENT_TIMESTAMP(3)"), false, "CURRENT_TIMESTAMP(3)")] {
            #expect(EditorText.defaultValue(value, numeric: numeric, noBackslashEscapes: false) == text)
            let back = EditorText.defaultValue(from: text, noBackslashEscapes: false)
            #expect(back == value || (back == .value("0") && value == .value("0")), "\(text)")
        }
        #expect(EditorText.qualified(from: "crm.`people.v2`") == ("crm", "people.v2"))
        #expect(EditorText.qualified(from: " people ") == (nil, "people"))
        #expect(EditorText.defaultValue(from: "null", noBackslashEscapes: false) == .null)
        #expect(EditorText.defaultValue(from: "'a' 'b'", noBackslashEscapes: false) == .expression("'a' 'b'"))
        #expect(EditorText.defaultValue(from: "-1.5", noBackslashEscapes: false) == .value("-1.5"))
    }
}
