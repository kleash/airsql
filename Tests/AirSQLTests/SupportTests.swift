import Darwin
import Foundation
import Testing

/// The tests' own sshd and proxies (Support/): what CI proves routes with, having no Docker.
struct SupportTests {
    private func banner(_ fd: Int32) -> String { String(decoding: receive(fd, through: "\n"), as: UTF8.self) }

    /// What a tunnel does: ssh -N -L <unix socket>:127.0.0.1:<port> through the throwaway sshd, here to the sshd's own
    /// port, so that its banner comes back through the forward. And a command, with the key that has a passphrase.
    @Test func throwawaySSHDForwardsToAUnixSocket() async throws {
        try await withServer { server in
            let socket = try scratch() + "/s.sock"
            let ssh = Process()
            ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            ssh.arguments = server.sshOptions() + ["-N", "-o", "ExitOnForwardFailure=yes",
                                                   "-L", "\(socket):127.0.0.1:\(server.port)", "127.0.0.1"]
            ssh.environment = TestEnvironment.environment
            ssh.standardInput = FileHandle.nullDevice
            ssh.standardError = FileHandle.nullDevice
            try ssh.run()
            defer { ssh.terminate() }
            #expect(await eventually(timeout: 30) { FileManager.default.fileExists(atPath: socket) || !ssh.isRunning })
            let fd = connectUnix(socket)
            defer { close(fd) }
            #expect(banner(fd).hasPrefix("SSH-2.0-"))

            let echo = try await run(["/usr/bin/ssh"] + server.sshOptions() + ["127.0.0.1", "echo", "hello"])
            #expect(echo.output == "hello\n")
            // The other key wants its passphrase, which BatchMode can't ask for.
            await #expect(throws: SupportError.self) {
                try await run(["/usr/bin/ssh"] + server.sshOptions(key: server.encryptedKey) + ["127.0.0.1", "true"])
            }
        }
    }

    /// TestProxy: 407 without the login, through with Basic, CONNECT to 127.0.0.1 only.
    @Test func testProxyTakesBasic() async throws {
        try await withServer { server in
            let proxy = try TestProxy(user: "lab", password: "proxy secret")
            defer { proxy.stop() }
            let target = "127.0.0.1:\(server.port)", basic = "Basic " + Data("lab:proxy secret".utf8).base64EncodedString()
            var (fd, head) = proxyConnect(port: proxy.port, target: target)
            close(fd)
            #expect(head.hasPrefix("HTTP/1.1 407 ") && head.contains("Proxy-Authenticate: Basic realm="), "\(head)")
            (fd, head) = proxyConnect(port: proxy.port, target: target, authorization: basic)
            #expect(head.hasPrefix("HTTP/1.1 200 ") && banner(fd).hasPrefix("SSH-2.0-"), "\(head)")
            close(fd)
            (fd, head) = proxyConnect(port: proxy.port, target: "example.invalid:22", authorization: basic)
            close(fd)
            #expect(head.hasPrefix("HTTP/1.1 403 "), "\(head)")
            #expect(proxy.logins.count == 2 && proxy.requests.all.count == 3)
        }
    }

    /// TestProxy with Digest: MD5 and SHA-256, a stale nonce answered again, a wrong password refused; never Basic.
    @Test func testProxyTakesDigest() async throws {
        try await withServer { server in
            let target = "127.0.0.1:\(server.port)"
            for (algorithm, stale) in [("MD5", false), ("SHA-256", false), ("SHA-256", true)] {
                let proxy = try TestProxy(user: "lab", password: "proxy secret", digest: algorithm, staleOnce: stale)
                defer { proxy.stop() }
                func answer(_ head: String, password: String = "proxy secret") throws -> String {
                    let challenge = try #require(digestChallenge(in: head), "\(algorithm): \(head)")
                    return try #require(HTTPDigest.authorization(challenge, username: "lab", password: password, uri: target,
                                                                 cnonce: "cnonce-\(proxy.requests.all.count)"))
                }
                var (fd, head) = proxyConnect(port: proxy.port, target: target)
                close(fd)
                for _ in 0..<(stale ? 2 : 1) where !head.contains(" 200 ") {
                    let authorization = try answer(head)
                    (fd, head) = proxyConnect(port: proxy.port, target: target, authorization: authorization)
                    if !head.contains(" 200 ") { close(fd) }
                }
                #expect(head.hasPrefix("HTTP/1.1 200 ") && banner(fd).hasPrefix("SSH-2.0-"), "\(algorithm) \(stale): \(head)")
                close(fd)
                #expect(proxy.requests.all.count == (stale ? 3 : 2))
                // A wrong password: the 407 again, and no stale nonce this time.
                (fd, head) = proxyConnect(port: proxy.port, target: target)
                close(fd)
                let wrong = try answer(head, password: "wrong")
                (fd, head) = proxyConnect(port: proxy.port, target: target, authorization: wrong)
                close(fd)
                #expect(head.hasPrefix("HTTP/1.1 407 ") && !head.contains("stale=true"), "\(algorithm): \(head)")
                #expect(proxy.requests.all.allSatisfy { !$0.contains("Basic ") && !$0.contains("proxy secret") })
            }
        }
    }

    /// RFC 7616's own example, byte for byte: the arithmetic TestProxy checks Digest answers with.
    @Test func digestAnswersAsRFC7616Says() throws {
        let challenge = ["realm": "http-auth@example.org", "qop": "auth, auth-int",
                         "nonce": "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v", "opaque": "FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS"]
        let cnonce = "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ"
        var md5 = challenge
        md5["algorithm"] = "MD5"
        let md5Answer = try #require(HTTPDigest.authorization(md5, username: "Mufasa", password: "Circle of Life",
                                                              uri: "/dir/index.html", cnonce: cnonce, method: "GET"))
        #expect(md5Answer.contains("response=\"8ca523f5e9506fed4657c9700eebdbec\""))
        #expect(md5Answer.contains("qop=auth, nc=00000001, cnonce=\"\(cnonce)\"") && md5Answer.contains("opaque=\"FQhe"))
        var sha = challenge
        sha["algorithm"] = "SHA-256"
        let shaAnswer = try #require(HTTPDigest.authorization(sha, username: "Mufasa", password: "Circle of Life",
                                                              uri: "/dir/index.html", cnonce: cnonce, method: "GET"))
        #expect(shaAnswer.contains("response=\"753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1\""))
        // What it can't answer, and a header's parameters (quoted commas and escapes).
        #expect(HTTPDigest.authorization(["realm": "r", "nonce": "n", "algorithm": "SHA-512-256"], username: "u", password: "p",
                                         uri: "h:22", cnonce: "c") == nil)
        #expect(HTTPDigest.authorization(["realm": "r", "nonce": "n", "qop": "auth-int"], username: "u", password: "p", uri: "h:22",
                                         cnonce: "c") == nil)
        #expect(HTTPDigest.parameters("realm=\"a, \\\"b\\\"\", nonce=xyz, stale=TRUE") == ["realm": "a, \"b\"", "nonce": "xyz",
                                                                                           "stale": "TRUE"])
    }

    /// TestSOCKS: without and with a login, a wrong password refused, CONNECT to 127.0.0.1 only.
    @Test func testSOCKSRelays() async throws {
        try await withServer { server in
            for user in [nil, "lab"] as [String?] {
                let socks = try TestSOCKS(user: user, password: "socks secret")
                defer { socks.stop() }
                var (fd, reply) = socksConnect(port: socks.port, host: "127.0.0.1", targetPort: server.port, user: user,
                                               password: "socks secret")
                #expect(reply == 0 && banner(fd).hasPrefix("SSH-2.0-"), "\(user ?? "-"): reply \(reply ?? 255)")
                close(fd)
                (fd, reply) = socksConnect(port: socks.port, host: "example.invalid", targetPort: 22, user: user,
                                           password: "socks secret")
                close(fd)
                #expect(reply == 2)
                if user != nil {
                    (fd, reply) = socksConnect(port: socks.port, host: "127.0.0.1", targetPort: server.port, user: user,
                                               password: "wrong")
                    close(fd)
                    #expect(reply == nil)
                }
                #expect(socks.asked.all == ["127.0.0.1:\(server.port)", "example.invalid:22"])
            }
        }
    }
}
