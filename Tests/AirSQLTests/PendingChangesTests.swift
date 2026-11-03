import Foundation
import Testing
@testable import AirSQLCore

/// Pending changes (plan §2.5, grid-spec §5): edits, new rows and deletes by key, undo, the statements Apply runs and
/// the rows each must change, the rollback when one changes another number, which tables can be edited, and the copy
/// kept on disk for a crash.
struct PendingChangesTests {
    static let columns = [GridColumn(name: "id", type: "int", kind: .number, isKey: true), GridColumn(name: "name"),
                          GridColumn(name: "price", type: "decimal", kind: .number)]

    func sql(_ changes: PendingChanges, noBackslashEscapes: Bool = false) -> [String] {
        changes.statements(database: "shop", table: "items", columns: Self.columns, noBackslashEscapes: noBackslashEscapes).map(\.sql)
    }

    @Test func editsInsertsAndDeletesBecomeStatementsInOrder() {
        var changes = PendingChanges(keyColumns: ["id"])
        changes.set(.text("Bob"), column: "name", key: ["2"], original: "Bo")
        changes.set(.text("9.90"), column: "price", key: ["2"], original: "9")
        changes.set(.null, column: "name", key: ["1"], original: "Ann")
        changes.delete([["7"], ["5"]])
        let id = changes.addRow(["name": .text("Cy"), "price": .default])
        changes.addRow()
        #expect(changes.rowCount == 6)
        let statements = changes.statements(database: "shop", table: "items", columns: Self.columns, noBackslashEscapes: false)
        #expect(statements.map(\.sql) == [
            "DELETE FROM `shop`.`items` WHERE `id` IN (5, 7)",
            "UPDATE `shop`.`items` SET `name` = NULL WHERE `id` = 1",
            "UPDATE `shop`.`items` SET `name` = 'Bob', `price` = 9.90 WHERE `id` = 2",
            "INSERT INTO `shop`.`items` (`name`, `price`) VALUES ('Cy', DEFAULT)",
            "INSERT INTO `shop`.`items` () VALUES ()",
        ])
        #expect(statements.map(\.expectedRows) == [2, 1, 1, 1, 1])
        #expect(statements[0].target == .delete([["5"], ["7"]]))
        #expect(statements[3].target == .insert(id))
    }

    @Test func settingTheLoadedValueAgainDropsTheEdit() {
        var changes = PendingChanges(keyColumns: ["id"])
        changes.set(.text("x"), column: "name", key: ["1"], original: "Ann")
        changes.set(.text("Ann"), column: "name", key: ["1"], original: "Ann")
        #expect(changes.isEmpty)
        changes.set(.null, column: "name", key: ["1"], original: nil)
        #expect(changes.isEmpty)
        changes.set(.text(""), column: "name", key: ["1"], original: nil)  // an empty text isn't NULL
        #expect(changes.value(["1"], "name") == .text(""))
    }

    @Test func deletedRowsAreNotUpdatedAndNewRowsJustGo() {
        var changes = PendingChanges(keyColumns: ["id"])
        changes.set(.text("x"), column: "name", key: ["1"], original: "Ann")
        let id = changes.addRow()
        changes.delete([["1"]], inserts: [id])
        #expect(sql(changes) == ["DELETE FROM `shop`.`items` WHERE `id` IN (1)"])
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

    @Test func compositeKeysAndBatchesOfFiveHundred() {
        var changes = PendingChanges(keyColumns: ["shop", "sku"])
        changes.delete((0..<1_001).map { ["1", String(format: "s%04d", $0)] })
        changes.set(.text("x"), column: "name", key: ["2", "it's"], original: nil)
        let statements = changes.statements(database: "db", table: "t", columns: [GridColumn(name: "shop", kind: .number)],
                                            noBackslashEscapes: false)
        #expect(statements.map(\.expectedRows) == [500, 500, 1, 1])
        #expect(statements[0].sql.hasPrefix("DELETE FROM `db`.`t` WHERE (`shop`, `sku`) IN ((1, 's0000'), (1, 's0001'), "))
        #expect(statements[3].sql == "UPDATE `db`.`t` SET `name` = 'x' WHERE `shop` = 2 AND `sku` = 'it\\'s'")
    }

    @Test(arguments: [false, true])
    func hostileValuesAndNamesStayQuoted(noBackslashEscapes: Bool) {
        for value in Hostile.names {
            var changes = PendingChanges(keyColumns: [value])
            changes.set(.text(value), column: value, key: [value], original: nil)
            let quotedName = SQLQuote.identifier(value), quoted = SQLQuote.string(value, noBackslashEscapes: noBackslashEscapes)
            let statements = changes.statements(database: value, table: value, columns: [], noBackslashEscapes: noBackslashEscapes)
            #expect(statements.map(\.sql) == ["UPDATE \(SQLQuote.identifier(value, value)) SET \(quotedName) = \(quoted) "
                                              + "WHERE \(quotedName) = \(quoted)"])
        }
    }

    @Test func applyRollsBackOnAMismatchOrAnError() async throws {
        var changes = PendingChanges(keyColumns: ["id"])
        changes.set(.text("x"), column: "name", key: ["1"], original: nil)
        changes.set(.text("y"), column: "name", key: ["2"], original: nil)
        let statements = changes.statements(database: "shop", table: "items", columns: Self.columns, noBackslashEscapes: false)
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
                return sql.hasSuffix("= 2") ? 0 : 1
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

    @Test func onlyTablesWithAKeyCanBeEdited() {
        func index(_ name: String, unique: Bool = true, _ columns: [String]) -> SchemaIndex {
            SchemaIndex(name: name, unique: unique, type: "BTREE",
                        parts: columns.map { .init(column: $0, expression: nil, prefixLength: nil, descending: false) },
                        visible: true, comment: "")
        }
        var table = SchemaTable(name: "t", kind: .table, engine: "InnoDB")
        table.columns = [cachedColumn("a", "int"), cachedColumn("b", "int", nullable: true), cachedColumn("c", "int")]
        #expect(TableEditing.key(of: table).columns == nil)
        #expect(TableEditing.key(of: table).reason?.contains("no primary key") == true)
        table.indexes = [index("ub", ["b"]), index("ix", unique: false, ["c"]), index("uac", ["a", "c"])]
        #expect(TableEditing.key(of: table).columns == ["a", "c"])  // b can be NULL; ix isn't unique
        table.indexes.append(index("PRIMARY", ["c"]))
        #expect(TableEditing.key(of: table).columns == ["c"])
        let view = SchemaTable(name: "v", kind: .view)
        #expect(TableEditing.key(of: view).columns == nil && TableEditing.key(of: view).reason?.hasPrefix("Views") == true)
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
