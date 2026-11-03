import Darwin
import Foundation
import Testing

/// The lab itself (testenv/): each server answers through its route, and only there. With AIRSQL_LAB=1 (test.sh then
/// starts the lab first).
@Suite(.enabled(if: Lab.enabled, "AIRSQL_LAB=1 runs the lab tests"))
struct LabTests {
    /// The server version in a MySQL greeting read from `fd` (protocol 10: a packet header, 10, then the version up to a
    /// NUL; MariaDB 10 puts "5.5.5-" first), or nil when the connection closes or sends something else.
    static func greeting(_ fd: Int32) -> String? {
        let header = receive(fd, count: 4)
        guard header.count == 4 else { return nil }
        let payload = receive(fd, count: Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16)
        guard payload.first == 10, let end = payload.firstIndex(of: 0) else { return nil }
        let version = String(decoding: payload[1..<end], as: UTF8.self)
        return version.hasPrefix("5.5.5-") ? String(version.dropFirst(6)) : version
    }

    @Test(arguments: Lab.direct + [Lab.many, Lab.slow])
    func answersOnItsOwnPort(_ server: Lab.Server) throws {
        let fd = connectTCP(try #require(server.port))
        defer { close(fd) }
        let version = Self.greeting(fd)
        #expect(version?.hasPrefix(server.version) == true, "\(server): \(version ?? "nothing")")
    }

    /// ProxySQL answers with its own greeting; behind it is mariadb114.
    @Test func proxySQLAnswersForMariaDB114() throws {
        let fd = connectTCP(try #require(Lab.proxySQL.port))
        defer { close(fd) }
        let version = Self.greeting(fd)
        #expect(version != nil && version?.contains("MariaDB") == false, "\(version ?? "nothing")")
    }

    /// slow is mysql84 with 50 ms on every packet the relay sends: its greeting takes over 100 ms more.
    @Test func theSlowRouteAddsLatency() throws {
        func fastest(_ port: Int) -> TimeInterval {
            (0..<3).map { _ in
                let started = Date()
                let fd = connectTCP(port)
                defer { close(fd) }
                _ = Self.greeting(fd)
                return Date().timeIntervalSince(started)
            }.min()!
        }
        let direct = fastest(try #require(Lab.mysql84.port)), slow = fastest(try #require(Lab.slow.port))
        #expect(slow - direct > 0.08, "direct \(direct) s, slow \(slow) s")
    }

    /// Through the bastion: secure and wrongname; not deep (only behind the jump host) or the servers on their own ports.
    @Test func theBastionReachesTheInnerNetworkOnly() async throws {
        for (server, reachable) in [(Lab.secure, true), (Lab.wrongName, true), (Lab.deep, false), (Lab.mysql84, false)] {
            let forward = try await Lab.forward(to: server)
            defer { forward.close() }
            let fd = connectUnix(forward.socket)
            defer { close(fd) }
            let version = Self.greeting(fd)
            #expect(reachable ? version?.hasPrefix(server.version) == true : version == nil, "\(server): \(version ?? "nothing")")
        }
    }

    /// deep through the bastion and then the jump host.
    @Test func theJumpHostReachesDeep() async throws {
        let forward = try await Lab.forward(to: Lab.deep, throughJump: true)
        defer { forward.close() }
        let fd = connectUnix(forward.socket)
        defer { close(fd) }
        let version = Self.greeting(fd)
        #expect(version?.hasPrefix(Lab.deep.version) == true, "\(version ?? "nothing")")
    }

    /// The HTTP proxies want their login (Basic, Digest only) and the SOCKS proxy its own; all three reach the inner
    /// network's databases and SSH hosts, and nothing else.
    @Test func theProxiesReachTheInnerNetworkOnly() throws {
        let proxy = Lab.httpProxy, basic = "Basic " + Data("\(proxy.user):\(proxy.password)".utf8).base64EncodedString()
        var (fd, head) = proxyConnect(port: proxy.port, target: "secure:3306")
        close(fd)
        #expect(head.contains(" 407 "), "\(head)")
        (fd, head) = proxyConnect(port: proxy.port, target: "secure:3306", authorization: basic)
        #expect(head.contains(" 200 ") && Self.greeting(fd)?.hasPrefix(Lab.secure.version) == true, "\(head)")
        close(fd)
        (fd, head) = proxyConnect(port: proxy.port, target: "bastion:22", authorization: basic)
        #expect(String(decoding: receive(fd, through: "\n"), as: UTF8.self).hasPrefix("SSH-2.0-"), "\(head)")
        close(fd)
        for target in ["deep:3306", "mysql84:3306"] {
            (fd, head) = proxyConnect(port: proxy.port, target: target, authorization: basic)
            close(fd)
            #expect(!head.contains(" 200 "), "\(target): \(head)")
        }

        let digest = Lab.digestProxy
        (fd, head) = proxyConnect(port: digest.port, target: "wrongname:3306")
        close(fd)
        let challenge = try #require(digestChallenge(in: head), "\(head)")
        let answer = try #require(HTTPDigest.authorization(challenge, username: digest.user, password: digest.password,
                                                           uri: "wrongname:3306", cnonce: "airsql-lab"))
        (fd, head) = proxyConnect(port: digest.port, target: "wrongname:3306", authorization: answer)
        #expect(head.contains(" 200 ") && Self.greeting(fd)?.hasPrefix(Lab.wrongName.version) == true, "\(head)")
        close(fd)

        let socks = Lab.socksProxy
        var (socket, reply) = socksConnect(port: socks.port, host: "secure", targetPort: 3306, user: socks.user,
                                           password: socks.password)
        #expect(reply == 0 && Self.greeting(socket)?.hasPrefix(Lab.secure.version) == true, "reply \(reply ?? 255)")
        close(socket)
        (socket, reply) = socksConnect(port: socks.port, host: "deep", targetPort: 3306, user: socks.user, password: socks.password)
        close(socket)
        #expect(reply != nil && reply != 0, "deep: reply \(reply ?? 255)")
        (socket, reply) = socksConnect(port: socks.port, host: "secure", targetPort: 3306, user: socks.user, password: "wrong")
        close(socket)
        #expect(reply == nil)
    }
}
