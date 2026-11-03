// The ssh rules follow AirSCP 1.4.0 Sources/AirSCPCore/ErrorMapping.swift (ErrorMapping.map), cut to what a tunnel meets.
import Foundation

extension ErrorMapping {
    /// Plain words for why a tunnel's ssh stopped, from its error output (the first rule that matches wins); ssh's own
    /// words stay in `details`, without its progress notes.
    public static func ssh(_ stderr: String, status: Int32) -> AirSQLError {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init).filter { line in
            !line.hasPrefix("Authenticated to ") && !line.hasPrefix("Warning: Permanently added")
                && !line.hasPrefix("Transferred: ") && !line.hasPrefix("Bytes per second")
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        func has(_ needle: String) -> Bool { text.range(of: needle, options: .caseInsensitive) != nil }
        func error(_ kind: AirSQLError.Kind, _ message: String) -> AirSQLError {
            AirSQLError(kind, message, details: text.isEmpty ? "ssh ended with status \(status)" : text)
        }
        let hop = text.range(of: #"host key for \S+ has changed"#, options: [.regularExpression, .caseInsensitive])
            .map { String(text[$0].dropFirst("host key for ".count).dropLast(" has changed".count)) }
        if has("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return error(.hostKeyChanged, "The identity (host key) of \(hop ?? "an SSH host") has changed since you last "
                + "connected. Someone may be intercepting the connection, or the server was reinstalled. Ask its administrator "
                + "before you remove the old key from known_hosts.")
        }
        if has("Host key verification failed") {
            return error(.other, "An SSH host's key wasn't trusted, so AirSQL didn't connect. Connect again and trust it "
                + "if its fingerprint is the one you expect.")
        }
        if let range = text.range(of: #"Bad configuration option: \S+"#, options: .regularExpression) {
            return error(.other, "ssh doesn't know the option “\(text[range].dropFirst("Bad configuration option: ".count))” "
                + "(in your ~/.ssh/config).")
        }
        if has("Could not resolve hostname") || has("Name does not resolve") || has("Name or service not known")
            || has("Temporary failure in name resolution") || has("nodename nor servname") {
            return error(.unknownHost, "Can't find an SSH host. Check its name in the SSH and Proxy tab and your network.")
        }
        if has("Connection refused") {
            return error(.refused, "An SSH host refused the connection. Check its port and that its SSH server runs.")
        }
        if has("timed out") {
            return error(.timeout, "An SSH host didn't answer in time. Check its name, its port and your network.")
        }
        if has("No route to host") || has("Network is unreachable") || has("Network is down") || has("Host is down") {
            return error(.noRoute, "An SSH host can't be reached from this network. Check Wi-Fi or VPN, or reach it "
                + "through a jump host.")
        }
        if has("Too many authentication failures") {
            return error(.authFailed, "An SSH host gave up after too many keys were offered. Choose its key file in the SSH "
                + "and Proxy tab.")
        }
        if let range = text.range(of: #"Permission denied \(([^)]*)\)"#, options: .regularExpression) {
            let methods = text[range].dropFirst("Permission denied (".count).dropLast()
            return error(.authFailed, "An SSH host didn't accept the login; it allows: "
                + methods.replacingOccurrences(of: ",", with: ", ") + ". Check the user and how it logs in, in the SSH and "
                + "Proxy tab.")
        }
        if has("Permission denied") {
            return error(.authFailed, "An SSH host didn't accept the user name or password.")
        }
        if has("cannot listen to path") || has("Could not request local forwarding") {
            return error(.other, "ssh couldn't open the route's socket on this Mac.")
        }
        if has("kex_exchange_identification") || has("Connection closed by") || has("Connection reset by")
            || has("Broken pipe") || has("client_loop:") || has("packet_write_wait") {
            return error(.disconnected, "An SSH host closed the connection. Check that it is an SSH server, and the proxy if "
                + "the route uses one.")
        }
        return error(.other, lines.last ?? "ssh ended with status \(status).")
    }
}
