// Ported from AirSCP 1.4.0 Tests/AirSCPTests/ProxyTests.swift (TestProxy, TestSOCKS) and SessionTests.swift
// (listener). AirSCP's TestProxy checks Digest with ProxyConnect's own functions; AirSQL has no ProxyConnect yet, so
// HTTPDigest below does it, and the client side the tests need follows at the end.
import CryptoKit
import Darwin
import Foundation

/// A tiny HTTP CONNECT proxy on 127.0.0.1 for the tests: Basic auth when made with credentials (Digest when made with
/// `digest`, an algorithm: it then calls the first nonce stale when `staleOnce`), CONNECT to 127.0.0.1
/// only (the tests' own servers), relaying both ways. `stop()` closes it and every connection through it, as a lost
/// network would.
final class TestProxy {
    static let realm = "airsql test"

    let port: Int
    /// The request heads it received.
    let requests = Recorder<String>()
    /// The ones that carried a login (each came after one the proxy answered by asking for it).
    var logins: [String] { requests.all.filter { $0.contains("\r\nProxy-Authorization: ") } }
    private let expected: String?
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var _away = false
    private var connections: Set<Int32> = []
    private let finished = DispatchSemaphore(value: 0)
    private let digest: String?
    private let credentials: (user: String, password: String)?
    private var staleLeft: Bool

    init(user: String? = nil, password: String = "", port wanted: Int = 0, digest: String? = nil, staleOnce: Bool = false) throws {
        expected = user.map { "Basic " + Data("\($0):\(password)".utf8).base64EncodedString() }
        self.digest = digest
        credentials = user.map { ($0, password) }
        staleLeft = staleOnce
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(wanted).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound, listen(fd, 16) == 0 else {
            close(fd)
            throw SupportError("the test proxy can't listen on port \(wanted)")
        }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// While true it plays a network that is down: its connections are cut and new ones closed at once. It keeps its
    /// port meanwhile (one given back and taken again could be another test's by then).
    var away: Bool {
        get { locked { _away } }
        set {
            locked {
                _away = newValue
                if newValue { connections.forEach { shutdown($0, SHUT_RDWR) } }
            }
        }
    }

    /// Stops listening and cuts every connection.
    func stop() {
        let first = locked { () -> Bool in
            defer { stopped = true }
            connections.forEach { shutdown($0, SHUT_RDWR) }
            return !stopped
        }
        if first { finished.wait() }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func acceptLoop() {
        while !locked({ stopped }) {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            if away {
                close(client)
                continue
            }
            guard track(client) else { continue }
            Thread.detachNewThread { [self] in serve(client) }
        }
        close(listener)
        finished.signal()
    }

    private func serve(_ client: Int32) {
        var head = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !String(decoding: head, as: UTF8.self).contains("\r\n\r\n") {
            let count = read(client, &buffer, buffer.count)
            guard count > 0, head.count < 16384 else { return finish(client) }
            head += buffer[0..<count]
        }
        let text = String(decoding: head, as: UTF8.self)
        requests.append(text)
        let lines = text.components(separatedBy: "\r\n")
        let authorization = lines.first { $0.lowercased().hasPrefix("proxy-authorization:") }
            .map { $0.dropFirst("proxy-authorization:".count).trimmingCharacters(in: .whitespaces) }
        let words = lines[0].split(separator: " ")
        if let digest, let credentials {
            // Digest only: a Basic answer (or none) gets the challenge; a Digest answer is checked as the proxy would.
            let nonce = "nonce-\(requests.all.count)"
            let challenge = "407 Proxy Authentication Required\r\nProxy-Authenticate: Digest realm=\"\(TestProxy.realm)\", "
                + "nonce=\"\(nonce)\", qop=\"auth\", algorithm=\(digest), opaque=\"op\""
            guard let authorization, authorization.hasPrefix("Digest ") else { return answer(client, challenge) }
            let sent = HTTPDigest.parameters(authorization.dropFirst("Digest ".count))
            let uri = String(words.count > 1 ? words[1] : "")
            let good = HTTPDigest.response(algorithm: digest, username: credentials.user, realm: TestProxy.realm,
                                           password: credentials.password, method: "CONNECT", uri: uri,
                                           nonce: sent["nonce"] ?? "", nc: sent["nc"] ?? "", cnonce: sent["cnonce"] ?? "")
            guard sent["username"] == credentials.user, sent["realm"] == TestProxy.realm, sent["uri"] == uri,
                  sent["qop"] == "auth", sent["opaque"] == "op", let good, sent["response"] == good else {
                return answer(client, challenge)
            }
            if locked({ defer { staleLeft = false }; return staleLeft }) {
                return answer(client, challenge + ", stale=true")
            }
        } else if let expected, authorization != expected {
            return answer(client, "407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"\(TestProxy.realm)\"")
        }
        guard words.count == 3, words[0] == "CONNECT", let colon = words[1].lastIndex(of: ":"),
              ["127.0.0.1", "localhost"].contains(words[1][..<colon]), let port = Int(words[1][colon...].dropFirst()) else {
            return answer(client, "403 Forbidden")
        }
        let upstream = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
        guard connected else {
            close(upstream)
            return answer(client, "502 Bad Gateway")
        }
        // (track closes it when the proxy has stopped: closing it again here closed whatever took its number meanwhile.)
        guard track(upstream) else { return answer(client, "502 Bad Gateway") }
        guard send(client, "HTTP/1.1 200 Connection established\r\n\r\n") else {
            finish(upstream)
            return finish(client)
        }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            TestProxy.relay(from: client, to: upstream)
            done.signal()
        }
        TestProxy.relay(from: upstream, to: client)
        done.wait()
        finish(upstream)
        finish(client)
    }

    private func answer(_ client: Int32, _ status: String) {
        _ = send(client, "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        finish(client)
    }

    private func send(_ fd: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return write(fd, bytes, bytes.count) == bytes.count
    }

    /// Copies until the end of `source`, then passes the end on.
    static func relay(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0, write(destination, buffer, count) == count else { break }
        }
        shutdown(destination, SHUT_WR)
    }

    /// Tracked so that `stop` can cut it; false (and closed) when already stopped.
    private func track(_ fd: Int32) -> Bool {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let added = locked { () -> Bool in
            if stopped { return false }
            connections.insert(fd)
            return true
        }
        if !added { close(fd) }
        return added
    }

    private func finish(_ fd: Int32) {
        locked {
            connections.remove(fd)
            close(fd)
        }
    }
}

/// A tiny SOCKS5 proxy on 127.0.0.1 for the tests (RFC 1928, with RFC 1929's login when made with a user): CONNECT to
/// 127.0.0.1 only, relaying both ways. It records the addresses asked for.
final class TestSOCKS {
    let port: Int
    let asked = Recorder<String>()
    private let listener: Int32
    private let credentials: (String, String)?

    init(user: String? = nil, password: String = "") throws {
        credentials = user.map { ($0, password) }
        let found = try AirSQLTests.listener()
        close(found.fd6)
        listener = found.fd
        port = found.port
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    func stop() { shutdown(listener, SHUT_RDWR); close(listener) }

    private func serve(_ client: Int32) {
        defer { close(client) }
        func read(_ count: Int) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: count), got = 0
            while got < count {
                let n = bytes.withUnsafeMutableBytes { Darwin.read(client, $0.baseAddress! + got, count - got) }
                guard n > 0 else { return nil }
                got += n
            }
            return bytes
        }
        func send(_ bytes: [UInt8]) { _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) } }
        guard let head = read(2), head[0] == 5, let methods = read(Int(head[1])) else { return }
        if let (user, password) = credentials {
            guard methods.contains(2) else { return send([5, 0xFF]) }
            send([5, 2])
            guard let version = read(2), version[0] == 1, let name = read(Int(version[1])), let length = read(1),
                  let secret = read(Int(length[0])) else { return }
            let ok = String(decoding: name, as: UTF8.self) == user && String(decoding: secret, as: UTF8.self) == password
            send([1, ok ? 0 : 1])
            guard ok else { return }
        } else {
            send([5, 0])
        }
        guard let request = read(4), request[1] == 1 else { return }
        var host = ""
        switch request[3] {
        case 1: host = (read(4) ?? []).map(String.init).joined(separator: ".")
        case 3: host = read(1).flatMap { read(Int($0[0])) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        default: return send([5, 8, 0, 1, 0, 0, 0, 0, 0, 0])
        }
        guard let portBytes = read(2) else { return }
        let port = Int(portBytes[0]) << 8 | Int(portBytes[1])
        asked.append("\(host):\(port)")
        guard ["127.0.0.1", "localhost"].contains(host) else { return send([5, 2, 0, 1, 0, 0, 0, 0, 0, 0]) }
        let upstream = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
        guard connected else {
            close(upstream)
            return send([5, 5, 0, 1, 0, 0, 0, 0, 0, 0])
        }
        send([5, 0, 0, 1, 127, 0, 0, 1, portBytes[0], portBytes[1]])
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            TestProxy.relay(from: client, to: upstream)
            done.signal()
        }
        TestProxy.relay(from: upstream, to: client)
        done.wait()
        close(upstream)
    }
}

/// A TCP listener on 127.0.0.1 and ::1 at the same free port.
func listener() throws -> (port: Int, fd: Int32, fd6: Int32) {
    for _ in 0..<20 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                bind(fd, pointer, length)
                return getsockname(fd, pointer, &length)
            }
        }
        listen(fd, 4)
        let port = UInt16(bigEndian: address.sin_port)
        let fd6 = socket(AF_INET6, SOCK_STREAM, 0)
        var address6 = sockaddr_in6()
        address6.sin6_family = sa_family_t(AF_INET6)
        address6.sin6_addr = in6addr_loopback
        address6.sin6_port = port.bigEndian
        let bound = withUnsafePointer(to: &address6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        if bound == 0 && listen(fd6, 4) == 0 { return (Int(port), fd, fd6) }
        close(fd)
        close(fd6)
    }
    throw SupportError("no free port")
}

/// HTTP Digest (RFC 7616: MD5 and SHA-256, qop "auth"), for TestProxy's check and the tests' own answers.
enum HTTPDigest {
    /// The parameters of a Digest header after the scheme: `name=token` or `name="quoted"` (commas and \-escapes
    /// inside quotes), separated by commas. Names in lower case.
    static func parameters<S: StringProtocol>(_ text: S) -> [String: String] {
        var result: [String: String] = [:]
        var rest = Substring(text)
        while true {
            rest = rest.drop { $0 == " " || $0 == "," }
            guard let equals = rest.firstIndex(of: "=") else { return result }
            let name = rest[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            rest = rest[rest.index(after: equals)...].drop { $0 == " " }
            var value = ""
            if rest.first == "\"" {
                rest = rest.dropFirst()
                while let character = rest.first, character != "\"" {
                    rest = rest.dropFirst()
                    if character == "\\", let escaped = rest.first {
                        value.append(escaped)
                        rest = rest.dropFirst()
                    } else {
                        value.append(character)
                    }
                }
                rest = rest.dropFirst()
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<end].trimmingCharacters(in: .whitespaces)
                rest = rest[end...]
            }
            result[name] = value
        }
    }

    /// The `response` for qop "auth", or nil for an algorithm other than MD5 and SHA-256.
    static func response(algorithm: String, username: String, realm: String, password: String, method: String, uri: String,
                         nonce: String, nc: String, cnonce: String) -> String? {
        let hash: (String) -> String
        switch algorithm.uppercased() {
        case "MD5": hash = { Insecure.MD5.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        case "SHA-256": hash = { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        default: return nil
        }
        return hash([hash("\(username):\(realm):\(password)"), nonce, nc, cnonce, "auth", hash("\(method):\(uri)")]
            .joined(separator: ":"))
    }

    /// The Proxy-Authorization value answering a challenge's parameters, or nil when its algorithm or qop can't be
    /// answered.
    static func authorization(_ challenge: [String: String], username: String, password: String, uri: String,
                              cnonce: String, method: String = "CONNECT") -> String? {
        let algorithm = challenge["algorithm"] ?? "MD5", realm = challenge["realm"] ?? "", nonce = challenge["nonce"] ?? ""
        guard (challenge["qop"] ?? "auth").split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "auth" }),
              let response = response(algorithm: algorithm, username: username, realm: realm, password: password,
                                      method: method, uri: uri, nonce: nonce, nc: "00000001", cnonce: cnonce) else { return nil }
        var value = "Digest username=\"\(username)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", "
            + "algorithm=\(algorithm), response=\"\(response)\", qop=auth, nc=00000001, cnonce=\"\(cnonce)\""
        if let opaque = challenge["opaque"] { value += ", opaque=\"\(opaque)\"" }
        return value
    }
}

// MARK: The client side, for the tests of these proxies and of the lab's

/// A connection to 127.0.0.1:`port`, or -1. The caller closes it.
func connectTCP(_ port: Int) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = UInt16(port).bigEndian
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
    if connected { return fd }
    close(fd)
    return -1
}

/// A connection to the unix socket at `path`, or -1. The caller closes it.
func connectUnix(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        close(fd)
        return -1
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    } == 0
    if connected { return fd }
    close(fd)
    return -1
}

/// Exactly `count` bytes from `fd`: fewer when it closes first or `timeout` passes. Never more, so what comes next
/// (a server's greeting after a proxy's answer) stays unread.
func receive(_ fd: Int32, count: Int, timeout: TimeInterval = 15) -> [UInt8] {
    guard fd >= 0 else { return [] }
    var received = [UInt8](repeating: 0, count: count)
    var got = 0
    let deadline = Date().addingTimeInterval(timeout)
    while got < count, Date() < deadline {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, 100) >= 0 else { break }
        guard poller.revents != 0 else { continue }
        let n = received.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
        guard n > 0 else { break }
        got += n
    }
    return Array(received[0..<got])
}

/// The bytes from `fd` up to and including `end` (or what came before it closed or `timeout` passed).
func receive(_ fd: Int32, through end: String, timeout: TimeInterval = 15) -> [UInt8] {
    var received = [UInt8]()
    while !received.suffix(end.utf8.count).elementsEqual(end.utf8) {
        let byte = receive(fd, count: 1, timeout: timeout)
        guard byte.count == 1 else { break }
        received += byte
    }
    return received
}

/// Sends `bytes` on `fd`.
func send(_ fd: Int32, _ bytes: [UInt8]) {
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

/// An HTTP CONNECT to `target` through the proxy at 127.0.0.1:`port`, with `authorization` as Proxy-Authorization:
/// the connection (relaying to `target` after a 200; -1 when the proxy is down) and the head of the answer.
func proxyConnect(port: Int, target: String, authorization: String? = nil) -> (fd: Int32, head: String) {
    let fd = connectTCP(port)
    guard fd >= 0 else { return (-1, "") }
    var request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
    if let authorization { request += "Proxy-Authorization: \(authorization)\r\n" }
    send(fd, Array((request + "\r\n").utf8))
    return (fd, String(decoding: receive(fd, through: "\r\n\r\n"), as: UTF8.self))
}

/// The parameters of the Digest challenge in a proxy's 407 answer.
func digestChallenge(in head: String) -> [String: String]? {
    head.components(separatedBy: "\r\n")
        .first { $0.lowercased().hasPrefix("proxy-authenticate: digest ") }
        .map { HTTPDigest.parameters($0.dropFirst("proxy-authenticate: digest ".count)) }
}

/// A SOCKS5 CONNECT to `host`:`targetPort` through the proxy at 127.0.0.1:`port` (logging in when given a user): the
/// connection (relaying after a success) and the proxy's reply code (0 is success; nil when it refused the login or
/// answered nothing).
func socksConnect(port: Int, host: String, targetPort: Int, user: String? = nil, password: String = "") -> (fd: Int32, reply: UInt8?) {
    let fd = connectTCP(port)
    guard fd >= 0 else { return (-1, nil) }
    send(fd, user == nil ? [5, 1, 0] : [5, 1, 2])
    guard receive(fd, count: 2) == [5, user == nil ? 0 : 2] else { return (fd, nil) }
    if let user {
        send(fd, [1, UInt8(user.utf8.count)] + Array(user.utf8) + [UInt8(password.utf8.count)] + Array(password.utf8))
        guard receive(fd, count: 2) == [1, 0] else { return (fd, nil) }
    }
    send(fd, [5, 1, 0, 3, UInt8(host.utf8.count)] + Array(host.utf8) + [UInt8(targetPort >> 8), UInt8(targetPort & 0xFF)])
    // The reply: version, code, 0, the bound address (its type, then IPv4, a name or IPv6) and port.
    let reply = receive(fd, count: 4)
    guard reply.count == 4 else { return (fd, nil) }
    switch reply[3] {
    case 1: _ = receive(fd, count: 4 + 2)
    case 3: _ = receive(fd, count: Int(receive(fd, count: 1).first ?? 0) + 2)
    default: _ = receive(fd, count: 16 + 2)
    }
    return (fd, reply[1])
}
