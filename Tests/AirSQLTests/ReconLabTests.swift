import Foundation
import Testing
@testable import AirSQLCore

/// Compare and reconcile against the lab (AIRSQL_LAB=1): structure and data on MariaDB and MySQL, across the two
/// flavours, the hashing's edge cases on real servers, the million-row table, and a sync script that makes the target
/// match. Writes only in databases named lane_l8a_*.
@Suite(.serialized, .enabled(if: Lab.enabled, "AIRSQL_LAB=1 runs the lab tests"))
struct ReconLabTests {
    static let log = SQLLog(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("airsql-recon-lab-\(getpid())/SQL.log"))

    static func session(_ server: Lab.Server) async throws -> DBConnection {
        let options = ConnectOptions(name: server.name, host: "127.0.0.1", port: try #require(server.port),
                                     user: Lab.airsql.user, password: Lab.airsql.password,
                                     tls: TLSOptions(mode: server.flavor == .mysql ? .required : .off))
        let session = DBConnection(options: options, role: .tools, log: log)
        try await session.connect()
        return session
    }

    /// Runs statements one at a time.
    static func run(_ session: DBConnection, _ statements: [String]) async throws {
        for statement in statements { _ = try await session.query(statement) }
    }

    /// A fresh database of this lane's with these statements run in it.
    static func database(_ session: DBConnection, _ name: String, _ statements: [String]) async throws {
        try await run(session, ["DROP DATABASE IF EXISTS \(name)", "CREATE DATABASE \(name) CHARACTER SET utf8mb4",
                                "USE \(name)"] + statements)
    }

    static func compare(_ source: DBConnection, _ sourceDB: String, _ target: DBConnection, _ targetDB: String,
                        options: ReconOptions = ReconOptions()) async throws -> ReconResult {
        try await Recon.run(source: ReconSide(name: "Source", database: sourceDB, session: source),
                            target: ReconSide(name: "Target", database: targetDB, session: target), options: options)
    }

    static let shopSource = [
        "CREATE TABLE customers (id INT PRIMARY KEY, name VARCHAR(50) NOT NULL, note TEXT NULL, seen TIMESTAMP NULL)",
        """
        CREATE TABLE orders (id BIGINT PRIMARY KEY, customer_id INT NOT NULL, total DECIMAL(10,2) NOT NULL,
            currency CHAR(3) NOT NULL DEFAULT 'EUR', KEY ix_customer (customer_id),
            CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES customers (id))
        """,
        "CREATE TABLE gift_cards (code VARCHAR(20) PRIMARY KEY, amount INT)",
        "CREATE VIEW big_orders AS SELECT id, total FROM orders WHERE total > 100",
        """
        INSERT INTO customers VALUES (1, 'Ada', 'first', '2026-01-02 03:04:05'), (2, 'Brook', NULL, NULL),
            (3, 'Cy', '', NULL), (4, 'Dee', 'it''s \\\\ "quoted"', NULL), (5, 'Eve', 'new', NULL)
        """,
        "INSERT INTO orders VALUES (10, 1, 12.50, 'EUR'), (11, 2, 250.00, 'USD')",
        "INSERT INTO gift_cards VALUES ('G-1', 20)",
    ]

    static let shopTarget = [
        "CREATE TABLE customers (id INT PRIMARY KEY, name VARCHAR(50) NOT NULL, note TEXT NULL, seen TIMESTAMP NULL)",
        """
        CREATE TABLE orders (id BIGINT PRIMARY KEY, customer_id INT NOT NULL, total DECIMAL(10,2) NOT NULL,
            KEY ix_customer (customer_id))
        """,
        "CREATE TABLE legacy (id INT PRIMARY KEY)",
        """
        INSERT INTO customers VALUES (1, 'Ada', 'first', '2026-01-02 03:04:05'), (2, 'Brooke', NULL, NULL),
            (3, 'Cy', NULL, NULL), (4, 'Dee', 'it''s \\\\ "quoted"', NULL), (6, 'Fay', 'gone', NULL)
        """,
        "INSERT INTO orders VALUES (10, 1, 12.50), (11, 2, 250.00)",
    ]

    @Test(arguments: [(Lab.mariadb114, Lab.mariadb114), (Lab.mysql84, Lab.mysql84), (Lab.mysql84, Lab.mariadb114)])
    func comparesAndSyncsAShop(_ servers: (Lab.Server, Lab.Server)) async throws {
        let source = try await Self.session(servers.0), target = try await Self.session(servers.1)
        defer { Task { await source.close(); await target.close() } }
        try await Self.database(source, "lane_l8a_shop_src", Self.shopSource)
        try await Self.database(target, "lane_l8a_shop_dst", Self.shopTarget)

        let result = try await Self.compare(source, "lane_l8a_shop_src", target, "lane_l8a_shop_dst")
        let customers = try #require(result.object(.table, "customers"))
        #expect(customers.status == .same, "\(customers.parts)")
        let data = try #require(customers.data)
        #expect(data.outcome == .different)
        #expect(data.missing.map { $0.text(0, kind: .integer) } == ["5"])
        #expect(data.extra.map { $0.text(0, kind: .integer) } == ["6"])
        #expect(Set(data.changed.map { $0.source.text(0, kind: .integer) }) == ["2", "3"])
        let orders = try #require(result.object(.table, "orders"))
        #expect(orders.status == .different)
        #expect(orders.parts.map { "\($0.kind) \($0.name) \($0.change)" }.sorted()
                == ["column currency added", "foreignKey fk_customer added"])
        #expect(result.object(.table, "gift_cards")?.status == .onlyInSource)
        #expect(result.object(.table, "legacy")?.status == .onlyInTarget)
        #expect(result.object(.view, "big_orders")?.status == .onlyInSource)

        // The script with its destructive steps makes the target match the source; the values of a new column come
        // with a second compare.
        try await result.apply(destructive: true, on: target) { _ in }
        let second = try await Self.compare(source, "lane_l8a_shop_src", target, "lane_l8a_shop_dst")
        #expect(second.object(.table, "orders")?.data?.changed.count == 1)
        #expect(second.object(.table, "gift_cards")?.data?.outcome == .same)
        try await second.apply(destructive: true, on: target) { _ in }
        let again = try await Self.compare(source, "lane_l8a_shop_src", target, "lane_l8a_shop_dst")
        // Each flavour writes a view's body its own way, so across flavours the view still reads differently.
        let left = again.objects.filter { $0.differs && !($0.kind == .view && servers.0.flavor != servers.1.flavor) }
            .map { "\($0.kind) \($0.name) \($0.status) \($0.parts.map(\.detail)) \($0.data?.outcome as Any)" }
        #expect(left.isEmpty, "\(left)")
        try await Self.run(source, ["DROP DATABASE lane_l8a_shop_src"])
        try await Self.run(target, ["DROP DATABASE lane_l8a_shop_dst"])
    }
}
