import Foundation
import Testing
@testable import AirSQLCore

/// Pending changes (plan §2.5, grid-spec §5): edits, new rows and deletes by key, undo, the statements Apply runs and
/// the rows each must change, the rollback when one changes another number, which tables can be edited, and the copy
/// kept on disk for a crash.
struct PendingChangesTests {
    static let columns = [GridColumn(name: "id", type: "int", kind: .number, isKey: true), GridColumn(name: "name", type: "varchar(20)"),
                          GridColumn(name: "price", type: "decimal", kind: .number)]

    func sql(_ changes: PendingChanges, noBackslashEscapes: Bool = false) throws -> [String] {
        try changes.statements(database: "shop", table: "items", columns: Self.columns, noBackslashEscapes: noBackslashEscapes).map(\.sql)
    }

    @Test func editsInsertsAndDeletesBecomeStatementsInOrder() throws {
        var changes = PendingChanges(keyColumns: ["id"])
        changes.set(.text("Bob"), column: "name", key: ["2"], original: "Bo")
        changes.set(.text("9.90"), column: "price", key: ["2"], original: "9")
        changes.set(.null, column: "name", key: ["1"], original: "Ann")
        changes.delete([["7"], ["5"]])
        let id = changes.addRow(["name": .text("Cy"), "price": .default])
        changes.addRow()
        #expect(changes.rowCount == 6)
        let statements = try changes.statements(database: "shop", table: "items", columns: Self.columns, noBackslashEscapes: false)
        #expect(statements.map(\.sql) == [
            "DELETE FROM `shop`.`items` WHERE `id` IN (5, 7)",
            "UPDATE `shop`.`items` SET `name` = NULL WHERE `id` = 1 AND `name` <=> 'Ann'",
            "UPDATE `shop`.`items` SET `name` = 'Bob', `price` = 9.90 WHERE `id` = 2 AND `name` <=> 'Bo' AND `price` <=> 9",
            "INSERT INTO `shop`.`items` (`name`, `price`) VALUES ('Cy', DEFAULT)",
            "INSERT INTO `shop`.`items` () VALUES ()",
        ])
        #expect(statements.map(\.expectedRows) == [2, 1, 1, 1, 1])
        #expect(statements[0].target == .delete([["5"], ["7"]]))
        #expect(statements[3].target == .insert(id))
    }

    @Test func settingTheLoadedValueAgainDropsTheEdit() throws {
        var changes = PendingChanges(keyColumns: ["id"])
        changes.set(.text("x"), column: "name", key: ["1"], original: "Ann")
        changes.set(.text("Ann"), column: "name", key: ["1"], original: "Ann")
        #expect(changes.isEmpty)
        changes.set(.null, column: "name", key: ["1"], original: nil)
        #expect(changes.isEmpty)
        changes.set(.text(""), column: "name", key: ["1"], original: nil)  // an empty text isn't NULL
        #expect(changes.value(["1"], "name") == .text(""))
    }

    @Test func deletedRowsAreNotUpdatedAndNewRowsJustGo() throws {
        var changes = PendingChanges(keyColumns: ["id"])
        changes.set(.text("x"), column: "name", key: ["1"], original: "Ann")
        let id = changes.addRow()
        changes.delete([["1"]], inserts: [id])
        #expect(try sql(changes) == ["DELETE FROM `shop`.`items` WHERE `id` IN (1)"])
        changes.revert([["1"]])
        #expect(changes.isEmpty)
    }

    @Test func undoAndRedoStepThroughChanges() {
        var changes = PendingChanges(keyColumns: ["id"])
        changes.set(.text("a"), column: "name", key: ["1"], original: nil)
        changes.set(.text("b"), column: "name", key: ["1"], original: nil)
        changes.undo()
        #expect(changes.value(["1"], "name") == .text("a"))
        changes.undo()
        #expect(changes.isEmpty && !changes.canUndo && changes.canRedo)
        changes.redo()
        #expect(changes.value(["1"], "name") == .text("a"))
        changes.delete([["1"]])
        #expect(!changes.canRedo)
        changes.revertAll()
        changes.undo()
        #expect(changes.isDeleted(["1"]))
    }

    @Test func editsNameTheValueTheyReplaceWhereItComparesExactly() throws {
        let columns = [GridColumn(name: "id", type: "int", kind: .number), GridColumn(name: "note", type: "text"),
                       GridColumn(name: "ratio", type: "float", kind: .number), GridColumn(name: "rate", type: "double", kind: .number),
                       GridColumn(name: "at", type: "timestamp(3)", kind: .date), GridColumn(name: "day", type: "date", kind: .date),
                       GridColumn(name: "doc", type: "json", kind: .json), GridColumn(name: "spot", type: "point", kind: .binary),
                       GridColumn(name: "pic", type: "blob", kind: .binary)]
        func update(_ column: String, original: String?) throws -> (sql: String, unchecked: [String]) {
            var changes = PendingChanges(keyColumns: ["id"])
            changes.set(.text("0"), column: column, key: ["1"], original: original)
            let sql = try changes.statements(database: "d", table: "t", columns: columns, noBackslashEscapes: false)[0].sql
            return (sql, changes.uncheckedColumns(columns))
        }
        #expect(try update("rate", original: "0.1").sql.hasSuffix("WHERE `id` = 1 AND `rate` <=> 0.1"))
        #expect(try update("pic", original: "0x00FF").sql.hasSuffix("AND `pic` <=> X'00FF'"))
        #expect(try update("day", original: "2024-02-10").sql.hasSuffix("AND `day` <=> '2024-02-10'"))
        for (column, value) in [("ratio", "0.1"), ("at", "2024-01-01 00:00:00.000"), ("doc", "{}"), ("spot", "0x00"),
                                ("day", "0000-00-00"), ("day", "2024-02-00")] {
            let unchecked = try update(column, original: value)
            #expect(unchecked.sql.hasSuffix("WHERE `id` = 1") && unchecked.unchecked == [column])
            // NULL compares in any column.
            #expect(try update(column, original: nil).sql.hasSuffix("AND `\(column)` <=> NULL"))
        }
        let long = try update("note", original: String(repeating: "x", count: PendingChanges.originalLimit + 1))
        #expect(long.sql.hasSuffix("WHERE `id` = 1") && long.unchecked == ["note"])

        // A key's edit is checked by the key; the first edit's original stands; going back to it forgets it.
        var changes = PendingChanges(keyColumns: ["id"])
        changes.set(.text("2"), column: "id", key: ["1"], original: "1")
        changes.set(.text("a"), column: "note", key: ["1"], original: "was")
        changes.set(.text("b"), column: "note", key: ["1"], original: "reloaded")
        #expect(try changes.statements(database: "d", table: "t", columns: columns, noBackslashEscapes: false)[0].sql
                == "UPDATE `d`.`t` SET `id` = 2, `note` = 'b' WHERE `id` = 1 AND `note` <=> 'was'")
        #expect(changes.uncheckedColumns(columns).isEmpty)
        changes.set(.text("reloaded"), column: "note", key: ["1"], original: "reloaded")
        #expect(changes.state.originals[["1"]]?["note"] == nil)
        changes.revert([["1"]])
        #expect(changes.state.originals.isEmpty)
    }

    @Test func savedChangesKeepWhatTheyReplaceAndOldOnesStillLoad() throws {
        var changes = PendingChanges(keyColumns: ["id"])
        changes.set(.text("a"), column: "name", key: ["1"], original: nil)
        let state = try JSONDecoder().decode(PendingChanges.State.self, from: JSONEncoder().encode(changes.state))
        #expect(state == changes.state && state.originals[["1"]]?["name"] == .null)
        // 1.0.0's file: nothing to compare with, so its edits go by the key and the preview says so.
        let old = try JSONDecoder().decode(PendingChanges.State.self, from: Data(#"{"edits":[["1"],{"name":{"text":{"_0":"a"}}}],"inserts":[],"deletes":[]}"#.utf8))
        let restored = PendingChanges(keyColumns: ["id"], state: old)
        #expect(try sql(restored) == ["UPDATE `shop`.`items` SET `name` = 'a' WHERE `id` = 1"])
        #expect(restored.uncheckedColumns(Self.columns) == ["name"])
    }

    @Test func compositeKeysAndBatchesOfFiveHundred() throws {
        var changes = PendingChanges(keyColumns: ["shop", "sku"])
        changes.delete((0..<1_001).map { ["1", String(format: "s%04d", $0)] })
        changes.set(.text("x"), column: "name", key: ["2", "it's"], original: nil)
        let statements = try changes.statements(database: "db", table: "t", columns: [GridColumn(name: "shop", kind: .number)],
                                            noBackslashEscapes: false)
        #expect(statements.map(\.expectedRows) == [500, 500, 1, 1])
        #expect(statements[0].sql.hasPrefix("DELETE FROM `db`.`t` WHERE (`shop`, `sku`) IN ((1, 's0000'), (1, 's0001'), "))
        #expect(statements[3].sql == "UPDATE `db`.`t` SET `name` = 'x' WHERE `shop` = 2 AND `sku` = 'it\\'s' AND `name` <=> NULL")
    }

    @Test(arguments: [false, true])
    func hostileValuesAndNamesStayQuoted(noBackslashEscapes: Bool) throws {
        for value in Hostile.names {
            var changes = PendingChanges(keyColumns: [value])
            changes.set(.text(value), column: value, key: [value], original: nil)
            let quotedName = SQLQuote.identifier(value), quoted = SQLQuote.string(value, noBackslashEscapes: noBackslashEscapes)
            let statements = try changes.statements(database: value, table: value, columns: [], noBackslashEscapes: noBackslashEscapes)
            #expect(statements.map(\.sql) == ["UPDATE \(SQLQuote.identifier(value, value)) SET \(quotedName) = \(quoted) "
                                              + "WHERE \(quotedName) = \(quoted)"])
        }
    }

    @Test func applyRollsBackOnAMismatchOrAnError() async throws {
        var changes = PendingChanges(keyColumns: ["id"])
        changes.set(.text("x"), column: "name", key: ["1"], original: nil)
        changes.set(.text("y"), column: "name", key: ["2"], original: nil)
        let statements = try changes.statements(database: "shop", table: "items", columns: Self.columns, noBackslashEscapes: false)
        var ran: [String] = []
        try await PendingChanges.apply(statements) { sql in
            ran.append(sql)
            return 1
        }
        #expect(ran == ["START TRANSACTION"] + statements.map(\.sql) + ["COMMIT"])
        ran = []
        let failure = await #expect(throws: ApplyFailure.self) {
            try await PendingChanges.apply(statements) { sql in
                ran.append(sql)
                return sql.contains("`id` = 2") ? 0 : 1
            }
        }
        #expect(ran == ["START TRANSACTION"] + statements.map(\.sql) + ["ROLLBACK"])
        #expect(failure?.statement.target == .update(["2"]) && failure?.changed == 0)
        #expect(failure?.errorDescription?.hasPrefix("This row was changed or deleted by someone else") == true)
        ran = []
        let refused = await #expect(throws: ApplyFailure.self) {
            try await PendingChanges.apply(statements) { sql in
                ran.append(sql)
                if sql.hasPrefix("UPDATE") { throw AirSQLError(.duplicate, "Duplicate entry 'x' for key 'name'.") }
                return 0
            }
        }
        #expect(ran == ["START TRANSACTION", statements[0].sql, "ROLLBACK"])
        #expect(refused?.errorDescription == "Duplicate entry 'x' for key 'name'. Nothing was applied.")
    }

    @Test func aFailureFindsTheColumnTheServerNames() {
        var table = SchemaTable(name: "items", kind: .table, engine: "InnoDB")
        table.columns = [cachedColumn("id", "int"), cachedColumn("name", "varchar(20)"), cachedColumn("owner", "int")]
        table.indexes = [SchemaIndex(name: "by_name", unique: true, type: "BTREE",
                                     parts: [.init(column: "name", expression: nil, prefixLength: nil, descending: false)],
                                     visible: true, comment: "")]
        func column(_ code: Int, _ text: String) -> String? {
            let error = ErrorMapping.map(code: code, message: text, mariaDB: true)
            return ApplyFailure(statement: .init(sql: "", expectedRows: 1, target: .update(["1"])), changed: nil, error: error).column(in: table)
        }
        #expect(column(1406, "Data too long for column 'name' at row 1") == "name")
        #expect(column(1366, "Incorrect integer value: 'name' for column `shop`.`items`.`owner` at row 1") == "owner")
        #expect(column(1048, "Column 'owner' cannot be null") == "owner")
        #expect(column(1364, "Field 'id' doesn't have a default value") == "id")
        #expect(column(1452, "Cannot add or update a child row: a foreign key constraint fails (`shop`.`items`, CONSTRAINT `fk` "
                       + "FOREIGN KEY (`owner`) REFERENCES `people` (`id`))") == "owner")
        #expect(column(1062, "Duplicate entry 'x' for key 'items.by_name'") == "name")
        #expect(column(1062, "Duplicate entry 'x' for key 'PRIMARY'") == nil)
        #expect(column(1054, "Unknown column 'gone' in 'field list'") == nil)
        #expect(column(1136, "Column count doesn't match value count at row 1") == nil)
        // A value refused before anything ran names its column itself.
        var changes = PendingChanges(keyColumns: ["id"])
        changes.set(.text("x"), column: "owner", key: ["1"], original: nil)
        do {
            _ = try changes.statements(database: "shop", table: "items", columns: Self.columns, noBackslashEscapes: false) { _, _ in
                throw EditError("Not a whole number")
            }
            Issue.record("the value wasn't refused")
        } catch let failure as ApplyFailure {
            #expect(failure.column(in: table) == "owner")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func onlyTablesWithAKeyCanBeEdited() {
        func index(_ name: String, unique: Bool = true, _ columns: [String]) -> SchemaIndex {
            SchemaIndex(name: name, unique: unique, type: "BTREE",
                        parts: columns.map { .init(column: $0, expression: nil, prefixLength: nil, descending: false) },
                        visible: true, comment: "")
        }
        var table = SchemaTable(name: "t", kind: .table, engine: "InnoDB")
        table.columns = [cachedColumn("a", "int"), cachedColumn("b", "int", nullable: true), cachedColumn("c", "int")]
        #expect(table.editingKey == nil && TableDataSource(database: "d", table: table).key == nil)
        #expect(table.editingRefusal?.contains("no primary key") == true)
        table.indexes = [index("ub", ["b"]), index("ix", unique: false, ["c"]), index("uac", ["a", "c"])]
        #expect(table.editingKey == ["a", "c"])  // b can be NULL; ix isn't unique
        #expect(TableDataSource(database: "d", table: table).key == [0, 2])
        table.indexes.append(index("PRIMARY", ["c"]))
        #expect(table.editingKey == ["c"])
        var view = SchemaTable(name: "v", kind: .view)
        view.columns = table.columns
        #expect(view.editingRefusal?.hasPrefix("A view") == true && TableDataSource(database: "d", table: view).key == nil)
    }

    @Test func previewWarnsAboutEnginesAndCascades() {
        func table(_ name: String, engine: String = "InnoDB", parent: String? = nil, onDelete: String = "CASCADE") -> SchemaTable {
            var table = SchemaTable(name: name, kind: .table, engine: engine)
            if let parent {
                table.foreignKeys = [SchemaForeignKey(name: "fk", columns: ["p"], referencedDatabase: "shop", referencedTable: parent,
                                                      referencedColumns: ["id"], onUpdate: "RESTRICT", onDelete: onDelete)]
            }
            return table
        }
        var shop = SchemaDatabase(name: "shop", charset: "utf8mb4", collation: "utf8mb4_bin")
        shop.tables = [table("orders"), table("lines", parent: "orders"), table("notes", parent: "lines", onDelete: "SET NULL"),
                       table("audit", parent: "orders", onDelete: "RESTRICT"), table("log", engine: "MyISAM")]
        var snapshot = SchemaSnapshot()
        snapshot.databases = [shop]
        #expect(TableEditing.warnings(shop.tables[0], database: "shop", deleting: false, in: snapshot).isEmpty)
        #expect(TableEditing.warnings(shop.tables[0], database: "shop", deleting: true, in: snapshot)
                == ["Deleting rows also changes lines (rows deleted), notes (set to NULL) through their foreign keys."])
        #expect(TableEditing.warnings(shop.tables[4], database: "shop", deleting: true, in: snapshot)
                == ["log uses MyISAM, which can't roll back: if a statement fails, the ones before it stay applied."])
    }

    @Test func changesWaitOnDiskForTheNextLaunch() throws {
        let url = URL(fileURLWithPath: try scratch()).appendingPathComponent("pending.json")
        let store = PendingChangesStore(fileURL: url), connection = UUID()
        var changes = PendingChanges(keyColumns: ["id"])
        changes.set(.text("x"), column: "name", key: ["1"], original: nil)
        changes.addRow(["name": .default])
        store.save(changes, connection: connection, database: "shop", table: "items")
        store.flush()
        let again = PendingChangesStore(fileURL: url)
        #expect(again.changes(connection: connection, database: "shop", table: "items", keyColumns: ["id"])?.state == changes.state)
        #expect(again.changes(connection: connection, database: "shop", table: "items", keyColumns: ["sku"]) == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        again.save(PendingChanges(keyColumns: ["id"]), connection: connection, database: "shop", table: "items")
        again.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
