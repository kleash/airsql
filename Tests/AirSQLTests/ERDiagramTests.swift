import Testing
@testable import AirSQLCore

struct ERDiagramTests {
    /// A table with an id, and a foreign key to each of `parents` (through <parent>_id).
    func table(_ name: String, pointsAt parents: [String] = [], nullable: Bool = false, uniqueKey: Bool = false) -> SchemaTable {
        var table = SchemaTable(name: name, kind: .table, engine: "InnoDB")
        table.columns = [cachedColumn("id", "int")] + parents.map { cachedColumn($0 + "_id", "int", nullable: nullable) }
        table.indexes = [SchemaIndex(name: "PRIMARY", unique: true, type: "BTREE",
                                     parts: [.init(column: "id", expression: nil, prefixLength: nil, descending: false)],
                                     visible: true, comment: "")]
        if uniqueKey, let parent = parents.first {
            table.indexes.append(SchemaIndex(name: "one", unique: true, type: "BTREE",
                                             parts: [.init(column: parent + "_id", expression: nil, prefixLength: nil, descending: false)],
                                             visible: true, comment: ""))
        }
        table.foreignKeys = parents.map {
            SchemaForeignKey(name: name + "_" + $0, columns: [$0 + "_id"], referencedDatabase: "shop", referencedTable: $0,
                             referencedColumns: ["id"], onUpdate: "RESTRICT", onDelete: "CASCADE")
        }
        return table
    }

    func database(_ tables: [SchemaTable]) -> SchemaDatabase {
        var database = SchemaDatabase(name: "shop", charset: "utf8mb4", collation: "utf8mb4_bin")
        database.tables = tables
        return database
    }

    @Test func layersTablesByTheirForeignKeys() {
        let diagram = ERDiagram(database([
            table("customers"), table("order_items", pointsAt: ["orders", "products"]), table("orders", pointsAt: ["customers"]),
            table("products"), table("notes"), SchemaTable(name: "paid_orders", kind: .view),
        ]))
        #expect(diagram.columns.map { $0.map(\.name) } == [["customers", "products"], ["orders"], ["order_items"], ["notes"]])
        #expect(diagram.links.count == 3 && diagram.links.allSatisfy { !$0.optional && !$0.unique })
    }

    @Test func survivesCyclesAndSelfReferences() {
        var employees = table("employees", pointsAt: ["employees"], nullable: true)
        employees.columns[1].name = "employees_id"
        let diagram = ERDiagram(database([table("a", pointsAt: ["b"]), table("b", pointsAt: ["a"]), employees]))
        let placed = diagram.columns.flatMap { $0.map(\.name) }
        #expect(Set(placed) == ["a", "b", "employees"] && placed.count == 3)
        #expect(diagram.columns.count == 2)
    }

    @Test func putsLooseTablesInColumnsOfTheirOwn() {
        let loose = (1...20).map { table(String(format: "t%02d", $0)) }
        let diagram = ERDiagram(database(loose))
        #expect(diagram.columns.map(\.count) == [8, 8, 4])
    }

    @Test func ordersAColumnByTheTablesItPointsAt() {
        let diagram = ERDiagram(database([table("a"), table("b"), table("c"), table("x", pointsAt: ["c"]), table("y", pointsAt: ["a"])]))
        #expect(diagram.columns[1].map(\.name) == ["y", "x"])
    }

    @Test func writesMermaid() {
        var odd = table("order details", pointsAt: ["orders"], nullable: true, uniqueKey: true)
        odd.columns.append(cachedColumn("1st \"note\"", "varchar(20)"))
        let text = ERDiagram(database([table("orders"), odd])).mermaid()
        #expect(text == """
            erDiagram
                orders {
                    int id PK
                }
                order_details["order details"] {
                    int id PK
                    int orders_id FK, UK
                    varchar _1st__note_
                }
                orders |o--o| order_details : "order details_orders"

            """)
    }
}
