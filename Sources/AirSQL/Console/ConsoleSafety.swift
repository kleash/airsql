import AirSQLCore
import AppKit

/// The safety settings' prompts before a console run (plan §2.10), on the SQL preview sheet: an UPDATE or DELETE without
/// WHERE, DROP and TRUNCATE (dropping a database needs its name typed, and a table's too where the connection says so),
/// and any write where every write asks (the Production preset). Nothing runs until the person says Run.
@MainActor
enum ConsoleSafety {
    /// Calls `answer` with true when the statements may run: at once when nothing needs asking, else after the sheet.
    static func check(_ statements: [SQLStatement], in console: ConsoleViewController, answer: @escaping (Bool) -> Void) {
        guard let saved = console.connection, let window = console.view.window else { return answer(true) }
        let safety = console.model.data.safety(for: saved)
        let noBackslashEscapes = console.editor.noBackslashEscapes
        var warnings: [String] = [], typed: String?, destructive = false, heading: String?
        var writes = false
        for statement in statements {
            writes = writes || StatementCheck.writes(statement.sql, noBackslashEscapes: noBackslashEscapes)
            guard let risk = StatementCheck.risk(statement.sql, noBackslashEscapes: noBackslashEscapes) else { continue }
            switch risk.kind {
            case .unboundedWrite where safety.askBeforeUnboundedWrite:
                let verb = risk.verb == "DELETE" ? "deletes" : "changes"
                warnings.append("\(risk.verb) without WHERE \(verb) every row of \(risk.object).")
                heading = heading ?? (risk.verb == "DELETE" ? "Delete every row of \(risk.object)?" : "Change every row of \(risk.object)?")
                destructive = true
            case .drop where safety.askBeforeDrop || risk.objectType == "database" || risk.objectType == "schema":
                warnings.append("DROP \(risk.objectType.uppercased()) removes \(risk.object) for good.")
                heading = heading ?? "Drop \(risk.objectType) \(risk.object)?"
                destructive = true
                if ["database", "schema"].contains(risk.objectType) || (risk.objectType == "table" && safety.typeNameForTables) {
                    typed = typed ?? unquoted(risk.object)
                }
            case .truncate where safety.askBeforeDrop:
                warnings.append("TRUNCATE empties \(risk.object): every row goes, and it can't be rolled back.")
                heading = heading ?? "Empty \(risk.object)?"
                destructive = true
                if safety.typeNameForTables { typed = typed ?? unquoted(risk.object) }
            default:
                break
            }
        }
        // What an agent set off asks unless every statement is proven read-only (the agents' gate, plan §2.8).
        let agent = AgentGate.agent != nil && safety.askBeforeAgentChanges
            && statements.contains { !AgentGate.isReadOnly($0.sql, noBackslashEscapes: noBackslashEscapes) }
        guard !warnings.isEmpty || (writes && safety.askBeforeConsoleWrite) || agent else { return answer(true) }
        let count = statements.count
        let change = ChangeSQL(title: "Console", statements: statements.map(\.sql), connection: saved.id)
        var request = SQLPreviewRequest(
            change: change,
            heading: heading ?? "Run \(count == 1 ? "this statement" : "\(count) statements") on \(saved.displayName)?",
            caption: count == 1 ? "It may change data or structure on the server. Check it, then run it or cancel."
                : "They run one after another, and stop at the first error. Check them, then run them or cancel.")
        request.actionTitle = "Run"
        request.destructive = destructive
        request.warnings = warnings
        request.typeToConfirm = typed
        request.noBackslashEscapes = noBackslashEscapes
        SQLPreviewSheet.show(request, connection: saved, on: window) { result in answer(result.approved) }
    }

    /// A name as the person types it: `my db` without its backticks.
    static func unquoted(_ name: String) -> String {
        name.split(separator: ".").map { part -> String in
            var text = String(part)
            if text.hasPrefix("`"), text.hasSuffix("`"), text.count >= 2 {
                text = String(text.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
            }
            return text
        }.joined(separator: ".")
    }
}
