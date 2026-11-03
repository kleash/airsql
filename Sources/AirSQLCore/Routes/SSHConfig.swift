import Foundation

/// The ssh_config AirSQL writes for one connection's SSH route (plan §2.3): a Host block per hop (named as the hop's
/// host is typed, so a Host of ~/.ssh/config still gets its own settings from there), each reached through the one
/// before it (ProxyJump), the first through the proxy relay when there is one; then the tunnel's own settings for every
/// hop, then the person's ~/.ssh/config for whatever these leave open (ssh takes the first value it finds).
public enum SSHConfig {
    /// The person's own config, included last; a throwaway instance's `$AIRSQL_SSH_DIR/config` instead, which keeps its
    /// ssh away from the real ~/.ssh (testenv/AGENT.md). Tests point it at a config of theirs.
    public static var include: String? = Env.value("SSH_DIR").flatMap { $0.isEmpty ? nil : $0 + "/config" } ?? "~/.ssh/config"

    /// The file's text. `proxySocket`: the relay to the first hop (SSH + proxy).
    public static func text(for connection: SavedConnection, proxySocket: String? = nil) -> String {
        let hops = connection.sshHops
        var lines = ["# Made by AirSQL for the connection \(oneLine(connection.displayName)) at each connect. Changes are lost.", ""]
        for (index, hop) in hops.enumerated() {
            lines.append("Host " + value(hop.host))
            if let port = hop.port { lines.append("  Port \(port)") }
            if !hop.user.isEmpty { lines.append("  User " + value(hop.user)) }
            switch hop.login {
            case .keyFile where !hop.keyFile.isEmpty:
                lines.append("  IdentityFile " + value(hop.keyFile.replacingOccurrences(of: "%", with: "%%")))
                lines.append("  IdentitiesOnly yes")
            case .password:
                // Straight to the password: no agent keys or key passphrases first.
                lines.append("  PreferredAuthentications keyboard-interactive,password")
            default:
                break
            }
            if index > 0 {
                lines.append("  ProxyJump " + value(hops[index - 1].host))
            } else if let proxySocket {
                lines.append("  ProxyCommand /usr/bin/nc -U " + value(proxySocket.replacingOccurrences(of: "%", with: "%%")))
            } else {
                // 15 s to reach the first hop directly. The hops behind it (and a first hop behind the relay, which
                // has its own) get no timeout: it would also run while the person answers the first hop's
                // questions, its host key and password (as in AirSCP).
                lines.append("  ConnectTimeout 15")
            }
        }
        lines += ["", "Host *",
                  // The tunnel is this ssh alone: never a connection shared with another ssh.
                  "  ControlMaster no", "  ControlPath none",
                  // A socket it can't make ends it (ExitOnForwardFailure); one left by an earlier ssh is replaced.
                  "  ExitOnForwardFailure yes", "  StreamLocalBindUnlink yes", "  StreamLocalBindMask 0177",
                  // A dead network is noticed within a minute.
                  "  ServerAliveInterval 15", "  ServerAliveCountMax 3",
                  // "Authenticated to <hop>" lines: the connect's progress, hop by hop.
                  "  LogLevel VERBOSE",
                  "  BatchMode no", "  PermitLocalCommand no"]
        if let include { lines.append("Include " + value(include)) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A value as ssh_config reads it: in double quotes when it has a space (ssh_config has no way to write a quote).
    static func value(_ text: String) -> String {
        text.contains(where: { $0.isWhitespace }) ? "\"" + text + "\"" : text
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    /// Why `connection`'s SSH settings can't make a config, in words for the editor and the connect; nil when they can.
    public static func problem(with connection: SavedConnection) -> String? {
        let hops = connection.sshHops
        if connection.route == .sshJump && connection.jumpHosts.isEmpty {
            return "Add a jump host in the SSH and Proxy tab, or choose the route SSH tunnel."
        }
        for hop in hops {
            let name = hop.id == connection.sshHost.id ? "the SSH host" : "a jump host"
            if hop.host.trimmingCharacters(in: .whitespaces).isEmpty { return "Type the name of \(name) in the SSH and Proxy tab." }
            for text in [hop.host, hop.user]
            where text.hasPrefix("-") || text.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "#" || $0 == "," }) {
                return "The host or user name of \(name) can't start with - or contain spaces, quotes, commas or #."
            }
            if hop.login == .keyFile && hop.keyFile.isEmpty { return "Choose the key file of \(name), or log in another way." }
            if hop.keyFile.contains("\"") { return "The key file of \(name) has a quote in its path, which ssh can't read." }
        }
        if Set(hops.map(\.host)).count < hops.count {
            return "Two hops of this route have the same host name; each hop needs a name of its own."
        }
        return nil
    }
}
