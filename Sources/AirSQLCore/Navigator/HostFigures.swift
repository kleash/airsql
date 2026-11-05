import Foundation

/// The host page's figures (scope "server"): variables side by side, status counters per hour and second, and what
/// each kind of statement adds up to.
public enum HostFigures {
    public static let sessionVariables = "SHOW SESSION VARIABLES"
    public static let globalVariables = "SHOW GLOBAL VARIABLES"
    public static let status = "SHOW GLOBAL STATUS"

    public struct Variable: Hashable {
        public var name: String
        public var session: String?
        public var global: String?
        /// Set for this session alone: its value isn't the server's.
        public var differs: Bool { session != nil && global != nil && session != global }
    }

    /// The two lists as one, by name. A variable with one scope only has nil in the other.
    public static func variables(session: [[String?]], global: [[String?]]) -> [Variable] {
        var found: [String: Variable] = [:]
        for row in session where row.count >= 2 {
            if let name = row[0] { found[name] = Variable(name: name, session: row[1] ?? "", global: nil) }
        }
        for row in global where row.count >= 2 {
            if let name = row[0] { found[name, default: Variable(name: name, session: nil, global: nil)].global = row[1] ?? "" }
        }
        return found.values.sorted { $0.name < $1.name }
    }

    public struct Counter: Hashable {
        public var name: String
        public var value: String
        /// The value as a number, when it is one.
        public var number: Double?
        public var perHour: Double?
        public var perSecond: Double?
    }

    /// `SHOW GLOBAL STATUS`'s rows with their rates since the server started. A counter's rate is meaningless for a
    /// figure that isn't one (Threads_running), but only the person can tell which those are.
    public static func counters(_ rows: [[String?]]) -> [Counter] {
        let pairs = rows.compactMap { row -> (String, String)? in
            guard row.count >= 2, let name = row[0] else { return nil }
            return (name, row[1] ?? "")
        }
        let uptime = pairs.first { $0.0 == "Uptime" }.flatMap { Double($0.1) } ?? 0
        return pairs.map { name, value in
            let number = Double(value)
            let rated = uptime > 0 ? number : nil
            return Counter(name: name, value: value, number: number, perHour: rated.map { $0 / uptime * 3600 },
                           perSecond: rated.map { $0 / uptime })
        }
    }

    public struct Command: Hashable {
        /// As a person reads it: "alter_table" for `Com_alter_table`.
        public var name: String
        public var count: Double
        public var perHour: Double?
        public var perSecond: Double?
        /// Of all the statements counted, 0…1.
        public var share: Double
    }

    /// The `Com_` counters that have counted something, largest first.
    public static func commands(_ counters: [Counter]) -> [Command] {
        let used = counters.filter { $0.name.lowercased().hasPrefix("com_") && ($0.number ?? 0) > 0 }
        let all = used.reduce(0) { $0 + ($1.number ?? 0) }
        return used.map { counter in
            Command(name: String(counter.name.dropFirst(4)), count: counter.number ?? 0, perHour: counter.perHour,
                    perSecond: counter.perSecond, share: (counter.number ?? 0) / all)
        }.sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// `SET GLOBAL` or `SET SESSION` for `value`, as typed: a number and DEFAULT go bare, as numeric variables need,
    /// anything else as a string, which ON, OFF and an enum's names work as too.
    public static func setVariable(_ name: String, to value: String, global: Bool, noBackslashEscapes: Bool) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = text.uppercased() == "DEFAULT" || text.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil
        return "SET \(global ? "GLOBAL" : "SESSION") \(SQLQuote.identifier(name)) = "
            + (bare ? text : SQLQuote.string(text, noBackslashEscapes: noBackslashEscapes))
    }
}

extension HostFigures {
    /// Rows as CSV, for Copy List and Export List.
    public static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(AgentFormat.csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
