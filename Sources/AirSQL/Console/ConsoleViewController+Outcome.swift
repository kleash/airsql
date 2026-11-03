import AirSQLCore
import AppKit

/// What a statement's outcome becomes: result tabs, lines in Messages (rows, rows affected, time, warnings, or the
/// error at its line), an entry in the connection's history, the transaction's count of changes and the database a
/// USE made current.
extension ConsoleViewController {
    func show(_ outcome: ConsoleOutcome, title: String?, run: ConsoleRun, session: DBConnection) {
        let statement = outcome.statement
        let time = milliseconds(outcome.duration)
        if let error = outcome.error {
            var text = run.cancelled && error.kind == .cancelled ? "Cancelled · \(time)" : error.message
            if !error.details.isEmpty, error.kind != .cancelled { text += " " + error.details }
            note(.error, text, statement: statement, run: run, line: outcome.errorLine)
            if let line = outcome.errorLine, self.text == run.text { resultsRuler?.errorLine = line }
        } else if run.cancelled {
            note(.warning, "Cancelled · \(time): what came back may be cut short", statement: statement, run: run)
        }
        let writes = StatementCheck.writes(statement.sql, noBackslashEscapes: session.noBackslashEscapes)
        var number = 0
        for result in outcome.results {
            if let rows = result.rows {
                number += 1
                let count = "\(rows.rowCount.formatted()) row\(rows.rowCount == 1 ? "" : "s")"
                let summary = time + " · " + count + (rows.capped ? " (the first \(rows.rowCount.formatted()))" : "")
                if outcome.error == nil { note(.ok, count + (rows.capped ? ", the first only" : "") + " · " + time, statement: statement, run: run) }
                addResult(rows, title: title.map { number > 1 ? "\($0) (\(number))" : $0 }, summary: summary)
            } else if outcome.error == nil {
                let affected = result.affectedRows
                let text = writes ? "\(affected.formatted()) row\(affected == 1 ? "" : "s") affected" : "Done"
                note(.ok, text + " · " + time + (result.info.map { " · " + $0 } ?? ""), statement: statement, run: run)
            }
        }
        for warning in outcome.warnings { note(.warning, warning, statement: statement, run: run) }
        if outcome.error == nil, outcome.results.isEmpty, !run.cancelled { note(.ok, "Done · " + time, statement: statement, run: run) }

        // The transaction's changes, the current database.
        let changed = outcome.results.reduce(UInt64(0)) { $0 + $1.affectedRows }
        let database = outcome.error == nil ? StatementCheck.usedDatabase(statement.sql) : nil
        changeShared { shared in
            shared.changes = session.inTransaction ? shared.changes + (writes ? changed : 0) : 0
            if let database { shared.database = database }
        }
        if !statement.range.isEmpty, let id = connectionID {
            let rows = outcome.results.compactMap(\.rows).first?.rowCount
            QueryHistory.shared.add(HistoryEntry(sql: statement.sql, connection: id, database: shared.database,
                                                 duration: outcome.duration, rows: rows, error: outcome.error?.message),
                                    noBackslashEscapes: session.noBackslashEscapes)
        }
        showResults()
    }

    /// A line in Messages, about `statement` when given; the Messages tab comes forward for errors and notes.
    func note(_ level: ConsoleMessage.Level, _ text: String, statement: SQLStatement? = nil, run: ConsoleRun? = nil,
              line: Int? = nil) {
        var range: NSRange?, first: Int?
        if let statement, !statement.range.isEmpty, let run {
            range = NSRange(statement.range)
            first = line ?? ConsoleScript.line(of: statement.range.lowerBound, in: run.text)
        }
        let sql = statement?.sql.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        messagesView.append(ConsoleMessage(level: level, range: range, line: first, statement: sql, text: text))
        if level == .error || level == .info || (level == .warning && statement == nil) || resultTabs.isEmpty {
            selectedResult = messagesTab
        }
        showResults()
    }
}
