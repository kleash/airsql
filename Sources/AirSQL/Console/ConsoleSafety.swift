import AirSQLCore
import AppKit

/// The safety settings' prompts before a console run (plan §2.10), on the SQL preview sheet: an UPDATE or DELETE without
/// WHERE, DROP and TRUNCATE (dropping a database needs its name typed, and a table's too where the connection says so),
/// and any write where every write asks (the Production preset). Nothing runs until the person says Run.
@MainActor
enum ConsoleSafety {
    /// Calls `answer` with true when the statements may run: at once when nothing needs asking, else after the sheet.
    /// `askWrites`: any write asks, wherever (a command whose name doesn't say it changes data).
    static func check(_ statements: [SQLStatement], in console: ConsoleViewController, askWrites: Bool = false,
                      answer: @escaping (Bool) -> Void) {
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
                warnings.append("\(risk.verb) without WHERE \(verb) " + (risk.limited ? "whichever rows of \(risk.object) come first, "
                                + "up to its LIMIT." : "every row of \(risk.object)."))
                let reach = risk.limited ? "rows" : "every row"
                heading = heading ?? (risk.verb == "DELETE" ? "Delete \(reach) of \(risk.object)?" : "Change \(reach) of \(risk.object)?")
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
        guard !warnings.isEmpty || (writes && (safety.askBeforeConsoleWrite || askWrites)) || agent else { return answer(true) }
        let count = statements.count, no = AgentGate.agent == nil ? "cancel" : "decline"
        let change = ChangeSQL(title: "Console", statements: statements.map(\.sql), connection: saved.id)
        var request = SQLPreviewRequest(
            change: change,
            heading: heading ?? "Run \(count == 1 ? "this statement" : "\(count) statements") on \(saved.displayName)?",
            caption: count == 1 ? "It may change data or structure on the server. Check it, then run it or \(no)."
                : "They run one after another, and stop at the first error. Check them, then run them or \(no).")
        request.actionTitle = "Run"
        request.destructive = destructive
        request.warnings = warnings
        request.typeToConfirm = typed
        request.noBackslashEscapes = noBackslashEscapes
        SQLPreviewSheet.show(request, connection: saved, on: window) { result in answer(result.approved) }
    }

    /// On a read-only connection, says in Messages why the statements don't run unless each one is proven read-only.
    static func refusesOnReadOnly(_ statements: [String], in console: ConsoleViewController) -> Bool {
        guard let saved = console.connection, saved.readOnly else { return false }
        for sql in statements {
            if let refusal = StatementCheck.readOnlyRefusal(sql, on: saved.displayName,
                                                            noBackslashEscapes: console.editor.noBackslashEscapes) {
                console.note(.error, refusal, statement: SQLStatement(sql: sql))
                return true
            }
        }
        return false
    }

    /// Names as the person types them: each one without its backticks (`shop`.`my orders`, `a.b` → shop.my orders, a.b).
    static func unquoted(_ names: String) -> String {
        let text = Array(names.utf16)
        var result = "", end = 0
        for token in SQLLexer.tokens(names) where token.kind == .quotedName {
            result += String(decoding: text[end..<token.range.lowerBound], as: UTF16.self)
                + SQLQuote.unquoted(String(decoding: text[token.range], as: UTF16.self))
            end = token.range.upperBound
        }
        return result + String(decoding: text[end...], as: UTF16.self)
    }
}
