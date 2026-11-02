// Ported from AirSCP 1.4.0 Sources/AirSCPCore/Askpass.swift (exchange, unixAddress) and AgentBridge.swift (directory,
// socketPathProblem).
import Darwin
import Foundation

/// The agent socket's address and the helper's side of it (`AgentListener` is the app's).
public enum AgentSocket {
    /// `<support dir>/agent` (0700): the socket and the token file. AIRSQL_SUPPORT_DIR gives each instance its own.
    public static var directory: URL { Store.directory.appendingPathComponent("agent", isDirectory: true) }

    /// Sends `request` to the app over the socket at `path` and returns its reply, handing each progress line to
    /// `progress` as it comes. nil when the app can't be reached or didn't answer.
    static func exchange(_ request: [String: Any], socket path: String,
                         progress: ([String: Any]) -> Void = { _ in }) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard var address = unixAddress(path), withUnsafePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }) == 0 else { return nil }
        guard let body = try? JSONSerialization.data(withJSONObject: request),
              body.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == body.count else { return nil }
        shutdown(fd, SHUT_WR)
        var pending = Data(), reply: [String: Any]?
        var buffer = [UInt8](repeating: 0, count: 65536)
        func lines() {
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if object.count == 1, let report = object["progress"] as? [String: Any] { progress(report) } else { reply = object }
            }
        }
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            pending.append(contentsOf: buffer[0..<count])
            lines()
        }
        pending.append(0x0A)
        lines()
        return reply
    }

    static func unixAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Why agents can't use `socket`: a path longer than a socket's (a long AIRSQL_SUPPORT_DIR).
    static func socketPathProblem(_ socket: String) -> String? {
        guard unixAddress(socket) == nil else { return nil }
        return "The settings folder's path is too long for the agent socket (\(socket.utf8.count) bytes; a socket's path "
            + "may have 103): use a shorter folder (AIRSQL_SUPPORT_DIR)."
    }

    /// Whether something listens at `path` (a socket left by a crash doesn't).
    static func answers(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = unixAddress(path) else { return false }
        defer { close(fd) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    /// Compares tokens in constant time.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// JSON that NSJSONSerialization takes: it raises (an Objective-C exception no Swift code catches) for NaN, infinite
/// numbers and values that aren't JSON.
enum AgentJSON {
    static func finite(_ value: Any) -> Any {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.doubleValue.isFinite ? number : NSNull()
        case let array as [Any]: return array.map(finite)
        case let object as [String: Any]: return object.mapValues(finite)
        case is String, is NSNumber, is NSNull: return value
        default: return String(describing: value)
        }
    }

    /// One line of JSON text (sorted keys, so tests and diffs are stable).
    static func text(_ value: Any) -> String {
        String(decoding: data(value), as: UTF8.self)
    }

    static func data(_ value: Any) -> Data {
        let safe = finite(value)
        guard JSONSerialization.isValidJSONObject(safe) else { return Data("{}".utf8) }
        return (try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
}
