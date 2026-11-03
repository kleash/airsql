// Ported from AirSCP 1.4.0 Sources/AirSCPCore/Askpass.swift: PromptKind, AskpassRequest, Askpass (the helper, the prompt
// classifier) and AskpassServer, without the proxy-password message (AirSQL's proxies run inside the app) and the
// silent reconnect (AirSQL never reconnects by itself).
import Darwin
import Foundation

/// What an ssh prompt asks for.
public enum PromptKind: Equatable {
    /// "Are you sure you want to continue connecting (yes/no/[fingerprint])?": answer "yes" to trust.
    case hostKey(host: String, fingerprint: String)
    /// A login password; user and host come from "user@host's password:" or "(user@host) Password:".
    case password(user: String?, host: String?)
    /// A key's passphrase.
    case passphrase
    /// Anything else (verification codes, confirmations): show the prompt text.
    case other
}

/// A prompt from ssh, sent by the askpass helper.
public struct AskpassRequest {
    /// AIRSQL_ASKPASS_ID of the ssh that asked: the connection's id.
    public let id: String
    public let prompt: String
    /// The process that asked (the helper's parent): a password retried by the same process was wrong.
    public let pid: Int32
    /// The asking process is one AirSQL started (or one of theirs): only such get saved passwords.
    public var fromAirSQL = true
    public var kind: PromptKind { Askpass.classify(prompt) }
}

/// SSH_ASKPASS support: AirSQL's own binary is the askpass program. It sends the prompt to the running app over a Unix
/// socket and prints the reply.
public enum Askpass {
    /// The helper: main.swift calls it when AIRSQL_ASKPASS_SOCK is set. Prints the answer and returns 0, or returns 1
    /// when the app cancels, doesn't answer or can't be reached.
    public static func runHelper(prompt: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        guard let path = environment["AIRSQL_ASKPASS_SOCK"] else { return 1 }
        let request: [String: Any] = ["id": environment["AIRSQL_ASKPASS_ID"] ?? "", "prompt": prompt, "pid": Int(getppid()),
                                      "token": environment["AIRSQL_ASKPASS_TOKEN"] ?? ""]
        guard let answer = exchange(request, socket: path)?["answer"] as? String else { return 1 }
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        return 0
    }

    /// Sends `request` to the app over the socket at `path` and returns its reply; nil when the app can't be reached, or
    /// the ssh that ran the helper has gone meanwhile (a cancelled connect).
    static func exchange(_ request: [String: Any], socket path: String) -> [String: Any]? {
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
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            // Wake up every second to notice when the ssh that asked has gone.
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 1000)
            if ready == 0 {
                if getppid() == 1 { return nil }
                continue
            }
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        return try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
    }

    /// What a prompt asks for, from its text.
    public static func classify(_ prompt: String) -> PromptKind {
        let lower = prompt.lowercased()
        if lower.contains("(yes/no") || lower.contains("continue connecting") {
            return .hostKey(host: between(prompt, "authenticity of host '", "'").map(hostKeyName) ?? "",
                            fingerprint: fingerprint(in: prompt) ?? "")
        }
        if lower.contains("passphrase") { return .passphrase }
        if lower.contains("password") {
            // "user@host's password: " (password) or "(user@host) Password: " (keyboard-interactive).
            let target = between(prompt, "(", ")") ?? prompt.components(separatedBy: "'s password").first
            if let target, target.contains("@"), !target.contains(" "), let at = target.lastIndex(of: "@") {
                return .password(user: String(target[..<at]), host: String(target[target.index(after: at)...]))
            }
            return .password(user: nil, host: nil)
        }
        return .other
    }

    /// The askpass variables for an ssh whose prompts go to the handler for `id`.
    static func environment(helper: String, socket: String, token: String, id: String) -> [String: String] {
        ["SSH_ASKPASS": helper, "SSH_ASKPASS_REQUIRE": "force", "AIRSQL_ASKPASS_SOCK": socket, "AIRSQL_ASKPASS_ID": id,
         "AIRSQL_ASKPASS_TOKEN": token]
    }

    private static func between(_ text: String, _ start: String, _ end: String) -> String? {
        guard let lower = text.range(of: start), let upper = text.range(of: end, range: lower.upperBound..<text.endIndex)
        else { return nil }
        return String(text[lower.upperBound..<upper.lowerBound])
    }

    /// "[127.0.0.1]:2222 ([127.0.0.1]:2222)" → "[127.0.0.1]:2222".
    private static func hostKeyName(_ text: String) -> String {
        text.components(separatedBy: " (").first ?? text
    }

    private static func fingerprint(in text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace }).first { $0.hasPrefix("SHA256:") || $0.hasPrefix("MD5:") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    }

    /// Whether the process at the other end of a Unix socket is one this app started, or a descendant of one (ssh's
    /// askpass helper, a jump host's ssh).
    static func startedByThisApp(peerOf connection: Int32) -> Bool {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return false }
        let app = getpid()
        for _ in 0..<32 {
            var info = proc_bsdinfo()
            guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
            else { return false }
            if pid_t(info.pbi_ppid) == app { return true }
            pid = pid_t(info.pbi_ppid)
        }
        return false
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
}
