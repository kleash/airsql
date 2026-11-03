import Foundation

/// Adds AirSQL's MCP server to Claude Code (user scope, `~/.claude.json`) or Gemini CLI (`~/.gemini/settings.json`):
/// `plan` says exactly what changes, and only `apply` writes, after the person has seen it. The old file is kept next to
/// it as `<name>.airsql-backup`. File work: call both off the main thread.
public enum AgentSetup {
    public enum Client: String, CaseIterable {
        case claudeCode, geminiCLI

        public var title: String { self == .claudeCode ? "Claude Code" : "Gemini CLI" }

        public func file(home: URL) -> URL {
            self == .claudeCode ? home.appendingPathComponent(".claude.json")
                : home.appendingPathComponent(".gemini/settings.json")
        }

        /// The same in the client's own command line.
        public func command(program: String, supportDir: String?) -> String {
            let env = supportDir.map { "-e AIRSQL_SUPPORT_DIR=" + AgentSetup.shellWord($0) + " " } ?? ""
            return self == .claudeCode ? "claude mcp add --scope user " + env + "airsql -- " + AgentSetup.shellWord(program) + " --mcp"
                : "gemini mcp add --scope user " + env + "airsql " + AgentSetup.shellWord(program) + " --mcp"
        }
    }

    /// What `apply` would do: the file, AirSQL's entry before (nil: none) and after, and the file's new content.
    public struct Change {
        public let client: Client
        public let file: URL
        public let before: String?
        public let after: String
        let content: Data
        /// The entry is already there as it would be.
        public var unchanged: Bool { before == after }
    }

    /// The entry under `mcpServers.airsql`: this program with --mcp, and the settings folder of a throwaway instance.
    static func entry(_ client: Client, program: String, supportDir: String?) -> [String: Any] {
        var entry: [String: Any] = ["command": program, "args": ["--mcp"]]
        if client == .claudeCode { entry["type"] = "stdio" }
        if let supportDir { entry["env"] = ["AIRSQL_SUPPORT_DIR": supportDir] }
        return entry
    }

    public static func plan(_ client: Client, home: URL, program: String, supportDir: String?) throws -> Change {
        let file = client.file(home: home)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AirSQLError(.other, "\(file.lastPathComponent) isn't plain JSON, so AirSQL leaves it alone. Run this "
                                  + "instead: " + client.command(program: program, supportDir: supportDir))
            }
            root = object
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        let before = servers["airsql"].map(pretty)
        let entry = entry(client, program: program, supportDir: supportDir)
        servers["airsql"] = entry
        root["mcpServers"] = servers
        let content = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return Change(client: client, file: file, before: before, after: pretty(entry), content: content)
    }

    /// Writes the change, keeping the old file as a backup and its permissions (a new file only this user can read).
    public static func apply(_ change: Change) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: change.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? manager.attributesOfItem(atPath: change.file.path))?[.posixPermissions] as? Int
        if permissions != nil {
            let backup = change.file.appendingPathExtension("airsql-backup")
            try? manager.removeItem(at: backup)
            try manager.copyItem(at: change.file, to: backup)
        }
        try change.content.write(to: change.file, options: .atomic)
        try manager.setAttributes([.posixPermissions: permissions ?? 0o600], ofItemAtPath: change.file.path)
    }

    static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys,
                                                                                     .withoutEscapingSlashes])
        else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }

    /// A word for the shell: as it is when it is plain, else in single quotes.
    static func shellWord(_ text: String) -> String {
        let plain = !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+=:@%".contains($0)) }
        return plain ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
