import Foundation
import Testing
@testable import AirSQLCore

struct SQLLogTests {
    @Test(arguments: [
        ("CREATE USER 'bob'@'%' IDENTIFIED BY 's3cret'", "CREATE USER 'bob'@'%' IDENTIFIED BY <secret>"),
        ("create user bob identified with caching_sha2_password by 's3cret' password expire",
         "create user bob identified with caching_sha2_password by <secret> password expire"),
        ("ALTER USER bob IDENTIFIED BY 'new' REPLACE 'old' RETAIN CURRENT PASSWORD",
         "ALTER USER bob IDENTIFIED BY <secret> REPLACE <secret> RETAIN CURRENT PASSWORD"),
        ("CREATE USER a IDENTIFIED WITH mysql_native_password AS '*2470C0C06DEE42FD1618BB99005ADCA2EC9D1E19'",
         "CREATE USER a IDENTIFIED WITH mysql_native_password AS '*2470C0C06DEE42FD1618BB99005ADCA2EC9D1E19'"),
        ("CREATE USER a IDENTIFIED BY 'p1' AND IDENTIFIED WITH authentication_ldap_simple BY 'p2'",
         "CREATE USER a IDENTIFIED BY <secret> AND IDENTIFIED WITH authentication_ldap_simple BY <secret>"),
        ("GRANT ALL ON *.* TO 'x'@'%' IDENTIFIED BY 'pw'", "GRANT ALL ON *.* TO 'x'@'%' IDENTIFIED BY <secret>"),
        ("CREATE USER m IDENTIFIED VIA ed25519 USING PASSWORD('pw') OR unix_socket",
         "CREATE USER m IDENTIFIED VIA ed25519 USING PASSWORD(<secret>) OR unix_socket"),
        ("CREATE USER m IDENTIFIED BY PASSWORD '*hash'", "CREATE USER m IDENTIFIED BY PASSWORD <secret>"),
        ("SET PASSWORD FOR 'bob'@'%' = 'pw'", "SET PASSWORD FOR 'bob'@'%' = <secret>"),
        ("SET PASSWORD = PASSWORD('pw')", "SET PASSWORD = PASSWORD(<secret>)"),
        ("set password='pw'", "set password=<secret>"),
        ("CHANGE MASTER TO MASTER_HOST='h', MASTER_USER='r', MASTER_PASSWORD='pw', MASTER_PORT=3306",
         "CHANGE MASTER TO MASTER_HOST='h', MASTER_USER='r', MASTER_PASSWORD=<secret>, MASTER_PORT=3306"),
        ("CHANGE REPLICATION SOURCE TO SOURCE_PASSWORD = \"pw\"", "CHANGE REPLICATION SOURCE TO SOURCE_PASSWORD = <secret>"),
        ("START REPLICA USER='r' PASSWORD='pw'", "START REPLICA USER='r' PASSWORD=<secret>"),
        ("CREATE SERVER s FOREIGN DATA WRAPPER mysql OPTIONS (USER 'u', PASSWORD 'pw', HOST 'h')",
         "CREATE SERVER s FOREIGN DATA WRAPPER mysql OPTIONS (USER 'u', PASSWORD <secret>, HOST 'h')"),
        ("SELECT AES_ENCRYPT('text', 'key'), AES_DECRYPT(col, UNHEX('6b6579'), 'iv') FROM t",
         "SELECT AES_ENCRYPT('text', <secret>), AES_DECRYPT(col, UNHEX(<secret>), <secret>) FROM t"),
        ("SELECT ENCODE('a', 'k'), DECODE(x, 'k'), DES_ENCRYPT('a', 0x6B), ENCRYPT('a', 'salt'), LENGTH('kept')",
         "SELECT ENCODE('a', <secret>), DECODE(x, <secret>), DES_ENCRYPT('a', <secret>), ENCRYPT('a', <secret>), LENGTH('kept')"),
        ("SELECT AES_ENCRYPT(CONCAT('a', 'b'), x'6B6579')", "SELECT AES_ENCRYPT(CONCAT('a', 'b'), <secret>)"),
        ("UPDATE users SET password = 'pw' WHERE id = 1", "UPDATE users SET password = <secret> WHERE id = 1"),
        ("/*!80000 CREATE USER u IDENTIFIED BY 'pw' */", "/*!80000 CREATE USER u IDENTIFIED BY <secret> */"),
        ("SELECT 'IDENTIFIED BY' AS x, 'a' -- IDENTIFIED BY 'not code'\n, 'b'",
         "SELECT 'IDENTIFIED BY' AS x, 'a' -- IDENTIFIED BY 'not code'\n, 'b'"),
        ("CREATE USER u IDENTIFIED BY 'it\\'s \\\\ hidden'", "CREATE USER u IDENTIFIED BY <secret>"),
        ("SELECT 1; CREATE USER u IDENTIFIED BY 'x'", "SELECT 1; CREATE USER u IDENTIFIED BY <secret>"),
        ("SELECT * FROM t WHERE name = 'IDENTIFIED BY ''x'''", "SELECT * FROM t WHERE name = 'IDENTIFIED BY ''x'''"),
    ])
    func masksCredentials(sql: String, logged: String) {
        #expect(SQLLog.mask(sql) == logged)
    }

    /// Where a literal ends depends on the sql_mode: under NO_BACKSLASH_ESCAPES 'C:\' is whole, and the password after
    /// it must still be found.
    @Test func masksByTheSessionsQuotingRules() {
        let sql = "SELECT 'C:\\', PASSWORD('pw')"
        #expect(SQLLog.mask(sql, noBackslashEscapes: true) == "SELECT 'C:\\', PASSWORD(<secret>)")
    }

    @Test func writesAPrivateFileAndRotates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-sqllog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = SQLLog(fileURL: dir.appendingPathComponent("logs/SQL.log"), sizeLimit: 400)
        log.statement("CREATE USER u IDENTIFIED BY 'hunter2'", context: "Shop main:1", noBackslashEscapes: false)
        log.note("startup SQL (2 statements)", context: "Shop main")
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(text.contains("[Shop main:1] CREATE USER u IDENTIFIED BY <secret>\n"))
        #expect(text.contains("[Shop main] -- startup SQL (2 statements)\n"))
        #expect(!text.contains("hunter2"))
        let mode = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("logs").path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)

        for n in 0..<10 { log.statement("SELECT \(n), '\(String(repeating: "x", count: 40))'", context: "Shop main:\(n + 2)", noBackslashEscapes: false) }
        log.note("after", context: "Shop main")
        #expect(FileManager.default.fileExists(atPath: log.previousFileURL.path))
        let size = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.size] as? Int ?? 0
        #expect(size < 400)
    }

    @Test func keepsTheFileText() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-sqllog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = SQLLog(fileURL: dir.appendingPathComponent("SQL.log"))
        log.statement("SELECT 'a\u{0}b'", context: "x main:1", noBackslashEscapes: true)
        let data = try Data(contentsOf: log.fileURL)
        #expect(!data.contains(0))
        #expect(String(decoding: data, as: UTF8.self).hasSuffix("[x main:1] SELECT 'a\\0b'\n"))
    }

    @Test func shortensHugeStatements() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-sqllog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = SQLLog(fileURL: dir.appendingPathComponent("SQL.log"))
        log.statement("INSERT INTO t VALUES " + String(repeating: "('row'),", count: 20_000) + "('last')", context: "x main:1",
                      noBackslashEscapes: false)
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(text.utf8.count < 61_000)
        #expect(text.contains("more bytes)"))
    }
}
