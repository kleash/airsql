// Ported from AirSCP 1.4.0 Sources/AirSCPCore/ProxyConnect.swift: the SOCKS5 handshake, HTTP CONNECT with Basic and
// Digest logins, the challenge parser and the TCP connect. AirSQL runs them inside the app (`ProxyRelay`) instead of in a
// helper process, so `open` returns the connected socket rather than relaying standard input and output.
import CryptoKit
import Darwin
import Foundation

/// A connection through an HTTP CONNECT or SOCKS5 proxy: an HTTP proxy is asked for `CONNECT host:port` (with a user
/// name, the login its 407 asks for, Digest or Basic, on a new connection), a SOCKS5 proxy with its handshake.
enum ProxyConnect {
    /// Connects to host:port through `proxy`: the socket, and whatever the server sent along with the proxy's answer.
    /// Failures say what the proxy did, in plain words.
    static func open(_ proxy: ProxySettings, password: String, host: String, port: Int) throws -> (fd: Int32, early: [UInt8]) {
        let proxyPort = proxy.port ?? proxy.kind.defaultPort
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        if proxy.kind == .socks5 {
            let fd = try connectTCP(proxy.host, proxyPort)
            if let failure = socks5(fd, host: host, port: port, username: proxy.user, password: password) {
                close(fd)
                throw AirSQLError(failure.hasPrefix("the SOCKS proxy rejected") ? .authFailed : .refused,
                                  "The proxy didn't connect to \(target): \(failure).")
            }
            return (fd, [])
        }
        // No login at first: the proxy's 407 says how it wants one, and a new connection gives it. Digest when it offers
        // that (the password never goes over the network), else Basic; Digest once more when it says the nonce was stale.
        var authorization: String?
        for attempt in 0..<3 {
            let fd = try connectTCP(proxy.host, proxyPort)
            var head = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
            if let authorization { head += "Proxy-Authorization: \(authorization)\r\n" }
            guard Array((head + "\r\n").utf8).withUnsafeBytes({ writeAll(fd, $0) }) else {
                close(fd)
                throw AirSQLError(.disconnected, "The proxy closed the connection before it was asked for \(target).")
            }
            let (answer, bodyStart): ([UInt8], Int)
            do {
                (answer, bodyStart) = try readHead(fd)
            } catch {
                close(fd)
                throw error
            }
            let statusLine = String(decoding: answer.prefix { $0 != 13 && $0 != 10 }, as: UTF8.self)
            let code = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            if statusLine.hasPrefix("HTTP/"), (200..<300).contains(code) { return (fd, Array(answer[bodyStart...])) }
            close(fd)
            let offered = challenges(in: String(decoding: answer.prefix(bodyStart), as: UTF8.self))
            guard code == 407 else {
                throw AirSQLError(.refused, "The proxy didn't connect to \(target): it answered “\(statusLine)”.",
                                  details: statusLine)
            }
            guard !proxy.user.isEmpty, attempt < 2 else {
                throw AirSQLError(.authFailed, proxy.user.isEmpty
                    ? "The proxy wants a user name and password: add them in the connection's SSH and Proxy tab."
                    : "The proxy didn't accept the user name or password.", details: statusLine)
            }
            let sentDigest = authorization?.hasPrefix("Digest ") == true
            if let digest = offered.first(where: { $0.scheme == "digest" })?.parameters,
               authorization == nil || sentDigest && digest["stale"]?.lowercased() == "true",
               let answerHeader = Self.digest(digest, username: proxy.user, password: password, uri: target, cnonce: cnonce()) {
                authorization = answerHeader
            } else if authorization == nil, offered.isEmpty || offered.contains(where: { $0.scheme == "basic" }) {
                authorization = "Basic " + Data("\(proxy.user):\(password)".utf8).base64EncodedString()
            } else {
                throw AirSQLError(.authFailed, "The proxy didn't accept the user name or password.", details: statusLine)
            }
        }
        throw AirSQLError(.authFailed, "The proxy didn't accept the user name or password.")
    }

    /// The SOCKS5 handshake for CONNECT to host:port on `fd`: nil once connected, else why not (in words).
    static func socks5(_ fd: Int32, host: String, port: Int, username: String, password: String) -> String? {
        var limit = timeval(tv_sec: answerTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        func send(_ bytes: [UInt8]) -> Bool { bytes.withUnsafeBytes { writeAll(fd, $0) } }
        func receive(_ count: Int) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: count), got = 0
            while got < count {
                let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return nil }
                got += n
            }
            return bytes
        }
        let lost = "the proxy closed the connection (or didn't answer within \(answerTimeout) s)"
        // Methods: none, and user name/password when there is a user.
        guard send(username.isEmpty ? [5, 1, 0] : [5, 2, 0, 2]), let chosen = receive(2), chosen[0] == 5 else {
            return lost + ": is it a SOCKS5 proxy?"
        }
        switch chosen[1] {
        case 0: break
        case 2:
            let user = Array(username.utf8.prefix(255)), secret = Array(password.utf8.prefix(255))
            guard send([1, UInt8(user.count)] + user + [UInt8(secret.count)] + secret), let status = receive(2) else { return lost }
            guard status[1] == 0 else { return "the SOCKS proxy rejected the user name or password" }
        default:
            return username.isEmpty ? "the SOCKS proxy wants a user name and password"
                : "the SOCKS proxy accepts none of the login methods AirSQL knows"
        }
        // The target: an IPv4 or IPv6 address as such, else the name (the proxy resolves it).
        var address: [UInt8]
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            address = [1] + withUnsafeBytes(of: &v4) { Array($0) }
        } else if inet_pton(AF_INET6, host, &v6) == 1 {
            address = [4] + withUnsafeBytes(of: &v6) { Array($0) }
        } else {
            let name = Array(host.utf8.prefix(255))
            address = [3, UInt8(name.count)] + name
        }
        guard send([5, 1, 0] + address + [UInt8(port >> 8), UInt8(port & 0xFF)]), let head = receive(4), head[0] == 5 else {
            return lost
        }
        guard head[1] == 0 else {
            let reasons = [1: "the proxy failed", 2: "the proxy's rules don't allow it", 3: "the network can't be reached",
                           4: "the server can't be reached", 5: "the server refused the connection", 6: "it timed out",
                           7: "the proxy doesn't do CONNECT", 8: "the proxy doesn't take that kind of address"]
            return reasons[Int(head[1])] ?? "SOCKS5 error \(head[1])"
        }
        // The address the proxy connected from (skipped), then the port.
        let rest = head[3] == 1 ? 4 : head[3] == 4 ? 16 : Int(receive(1)?.first ?? 0)
        guard receive(rest + 2) != nil else { return lost }
        limit = timeval(tv_sec: 0, tv_usec: 0)  // from now on a quiet connection is no reason to end it
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        return nil
    }

    /// Seconds the proxy has to answer: a little more than a direct connection's timeout, since it connects first.
    static let answerTimeout = 20

    /// The proxy's answer up to its empty line (what follows is already the server's), and where that line ends.
    private static func readHead(_ fd: Int32) throws -> ([UInt8], Int) {
        var limit = timeval(tv_sec: answerTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        defer {
            limit = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        }
        var answer = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN {
                throw AirSQLError(.timeout, "The proxy didn't answer within \(answerTimeout) s: check its address and port.")
            }
            guard count > 0 else { throw AirSQLError(.disconnected, "The proxy closed the connection without answering.") }
            let searchFrom = max(0, answer.count - 3)
            answer += buffer[0..<count]
            if let end = (searchFrom..<max(searchFrom, answer.count - 3)).first(where: { answer[$0..<($0 + 4)] == [13, 10, 13, 10] }) {
                return (answer, end + 4)
            }
            if answer.count > 65536 { throw AirSQLError(.other, "The proxy's answer is too long.") }
        }
    }

    /// The Proxy-Authenticate challenges in a response head: each scheme (lowercased) with its parameters.
    static func challenges(in head: String) -> [(scheme: String, parameters: [String: String])] {
        head.components(separatedBy: "\r\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "proxy-authenticate" else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let scheme = String(value.prefix { !$0.isWhitespace })
            var parameters: [String: String] = [:]
            var rest = Substring(value.dropFirst(scheme.count))
            // name=value or name="quoted, value", separated by commas.
            while let equals = rest.firstIndex(of: "=") {
                let name = rest[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: " ,")).lowercased()
                rest = rest[rest.index(after: equals)...].drop { $0 == " " }
                var parsed = ""
                if rest.first == "\"" {
                    rest = rest.dropFirst()
                    while let character = rest.first, character != "\"" {
                        if character == "\\" { rest = rest.dropFirst() }
                        if let next = rest.first { parsed.append(next) }
                        rest = rest.dropFirst()
                    }
                    rest = rest.dropFirst()
                } else {
                    parsed = String(rest.prefix { $0 != "," }).trimmingCharacters(in: .whitespaces)
                    rest = rest.dropFirst(parsed.count)
                }
                parameters[name] = parsed
            }
            return (scheme.lowercased(), parameters)
        }
    }

    /// The Proxy-Authorization value answering a Digest challenge (RFC 7616: MD5 or SHA-256, their -sess forms, qop
    /// auth or none), for CONNECT to `uri`; nil for an algorithm or qop it can't answer.
    static func digest(_ challenge: [String: String], username: String, password: String, uri: String, cnonce: String,
                       method: String = "CONNECT") -> String? {
        guard let realm = challenge["realm"], let nonce = challenge["nonce"] else { return nil }
        let algorithm = challenge["algorithm"] ?? "MD5"
        let hash: (String) -> String
        switch algorithm.uppercased().replacingOccurrences(of: "-SESS", with: "") {
        case "MD5": hash = { Insecure.MD5.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        case "SHA-256": hash = { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        default: return nil
        }
        let qops = (challenge["qop"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard qops.isEmpty || qops.contains("auth") else { return nil }
        let nc = "00000001"
        var a1 = hash("\(username):\(realm):\(password)")
        if algorithm.uppercased().hasSuffix("-SESS") { a1 = hash("\(a1):\(nonce):\(cnonce)") }
        let a2 = hash("\(method):\(uri)")
        let response = qops.isEmpty ? hash("\(a1):\(nonce):\(a2)") : hash("\(a1):\(nonce):\(nc):\(cnonce):auth:\(a2)")
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var parts = ["username=\(quoted(username))", "realm=\(quoted(realm))", "nonce=\(quoted(nonce))", "uri=\(quoted(uri))",
                     "algorithm=\(algorithm)", "response=\(quoted(response))"]
        if !qops.isEmpty { parts += ["qop=auth", "nc=\(nc)", "cnonce=\(quoted(cnonce))"] }
        if let opaque = challenge["opaque"] { parts.append("opaque=\(quoted(opaque))") }
        return "Digest " + parts.joined(separator: ", ")
    }

    /// A fresh client nonce: 16 random bytes, hex.
    private static func cnonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// A TCP connection to host:port (each of its addresses in turn).
    private static func connectTCP(_ host: String, _ port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0 else {
            throw AirSQLError(.unknownHost, "Can't find the proxy \(host): \(String(cString: gai_strerror(status))).")
        }
        defer { freeaddrinfo(list) }
        var error = ECONNREFUSED
        var next = list
        while let info = next?.pointee {
            next = info.ai_next
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            guard fd >= 0 else {
                error = errno
                continue
            }
            var seconds: Int32 = 15
            setsockopt(fd, IPPROTO_TCP, TCP_CONNECTIONTIMEOUT, &seconds, socklen_t(MemoryLayout<Int32>.size))
            if connect(fd, info.ai_addr, info.ai_addrlen) == 0 {
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
                return fd
            }
            error = errno
            close(fd)
        }
        throw AirSQLError(error == ETIMEDOUT ? .timeout : error == ECONNREFUSED ? .refused : .noRoute,
                          "Can't connect to the proxy \(host):\(port): \(String(cString: strerror(error))).")
    }

    static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }
}
