/// A request the person hands to their agent from the editor. It names the tab and lines and holds no SQL: the agent
/// reads them with read_console, through the gate, at the access the connection allows and with passwords masked, so a
/// prompt can't widen what the agent may do.
public enum AgentRequest: Int, CaseIterable {
    case explain, fix, optimise, write

    private var job: String {
        switch self {
        case .explain: return "Explain what the SQL does, in plain words."
        case .fix: return "Say why the last statement run there failed, and how to fix it."
        case .optimise: return "Suggest how to make the SQL faster: indexes, or a rewrite. Use the schema and EXPLAIN."
        case .write: return "Write the SQL for this request:"
        }
    }

    /// What to paste into the agent. `lines`: the lines meant, from 1; `wish`: what the person typed.
    public func prompt(tab: String, title: String, connection: String, lines: ClosedRange<Int>?, wish: String? = nil) -> String {
        let place = lines.map { $0.count == 1 ? " at line \($0.lowerBound)" : " at lines \($0.lowerBound) to \($0.upperBound)" } ?? ""
        var parts = ["In AirSQL, use read_console with tab \(tab) (“\(title)” on “\(connection)”) and look\(place).", job]
        if let wish { parts.append(wish) }
        parts.append("Propose any SQL with open_in_console: I read it and run it myself.")
        return parts.joined(separator: " ")
    }
}
