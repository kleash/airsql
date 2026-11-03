import Darwin
import Foundation
import Testing
@testable import AirSQLCore

/// The lab servers the driver's tests use (AIRSQL_LAB=1; testenv/, Support/Lab.swift): MariaDB 11.8 and MySQL 8.4 on
/// their own ports, and through the bastion `secure` and `wrongname`, whose certificates come from the lab CA (for the
/// names "secure" and elsewhere.invalid).
enum DBLab {
    static func server(_ flavor: String) -> Lab.Server { flavor == "mariadb" ? Lab.mariadb118 : Lab.mysql84 }

    static func options(_ server: Lab.Server, _ login: Lab.Login = Lab.airsql, tls: TLSOptions = TLSOptions(mode: .off))
        -> ConnectOptions {
        ConnectOptions(name: "Lab", host: "127.0.0.1", port: server.port ?? 3306, user: login.user, password: login.password,
                       tls: tls)
    }

    /// Through `socket` (a forward through the bastion, or a Relay), as through an SSH tunnel: the driver checks TLS
    /// against `host`.
    static func routed(_ socket: String, host: String, _ login: Lab.Login = Lab.airsql, tls: TLSOptions) -> ConnectOptions {
        ConnectOptions(name: "Lab", host: host, port: 3306, endpoint: .route(socket), user: login.user,
                       password: login.password, tls: tls)
    }

    static var verified: TLSOptions { TLSOptions(mode: .verifyIdentity, caFile: Lab.caFile) }
    /// The lab CA without a name check (wrongname's certificate is for another name).
    static var encrypted: TLSOptions { TLSOptions(mode: .verifyCA, caFile: Lab.caFile) }
    /// The direct servers' own self-signed certificates: encryption only.
    static var required: TLSOptions { TLSOptions(mode: .required) }

    /// The numbers 0 ..< 10^power (id, and a label "row-<id>"; power 6 or 9), made as they are sent: from a recursive
    /// CTE joined with itself where the server has them, else (MySQL 5.7) from a ten-row derived table joined with
    /// itself (MySQL 8's hash joins build that up before the first row).
    static func numbers(_ power: Int, on server: ServerInfo?) -> String {
        if let server, server.flavor == .mariadb || server.atLeast(8) {
            let id = (0..<power / 3).map { "t\($0).i * 1\(String(repeating: "000", count: $0))" }.joined(separator: " + ")
            return "WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < 999) SELECT \(id) AS id, "
                + "CONCAT('row-', \(id)) AS label FROM " + (0..<power / 3).map { "n AS t\($0)" }.joined(separator: ", ")
        }
        let digits = "(" + (0...9).map { "SELECT \($0) AS d" }.joined(separator: " UNION ALL ") + ")"
        let id = (0..<power).map { "t\($0).d * 1\(String(repeating: "0", count: $0))" }.joined(separator: " + ")
        return "SELECT \(id) AS id, CONCAT('row-', \(id)) AS label FROM "
            + (0..<power).map { "\(digits) AS t\($0)" }.joined(separator: ", ")
    }

    /// A log of its own in a temporary folder, so the tests leave the user's SQL log alone.
    static let log = SQLLog(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("airsql-lab-\(getpid())/SQL.log"))
}

/// A route's end that a test can drop (Lab.forward is a real one, through the bastion): a private Unix socket whose
/// connections are piped to a TCP server, as an SSH tunnel's would be. `cut()` drops this Mac's side of every
/// connection and leaves the server's side open: a network gone without a word, which the server doesn't notice. The
/// threads own the sockets (each pair is closed by the last of its two pumps, the listener by its accept loop), so no
/// socket number is closed under a thread that still uses it.
final class Relay {
    let path: String
    private let dir: URL
    private let control = Control()

    private final class Control {
        let lock = NSLock()
        var stopped = false
        var pairs: [Pair] = []
        /// Pairs whose Mac side was cut: their server side waits for the server or for deinit.
        var cut: [Pair] = []
    }

    private final class Pair {
        let client: Int32, server: Int32
        private let lock = NSLock()
        private var pumps = 2

        init(_ client: Int32, _ server: Int32) {
            self.client = client
            self.server = server
        }

        func pumpEnded() {
            let last = lock.locked { () -> Bool in
                pumps -= 1
                return pumps == 0
            }
            if last {
                close(client)
                close(server)
            }
        }
    }

    init(to server: (host: String, port: Int)) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-relay-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        path = dir.appendingPathComponent("db.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            close(listener)
            throw AirSQLError(.other, "The test relay couldn't listen on \(path).")
        }
        let control = self.control, host = server.host == "localhost" ? "127.0.0.1" : server.host, port = server.port
        Thread.detachNewThread {
            while !control.lock.locked({ control.stopped }) {
                var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&ready, 1, 100) > 0 else { continue }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                let server = Relay.connect(host, port)
                guard server >= 0 else {
                    close(client)
                    continue
                }
                let pair = Pair(client, server)
                control.lock.locked { control.pairs.append(pair) }
                Thread.detachNewThread { Relay.pump(pair.client, pair.server, pair) }
                Thread.detachNewThread { Relay.pump(pair.server, pair.client, pair) }
            }
            close(listener)
        }
    }

    deinit {
        let pairs = control.lock.locked { () -> [Pair] in
            control.stopped = true
            return control.pairs + control.cut
        }
        for pair in pairs {
            shutdown(pair.client, SHUT_RDWR)
            shutdown(pair.server, SHUT_RDWR)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Drops this Mac's side of every connection so far; the server's side stays open.
    func cut() {
        let pairs = control.lock.locked { () -> [Pair] in
            defer {
                control.cut += control.pairs
                control.pairs = []
            }
            return control.pairs
        }
        for pair in pairs { shutdown(pair.client, SHUT_RDWR) }
    }

    private static func connect(_ host: String, _ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &address.sin_addr)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    /// Copies `from` to `to` until either side ends; never shuts the other side down (cut() relies on that).
    private static func pump(_ from: Int32, _ to: Int32, _ pair: Pair) {
        defer { pair.pumpEnded() }
        var on: Int32 = 1
        setsockopt(to, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(from, &buffer, buffer.count)
            guard count > 0 else { return }
            var sent = 0
            while sent < count {
                let written = buffer.withUnsafeBytes { write(to, $0.baseAddress! + sent, count - sent) }
                guard written > 0 else { return }
                sent += written
            }
        }
    }
}

func kind(of body: () async throws -> Any) async -> AirSQLError.Kind? {
    do {
        _ = try await body()
        return nil
    } catch let error as AirSQLError {
        return error.kind
    } catch {
        return .other
    }
}

@Suite(.serialized, .enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
struct DBLabTests {
    let log = DBLab.log

    func connected(_ options: ConnectOptions, role: DBConnection.Role = .main) async throws -> DBConnection {
        let session = DBConnection(options: options, role: role, log: log)
        try await session.connect()
        return session
    }

    func value(_ session: DBConnection, _ sql: String) async throws -> String? {
        try await session.query(sql).first?.rows?.string(0, 0)
    }

    @Test func logsInWithEveryMethod() async throws {
        // Empty caching_sha2's cache, so its logins take the full path (RSA without TLS, the password inside TLS).
        let admin = try await connected(DBLab.options(Lab.mysql84))
        _ = try await admin.query("FLUSH PRIVILEGES")
        await admin.close()
        for (server, login) in [(Lab.mariadb118, Lab.native), (Lab.mariadb118, Lab.ed25519), (Lab.mysql84, Lab.native),
                                (Lab.mysql84, Lab.sha2)] {
            let session = try await connected(DBLab.options(server, login))
            #expect(try await value(session, "SELECT CURRENT_USER()") == "\(login.user)@%")
            await session.close()
        }
        let forward = try await Lab.forward(to: Lab.wrongName)
        defer { forward.close() }
        let admin2 = try await connected(DBLab.routed(forward.socket, host: "wrongname", tls: DBLab.encrypted))
        _ = try await admin2.query("FLUSH PRIVILEGES")
        await admin2.close()
        let overTLS = try await connected(DBLab.routed(forward.socket, host: "wrongname", Lab.sha2, tls: DBLab.encrypted))
        #expect(try await value(overTLS, "SELECT CURRENT_USER()") == "sha2@%")
        #expect(overTLS.server?.tls?.hasPrefix("TLSv1.") == true)
        await overTLS.close()
    }

    /// Through a route without TLS caching_sha2_password would send the password as plain text on the route's last hop:
    /// refused before any of it is sent. mysql_native_password still logs in that way.
    @Test func routesWithoutTLSRefuseCleartextLogins() async throws {
        let forward = try await Lab.forward(to: Lab.wrongName)
        defer { forward.close() }
        let refused = DBConnection(options: DBLab.routed(forward.socket, host: "wrongname", Lab.sha2, tls: TLSOptions(mode: .off)),
                                   role: .main, log: log)
        do {
            try await refused.connect()
            Issue.record("caching_sha2_password logged in through a route without TLS")
        } catch let error as AirSQLError {
            #expect(error.kind == .loginMethodNotAllowed)
            #expect(error.message.contains("Turn on TLS"))
        }
        let native = try await connected(DBLab.routed(forward.socket, host: "wrongname", Lab.native, tls: TLSOptions(mode: .off)))
        #expect(try await value(native, "SELECT CURRENT_USER()") == "native@%")
        await native.close()

        var pam = DBLab.routed(forward.socket, host: "wrongname", Lab.native, tls: TLSOptions(mode: .required))
        pam.cleartextLogin = true
        #expect(await kind { try await DBConnection(options: pam, role: .main, log: log).connect() } == .loginMethodNotAllowed)
    }

    /// Through the bastion, as through any tunnel, the certificate is checked against the name typed, never the
    /// tunnel's local end.
    @Test func tlsChecksTheRealHostName() async throws {
        let secure = try await Lab.forward(to: Lab.secure), wrongName = try await Lab.forward(to: Lab.wrongName)
        defer {
            secure.close()
            wrongName.close()
        }
        let right = try await connected(DBLab.routed(secure.socket, host: "secure", tls: DBLab.verified))
        #expect(right.server?.certificate?.fingerprint.count == 95)
        #expect(right.server?.tls != nil)
        await right.close()

        func failure(_ options: ConnectOptions) async -> AirSQLError? {
            do {
                try await DBConnection(options: options, role: .main, log: log).connect()
                return nil
            } catch {
                return error as? AirSQLError
            }
        }
        // Another name than the certificate's, the server with the wrong-name certificate, and the address connected to.
        for options in [DBLab.routed(secure.socket, host: "other.airsql.test", tls: DBLab.verified),
                        DBLab.routed(wrongName.socket, host: "wrongname", tls: DBLab.verified),
                        DBLab.routed(secure.socket, host: "127.0.0.1", tls: DBLab.verified)] {
            let error = await failure(options)
            guard case .untrustedCertificate? = error?.kind else {
                Issue.record("expected an untrusted certificate for \(options.host), got \(String(describing: error))")
                continue
            }
            #expect(error?.message.contains("not for “\(options.host)”") == true, "\(String(describing: error?.message))")
        }
        // Without the CA: not trusted, and the fingerprint to pin comes with the error.
        let untrusted = await failure(DBLab.routed(secure.socket, host: "secure", tls: TLSOptions(mode: .verifyIdentity)))
        guard case .untrustedCertificate(let certificate)? = untrusted?.kind else {
            Issue.record("expected an untrusted certificate, got \(String(describing: untrusted))")
            return
        }
        let pin = TLSOptions(mode: .verifyIdentity, pinnedFingerprint: certificate.fingerprint)
        let pinned = try await connected(DBLab.routed(secure.socket, host: "127.0.0.1", tls: pin))
        await pinned.close()
        let changed = await failure(DBLab.routed(wrongName.socket, host: "wrongname", tls: pin))
        guard case .certificateChanged? = changed?.kind else {
            Issue.record("expected a changed certificate, got \(String(describing: changed))")
            return
        }
        // The CA but no name; encryption only.
        for tls in [DBLab.encrypted, DBLab.required] {
            let session = try await connected(DBLab.routed(wrongName.socket, host: "wrongname", tls: tls))
            #expect(session.server?.tls != nil)
            await session.close()
        }
    }

    /// Cancel stops this session's statement and nothing else: another session's statement on the same server runs on.
    @Test(arguments: ["mariadb", "mysql"])
    func cancelStopsOnlyItsOwnStatement(_ flavor: String) async throws {
        let server = DBLab.server(flavor)
        let options = flavor == "mysql" ? DBLab.options(server, Lab.native) : DBLab.options(server)
        let a = try await connected(options), b = try await connected(options)
        #expect(try await a.cancel() == .notRunning)

        let slow = Task { try await a.query("SELECT SLEEP(20) FROM (SELECT 1 UNION ALL SELECT 2) AS t") }
        let other = Task { try await b.query("SELECT SLEEP(3)") }
        let start = Date()
        var result = CancelResult.notRunning
        _ = try await eventually(timeout: 5) {
            if a.isBusy { result = try await a.cancel() }
            return result != .notRunning
        }
        #expect(result == .cancelled)
        let stopped = await kind { try await slow.value }
        #expect(stopped == .cancelled || stopped == nil)
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(try await other.value.first?.rows?.string(0, 0) == "0", "the other session's SLEEP ran to its end")
        #expect(try await value(a, "SELECT 1") == "1")
        await a.close()
        await b.close()
    }

    @Test(arguments: ["mariadb", "mysql"])
    func readsAMillionRowsAndStopsAtTheCap(_ flavor: String) async throws {
        let server = DBLab.server(flavor)
        let session = try await connected(flavor == "mysql" ? DBLab.options(server, Lab.native) : DBLab.options(server))
        let all = try #require(try await session.query(DBLab.numbers(6, on: session.server), rowCap: 2_000_000).first?.rows)
        #expect(all.rowCount == 1_000_000 && !all.capped)
        #expect(all.string(999_999, 1)?.hasPrefix("row-") == true)
        #expect(all.byteCount < 48 << 20, "\(all.byteCount >> 20) MB")

        // A billion rows: the cap stops the statement on the server instead of reading them all.
        let start = Date()
        let capped = try #require(try await session.query(DBLab.numbers(9, on: session.server), rowCap: 1000).first?.rows)
        #expect(capped.capped && capped.rowCount == 1000)
        #expect(Date().timeIntervalSince(start) < 30)
        #expect(try await value(session, "SELECT 1") == "1")
        await session.close()
    }

    /// Export all's way: every row in batches, none kept; a reader that gives up stops the statement on the server.
    @Test func streamsRowsInBatches() async throws {
        let session = try await connected(DBLab.options(Lab.mariadb118))
        var total = 0, batches = 0, largest = 0
        try await session.stream(DBLab.numbers(6, on: session.server), batchRows: 50_000) { batch in
            total += batch.rowCount
            batches += 1
            largest = max(largest, batch.rowCount)
        }
        #expect(total == 1_000_000 && batches == 20 && largest == 50_000)

        struct Enough: Error {}
        let start = Date()
        var seen = 0
        do {
            try await session.stream(DBLab.numbers(9, on: session.server), batchRows: 1000) { batch in
                seen += batch.rowCount
                if seen >= 3000 { throw Enough() }
            }
            Issue.record("the reader's error didn't come back")
        } catch is Enough {
        }
        #expect(Date().timeIntervalSince(start) < 30)
        #expect(try await value(session, "SELECT 1") == "1")
        await session.close()
    }

    @Test(arguments: ["mariadb", "mysql"])
    func hostileValuesAndNamesRoundTrip(_ flavor: String) async throws {
        let server = DBLab.server(flavor)
        let session = try await connected(DBLab.options(server, tls: DBLab.required))
        for noBackslashEscapes in [false, true] {
            if noBackslashEscapes { _ = try await session.query("SET SESSION sql_mode = CONCAT_WS(',', NULLIF(@@sql_mode, ''), 'NO_BACKSLASH_ESCAPES')") }
            #expect(session.noBackslashEscapes == noBackslashEscapes)
            for text in Hostile.values {
                let rows = try await session.query("SELECT " + SQLQuote.string(text, noBackslashEscapes: session.noBackslashEscapes))
                #expect(rows.first?.rows?.bytes(0, 0) == Array(text.utf8), "\(text.debugDescription)")
            }
        }
        // Servers drop leading blanks and control characters from names, and supplementary characters aren't allowed.
        for name in Hostile.names where !name.first!.isWhitespace
            && !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value > 0xFFFF }) {
            let rows = try await session.query("SELECT 1 AS " + SQLQuote.identifier(name))
            #expect(rows.first?.rows?.columns.first?.name == name, "\(name.debugDescription)")
        }
        let bytes = (0...255).map(UInt8.init)
        #expect(try await session.query("SELECT " + SQLQuote.hex(bytes)).first?.rows?.bytes(0, 0) == bytes)
        #expect(try await value(session, "SELECT " + SQLQuote.bits(5) + " + 0") == "5")

        let database = "lane_p0_2_quote_\(flavor)", table = "lane`p0;2 'tbl\"", column = "col`x' --x"
        _ = try await session.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(database))
        _ = try await session.query("CREATE DATABASE " + SQLQuote.identifier(database))
        _ = try await session.query("CREATE TABLE \(SQLQuote.identifier(database, table)) (\(SQLQuote.identifier(column)) TEXT)")
        let hostile = "\\'; DROP DATABASE \(database); -- '"
        _ = try await session.query("INSERT INTO \(SQLQuote.identifier(database, table)) VALUES "
                                    + "(\(SQLQuote.string(hostile, noBackslashEscapes: session.noBackslashEscapes)))")
        #expect(try await value(session, "SELECT \(SQLQuote.identifier(column)) FROM \(SQLQuote.identifier(database, table))")
                    == hostile)
        _ = try await session.query("DROP DATABASE " + SQLQuote.identifier(database))
        await session.close()
    }

    /// A dropped connection is reported, never re-made silently; Reconnect sets the session up again, says the open
    /// transaction is gone and kills the old session the server still had.
    @Test(arguments: ["mariadb", "mysql"])
    func reconnectIsExplicitAndCleansUp(_ flavor: String) async throws {
        let server = DBLab.server(flavor)
        let relay = try Relay(to: ("127.0.0.1", server.port ?? 3306))
        // MySQL's airsql logs in with caching_sha2_password: TLS through the route.
        let session = try await connected(DBLab.routed(relay.path, host: "127.0.0.1",
                                                        tls: flavor == "mysql" ? DBLab.required : TLSOptions(mode: .off)))
        let old = try #require(session.server?.threadID)
        _ = try await session.query("START TRANSACTION")
        #expect(session.inTransaction && session.transactionStarted != nil)

        relay.cut()
        #expect(await kind { try await session.query("SELECT 1") } == .disconnected)
        #expect(!session.isConnected)
        #expect(await kind { try await session.query("SELECT 1") } == .disconnected, "no silent reconnect")

        let report = try await session.reconnect()
        #expect(report.rolledBack && report.killedOldSession)
        #expect(report.server.threadID != old)
        #expect(!session.inTransaction)
        #expect(try await eventually {
            try await value(session, "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID = \(old)") == "0"
        })
        await session.close()
    }

    /// The session model: main, data, schema and agent sessions opened on first use (callers at the same time share one
    /// connect), the agent's read-only, tools sessions of their own, and Disconnect closing them all and forgetting the
    /// password.
    @Test func connectionOwnsItsSessions() async throws {
        let connection = Connection(options: DBLab.options(Lab.mariadb118), log: log)
        let server = try await connection.connect()
        async let first = connection.session(.data)
        async let second = connection.session(.data)
        let (data, sameData) = try await (first, second)
        #expect(data === sameData)
        let main = try await connection.session(.main), schema = try await connection.session(.schema)
        #expect(main.server?.threadID == server.threadID)
        #expect(Set([main, data, schema].compactMap { $0.server?.threadID }).count == 3)
        let agent = try await connection.session(.agent)
        #expect(agent.options.readOnly && agent.role == .agent)
        #expect(await kind { try await agent.query("CREATE DATABASE lane_p0_2_never") } == .readOnly)
        let tools = try await connection.toolsSession()
        #expect(tools.role == .tools && tools.server?.threadID != main.server?.threadID)

        await connection.keepAlive(transactionLimit: 15 * 60)
        await connection.disconnect()
        #expect(![main, data, schema, agent, tools].contains { $0.isConnected })
        #expect(connection.options.password.isEmpty)
    }

    @Test func logsTagsAndMasksLiveStatements() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-lablog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = SQLLog(fileURL: dir.appendingPathComponent("SQL.log"))
        var options = DBLab.options(Lab.mariadb118)
        options.startupSQL = ["SET @startup = 'do-not-log-me'"]
        options.timeZone = "+05:30"
        options.compress = true
        let session = DBConnection(options: options, role: .data, log: log)
        try await session.connect()
        let info = try await value(session, "SELECT INFO FROM information_schema.PROCESSLIST WHERE ID = CONNECTION_ID()")
        #expect(info?.hasPrefix("/* airsql:data:") == true, "\(String(describing: info))")
        let rows = try #require(try await session.query("SELECT @@time_zone, @startup, AES_ENCRYPT('data', 'k3y-secret') IS NOT NULL")
            .first?.rows)
        #expect(rows.string(0, 0) == "+05:30" && rows.string(0, 1) == "do-not-log-me" && rows.string(0, 2) == "1")
        #expect(try await session.query("SHOW SESSION STATUS LIKE 'Compression'").first?.rows?.string(0, 1) == "ON")
        await session.close()

        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(text.contains("[Lab data] -- startup SQL (1 statement)"))
        #expect(text.contains("AES_ENCRYPT('data', <secret>)"))
        #expect(text.contains("[Lab data] -- connected: MariaDB"))
        #expect(!text.contains("do-not-log-me") && !text.contains("k3y-secret"))
        #expect(try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.posixPermissions] as? Int == 0o600)
    }

    /// One statement at a time (no multi-statements), no LOAD DATA LOCAL, UPDATE counts matched rows, procedures give
    /// all their result sets, and a read-only session can't write.
    @Test(arguments: ["mariadb", "mysql"])
    func statementRules(_ flavor: String) async throws {
        let server = DBLab.server(flavor)
        let session = try await connected(DBLab.options(server, tls: DBLab.required))
        let database = SQLQuote.identifier("lane_p0_2_rules_\(flavor)")
        _ = try await session.query("DROP DATABASE IF EXISTS \(database)")
        _ = try await session.query("CREATE DATABASE \(database)")
        #expect(await kind { try await session.query("SELECT 1; SELECT 2") } == .syntax)
        #expect(await kind { try await session.query("LOAD DATA LOCAL INFILE '/etc/hosts' INTO TABLE \(database).t") } != nil)

        _ = try await session.query("CREATE TABLE \(database).t (id INT PRIMARY KEY, note VARCHAR(20))")
        _ = try await session.query("INSERT INTO \(database).t VALUES (1, 'same'), (2, NULL), (3, '')")
        #expect(try await session.query("UPDATE \(database).t SET note = 'same' WHERE id = 1").first?.affectedRows == 1)
        let rows = try #require(try await session.query("SELECT note FROM \(database).t ORDER BY id").first?.rows)
        #expect(rows.string(0, 0) == "same" && rows.isNull(1, 0) && rows.string(2, 0) == "")

        _ = try await session.query("CREATE PROCEDURE \(database).two() BEGIN SELECT 1 AS a; SELECT 2 AS b, 3 AS c; END")
        let results = try await session.query("CALL \(database).two()")
        #expect(results.count == 3)
        #expect(results.first?.rows?.string(0, 0) == "1" && results.dropFirst().first?.rows?.columns.count == 2)
        #expect(results.last?.rows == nil)

        var readOnly = DBLab.options(server, tls: DBLab.required)
        readOnly.readOnly = true
        let reader = try await connected(readOnly, role: .agent)
        #expect(await kind { try await reader.query("INSERT INTO \(database).t VALUES (4, 'no')") } == .readOnly)
        await reader.close()
        _ = try await session.query("DROP DATABASE \(database)")
        await session.close()
    }
}
