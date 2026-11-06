import AirSQLCore
import AppKit
import UniformTypeIdentifiers

/// A run under way: its statements, the one running, and how to stop it.
@MainActor
final class ConsoleRun {
    enum Kind { case run, explain, analyze, profile, toFile }

    let kind: Kind
    let statements: [SQLStatement]
    /// The text the statements' ranges are in, as it was when the run started.
    let text: String
    let started = Date()
    var index = 0
    var cancelled = false
    var session: DBConnection?
    var activity: Activity?
    var timer: Timer?
    /// A statement ended in an error.
    var failed = false
    /// Run to File: where the rows go.
    var target: URL?
    /// Skip All, after an error in a script.
    var skipsErrors = false
    /// Run Again: the result tab its rows take the place of.
    let replacing: ResultTab?

    init(kind: Kind, statements: [SQLStatement], text: String, replacing: ResultTab? = nil) {
        self.kind = kind
        self.statements = statements
        self.text = text
        self.replacing = replacing
    }

    /// The person's own statements, not a Commit or a change of mode: they run in the tab's database.
    var isTheirs: Bool { replacing != nil || statements.contains { !$0.range.isEmpty } }
}

/// Running (plan §2.6): ⌘↩ the statement at the caret (or the selection), ⇧⌘↩ all, each sent alone; the statement
/// that ran is highlighted for a moment, Run's progress and time show on the results bar and in the status bar's
/// activity, and Cancel stops it through the safe KILL QUERY.
extension ConsoleViewController {
    @objc func runStatement(_ sender: Any?) { run(all: false) }

    @objc func runSelection(_ sender: Any?) {
        guard editor.selectedRange().length > 0 else { return NSSound.beep() }
        run(all: false)
    }

    @objc func runAll(_ sender: Any?) { run(all: true) }

    /// The selection as it stands, not split on `;`: a routine's body without a DELIMITER line.
    @objc func runSelectionWhole(_ sender: Any?) {
        let selection = editor.selectedRange()
        guard selection.length > 0, let range = Range(selection) else { return NSSound.beep() }
        var whole = SQLStatement(sql: (text as NSString).substring(with: selection))
        whole.range = range
        whole.end = range.upperBound
        run([whole])
    }

    /// The statement at the caret and those after it.
    @objc func runFromCaret(_ sender: Any?) {
        run(ConsoleScript.statements(from: editor.selectedRange().location, in: text, noBackslashEscapes: editor.noBackslashEscapes))
    }

    /// The smallest query in brackets around the caret, else the statement.
    @objc func runSubquery(_ sender: Any?) {
        guard let subquery = ConsoleScript.subquery(at: editor.selectedRange().location, in: text,
                                                    noBackslashEscapes: editor.noBackslashEscapes) else {
            return note(.info, "The cursor isn't in a query in brackets: put it inside a subquery.")
        }
        run([subquery])
    }

    private func run(all: Bool, kind: ConsoleRun.Kind = .run) { run(chosen(all: all), kind: kind) }

    /// What a run sends: the selection, or everything, or the statement at the caret.
    private func chosen(all: Bool) -> [SQLStatement] {
        let selection = editor.selectedRange()
        return ConsoleScript.statements(in: text, selection: selection.length > 0 ? Range(selection) : nil, caret: selection.location,
                                        all: all, noBackslashEscapes: editor.noBackslashEscapes)
    }

    private func run(_ chosen: [SQLStatement], kind: ConsoleRun.Kind = .run) {
        if kind == .run, handedToCompare() { return }
        guard !chosen.isEmpty else {
            note(.info, "There is no statement here to run: type one, or put the cursor in one.")
            return
        }
        withParameters(kind == .run ? chosen : [chosen[0]]) { [weak self] statements in
            guard let self else { return }
            let sent = kind == .explain ? [ExplainPlan.tableSQL(statements[0].sql)] : statements.map(\.sql)
            guard !ConsoleSafety.refusesOnReadOnly(sent, in: self) else { return }
            guard kind == .run else { return self.start(ConsoleRun(kind: kind, statements: statements, text: self.text)) }
            ConsoleSafety.check(statements, in: self) { [weak self] approved in
                guard approved, let self else { return }
                self.start(ConsoleRun(kind: kind, statements: statements, text: self.text))
            }
        }
    }

    /// Fills in `?` and `:name`, asking their values first; everything after this sees the final SQL.
    private func withParameters(_ statements: [SQLStatement], then run: @escaping ([SQLStatement]) -> Void) {
        noticeLostSession()
        if let lostSession { return askAboutLostSession(lostSession) }  // before any other question about statements that won't run
        // A tab's first run has no session yet: the server's sql_mode, for the values and for the checks after them.
        if let known = session?.noBackslashEscapes ?? model.openConnection(connectionID)?.snapshot.server?.noBackslashEscapes {
            editor.noBackslashEscapes = known
        }
        let noBackslashEscapes = editor.noBackslashEscapes
        let places = QueryParameters.places(in: statements.map(\.sql), noBackslashEscapes: noBackslashEscapes)
        let keys = QueryParameters.keys(places)
        guard !keys.isEmpty, let window = view.window else { return run(statements) }
        let fields = keys.enumerated().map { index, key in
            textField(parameterValues[key] ?? "", placeholder: "value", id: "parameter.\(index)",
                      tip: "Type the value for \(key): a number or NULL goes in as it is, anything else as quoted text", width: 240)
        }
        let hints = Dictionary(places.joined().map { ($0.key, $0.hint) }, uniquingKeysWith: { first, _ in first })
        let grid = NSGridView(views: zip(keys, fields).map { key, field in
            [label((hints[key] ?? nil) ?? (key.hasPrefix("?") ? "? " + key.dropFirst() : key)), field]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.layoutSubtreeIfNeeded()
        grid.frame.size = grid.fittingSize
        grid.translatesAutoresizingMaskIntoConstraints = true
        ConsoleClosing.alert(window, keys.count == 1 ? "Value for this parameter" : "Values for these parameters",
                             "They're filled in before the SQL is sent. A number or NULL goes in as it is, anything else as quoted text.",
                             buttons: [("Run", "Fill in the values and run"), ("Cancel", "Run nothing")], destructive: nil, accessory: grid) {
            [weak self] choice in
            guard choice == 0, let self else { return }
            for (key, field) in zip(keys, fields) { self.parameterValues[key] = field.stringValue }
            run(zip(statements, places).map { statement, places in
                var bound = statement
                bound.sql = QueryParameters.bind(statement.sql, places, values: self.parameterValues, noBackslashEscapes: noBackslashEscapes)
                return bound
            })
        }
    }

    @objc func explain(_ sender: Any?) { run(all: false, kind: .explain) }

    /// Explain Analyze runs the statement for real, so read-only connections refuse it whatever it is, and a write always
    /// asks first.
    @objc func explainAnalyze(_ sender: Any?) {
        guard !handedToCompare() else { return }
        guard let chosen = chosen(all: false).first else {
            return note(.info, "There is no statement here to run: type one, or put the cursor in one.")
        }
        withParameters([chosen]) { [weak self] statements in
            guard let self, let sent = ExplainPlan.analyzeSQL(statements[0].sql, server: self.session?.server)?.sql,
                  !ConsoleSafety.refusesOnReadOnly([sent], in: self) else { return }
            ConsoleSafety.check(statements, in: self, askWrites: true) { [weak self] approved in
                guard approved, let self else { return }
                self.start(ConsoleRun(kind: .analyze, statements: statements, text: self.text))
            }
        }
    }

    /// Run to File: the rows of a statement that only reads go straight to a file, without a grid, however many there are.
    @objc func runToFile(_ sender: Any?) {
        // The gate (plan §2.8): files on this Mac are the person's to write.
        guard !AgentGuard.refuses("Run to File writes a file on this Mac: only the person at the Mac can do that."),
              let chosen = chosen(all: false).first else { return }
        withParameters([chosen]) { [weak self] statements in
            guard let self, let window = self.view.window else { return }
            guard ReadOnlyClassifier.classify(statements[0].sql, noBackslashEscapes: self.editor.noBackslashEscapes) == .readOnly else {
                return self.note(.error, "Run to File takes a statement that only reads, such as a SELECT: nothing ran.", statement: statements[0])
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = ["csv", "tsv", "json"].compactMap { UTType(filenameExtension: $0) }
            panel.nameFieldStringValue = (self.tab?.title ?? "Rows") + ".csv"
            panel.message = "Write the rows to a file: .csv, .tsv or .json, by the name you give it"
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .OK, let url = panel.url else { return }
                self.writeRows(of: statements[0], to: url)
            }
        }
    }

    func writeRows(of statement: SQLStatement, to url: URL) {
        let run = ConsoleRun(kind: .toFile, statements: [statement], text: text)
        run.target = url
        start(run)
    }

    /// Run Again: the shown result's statement once more, its rows taking the tab's place. It goes through the same
    /// checks as a Run, as a statement that returns rows can still write (CALL).
    @objc func rerunResult(_ sender: Any?) {
        guard let tab = currentResult, let sql = tab.sql else { return }
        askBeforeClosing([tab]) { [weak self] close in
            guard close, let self, !ConsoleSafety.refusesOnReadOnly([sql], in: self) else { return }
            let statement = SQLStatement(sql: sql)
            ConsoleSafety.check([statement], in: self) { [weak self] approved in
                guard approved, let self else { return }
                self.start(ConsoleRun(kind: .run, statements: [statement], text: self.text, replacing: tab))
            }
        }
    }

    /// A sync script runs only through its compare.
    private func handedToCompare() -> Bool {
        guard let syncScript else { return false }
        if !syncScript() { note(.info, "The compare window that made this script is closed: compare again to run a sync script.") }
        return true
    }

    @objc func profileQuery(_ sender: Any?) {
        guard !handedToCompare(), let chosen = chosen(all: false).first else { return }
        withParameters([chosen]) { [weak self] statements in
            guard let self, !ConsoleSafety.refusesOnReadOnly(statements.map(\.sql), in: self) else { return }
            ConsoleSafety.check(statements, in: self) { [weak self] approved in
                guard approved, let self else { return }
                self.start(ConsoleRun(kind: .profile, statements: statements, text: self.text))
            }
        }
    }

    /// Runs statements that aren't in the text (Commit, Rollback, the transaction mode), shown in Messages.
    func runCommand(_ sql: [String], then done: (() -> Void)? = nil) {
        start(ConsoleRun(kind: .run, statements: sql.map { SQLStatement(sql: $0) }, text: text), then: done)
    }

    @objc func cancelQuery(_ sender: Any?) {
        guard let run = running, !run.cancelled else { return }
        run.cancelled = true
        updateRunning()
        guard let session = run.session else { return }
        Task { [weak self] in
            let result = try? await session.cancel()
            guard let self else { return }
            switch result {
            case .unsafe(let reason):
                self.note(.warning, "AirSQL couldn't stop the statement safely: \(reason) Disconnect to stop it.")
            case .notRunning where self.running === run:
                self.note(.warning, "AirSQL couldn't find the statement to stop: it may be starting or between "
                    + "statements. If it keeps going, disconnect to stop it.")
            default:
                break
            }
        }
    }

    // MARK: The run

    func start(_ run: ConsoleRun, then done: (() -> Void)? = nil) {
        guard running == nil else {
            NSSound.beep()
            return done?() ?? ()
        }
        guard let id = connectionID, let connection = Self.openConnection(id) else {
            note(.error, "Not connected: connect to “\(self.connection?.displayName ?? "the server")” first (double-click it in the "
                 + "sidebar).")
            return done?() ?? ()
        }
        guard shared.runner == nil || shared.runner == documentID else {
            note(.warning, "Another query tab is running a statement on this connection: they share one session, so this one "
                 + "waits until it ends.")
            return done?() ?? ()
        }
        noticeLostSession()
        if let lostSession {
            askAboutLostSession(lostSession)
            return done?() ?? ()
        }
        if session == nil { sharing = nil }
        if run.kind == .run, run.statements.contains(where: { !$0.range.isEmpty }) {
            dropUnpinnedResults()
            resultsRuler?.errorLine = nil
            editor.runProblem = nil
            runMarks.clear()
        }
        running = run
        changeShared { $0.runner = documentID }
        let what = run.statements.count == 1 ? "a statement" : "\(run.statements.count) statements"
        run.activity = model.activity.start("Running \(what) on \(self.connection?.displayName ?? "the server")", connection: id) {
            [weak self] in self?.cancelQuery(nil)
        }
        run.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunning() }
        }
        updateRunning()
        contentChanged()
        Task { [weak self] in
            do {
                if let session = try await self?.sessionForRun(on: connection) {
                    run.session = session
                    self?.editor.noBackslashEscapes = session.noBackslashEscapes
                    await self?.perform(run, on: session, connection: id)
                }
            } catch {
                self?.note(.error, error.localizedDescription)
            }
            self?.finish(run)
            done?()
        }
    }

    private func perform(_ run: ConsoleRun, on session: DBConnection, connection id: UUID) async {
        guard !run.cancelled else { return }  // Cancel while the session opened had no statement to stop
        // The database chosen in the navigator or the toolbar since the session's last USE: used first, so the statements
        // run where the tab says (and a run under way is never switched midway). If it fails, nothing runs.
        let wanted = (sharesSession ? nil : chosenDatabase) ?? model.openConnection(id)?.currentDatabase
        if run.isTheirs, !sharesSession { chosenDatabase = wanted }
        if run.isTheirs, let wanted, wanted != shared.database ?? session.options.database {
            let use = await ConsoleRunner.run(SQLStatement(sql: "USE " + SQLQuote.identifier(wanted)), in: run.text, on: session)
            show(use, title: nil, run: run, session: session)
            guard use.error == nil else { return }
        }
        if run.kind == .explain { return await explain(run, on: session) }
        if run.kind == .analyze { return await analyze(run, on: session, connection: id) }
        if run.kind == .toFile { return await writeRows(run, on: session) }
        let profile = run.kind == .profile ? await QueryProfile.start(on: session) : nil
        let all = SQLSplitter.statements(in: run.text, noBackslashEscapes: session.noBackslashEscapes)
        var schemaChanged = false
        defer { if schemaChanged { model.openConnection(id)?.load() } }  // the navigator's tree shows the change
        var index = -1
        while index + 1 < run.statements.count {
            index += 1
            let statement = run.statements[index]
            guard !run.cancelled else { break }
            run.index = index
            updateRunning()
            if !statement.range.isEmpty, text == run.text { editor.flash(NSRange(statement.range)) }
            let outcome = await ConsoleRunner.run(statement, in: run.text, on: session, rowCap: Self.rowCap(), timeout: Self.queryTimeout(id))
            let previous = all.last { $0.end <= statement.range.lowerBound }?.end ?? 0
            let title = statement.range.isEmpty ? nil
                : ConsoleScript.title(of: statement, in: run.text, after: previous, noBackslashEscapes: session.noBackslashEscapes)
            show(outcome, title: title, run: run, session: session)
            if outcome.error == nil, Self.changesSchema(statement.sql) { schemaChanged = true }
            let names = SQLNameCheck.changedNames(in: statement.sql), code = SQLNameCheck.runsCode(statement.sql)
            if !names.isEmpty || code {
                changeShared {
                    $0.changedNames.formUnion(names)
                    $0.ranCode = $0.ranCode || code
                }
            }
            if outcome.error != nil, !run.cancelled, index + 1 < run.statements.count {
                let answer = await scriptAnswer(after: outcome, run: run)
                if answer == .retry { index -= 1 }
                if answer != .stop { continue }
            }
            if outcome.error != nil || run.cancelled {
                let left = run.statements.count - index - 1
                if left > 0 { note(.info, "Stopped: the \(left) statement\(left == 1 ? "" : "s") after it didn't run.") }
                break
            }
        }
        if let profile {
            let (rows, text) = await profile.read(on: session)
            if let rows { addResult(rows, title: "Profile", summary: "Where the server spent the time") }
            if let text { note(.info, text) }
        }
    }

    private enum ScriptAnswer { case stop, retry, skip }

    /// A script's statement failed with others to come: Retry sends it again, Skip goes on past it, Skip All past every error
    /// from here on, Stop ends the run, as it always has where nobody can answer.
    private func scriptAnswer(after outcome: ConsoleOutcome, run: ConsoleRun) async -> ScriptAnswer {
        if run.skipsErrors { return .skip }
        guard let window = view.window, window.attachedSheet == nil else { return .stop }
        return await withCheckedContinuation { continuation in
            ConsoleClosing.alert(window, "A statement failed: go on with the rest?", outcome.error?.localizedDescription ?? "",
                                 buttons: [("Stop", "End the run here"), ("Retry", "Send this statement again"),
                                           ("Skip", "Leave this statement and run the next"),
                                           ("Skip All", "Run the rest, leaving any that fail")], destructive: nil) { choice in
                if choice == 3 { run.skipsErrors = true }
                continuation.resume(returning: choice == 0 ? .stop : choice == 1 ? .retry : .skip)
            }
        }
    }

    /// Whether `sql` changes the schema: CREATE, ALTER, DROP or RENAME.
    static func changesSchema(_ sql: String) -> Bool {
        let text = Array(sql.utf16)
        guard let word = SQLLexer.tokens(sql).first(where: { $0.kind == .word }) else { return false }
        let keyword = String(utf16CodeUnits: Array(text[word.range]), count: word.range.count).uppercased()
        return ["CREATE", "ALTER", "DROP", "RENAME"].contains(keyword)
    }

    /// A statement of AirSQL's own around the person's (the plan's tree), its errors kept quiet.
    private func runQuery(_ sql: String, on session: DBConnection) async -> [StatementResult]? {
        try? await session.query(sql, rowCap: 10_000)
    }

    private func explain(_ run: ConsoleRun, on session: DBConnection) async {
        let statement = run.statements[0]
        if text == run.text { editor.flash(NSRange(statement.range)) }
        let table = await ConsoleRunner.run(SQLStatement(sql: ExplainPlan.tableSQL(statement.sql, server: session.server)), in: run.text, on: session)
        if let error = table.error { return planFailed(error, run: run, session: session) }
        let (sql, json) = ExplainPlan.treeSQL(statement.sql, server: session.server)
        let tree = (await runQuery(sql, on: session))?.first?.rows.flatMap { $0.rowCount > 0 ? $0.string(0, 0) : nil } ?? ""
        addPlan(table: table.results.first?.rows, tree: json ? ExplainPlan.tree(fromJSON: tree) : tree,
                nodes: ExplainPlan.nodes(from: tree, json: json), raw: tree, title: "Plan")
        note(.ok, "Plan shown · \(milliseconds(table.duration))", statement: statement, run: run)
    }

    private func analyze(_ run: ConsoleRun, on session: DBConnection, connection id: UUID) async {
        let statement = run.statements[0]
        guard let (sql, json) = ExplainPlan.analyzeSQL(statement.sql, server: session.server) else {
            return note(.info, "Explain Analyze needs MySQL 8.0.18 or later, or MariaDB: nothing ran.")
        }
        if text == run.text { editor.flash(NSRange(statement.range)) }
        let outcome = await ConsoleRunner.run(SQLStatement(sql: sql), in: run.text, on: session, rowCap: Self.rowCap(), timeout: Self.queryTimeout(id))
        if let error = outcome.error { return planFailed(error, run: run, session: session) }
        let plan = outcome.results.first?.rows.flatMap { $0.rowCount > 0 ? $0.string(0, 0) : nil } ?? ""
        addPlan(table: nil, tree: json ? ExplainPlan.tree(fromJSON: plan) : plan, nodes: ExplainPlan.nodes(from: plan, json: json),
                raw: plan, title: "Plan (Analyzed)")
        note(.ok, "Ran and analyzed · \(milliseconds(outcome.duration))", statement: statement, run: run)
    }

    private func writeRows(_ run: ConsoleRun, on session: DBConnection) async {
        guard let url = run.target else { return }
        let statement = run.statements[0], started = Date(), writer = RowFileWriter(url)
        do {
            try await session.stream(statement.sql, batchRows: 10_000) { try writer.write($0) }
            try writer.finish()
            let rows = writer.rows
            note(.ok, "\(rows.formatted()) row\(rows == 1 ? "" : "s") written to \(url.lastPathComponent) · \(milliseconds(Date().timeIntervalSince(started)))",
                 statement: statement, run: run)
        } catch {
            writer.close()
            run.failed = true
            note(.error, "Not every row reached \(url.lastPathComponent): \(error.localizedDescription)", statement: statement, run: run)
        }
    }

    private func planFailed(_ error: AirSQLError, run: ConsoleRun, session: DBConnection) {
        let statement = run.statements[0], shown = error.localizedDescription
        run.failed = true
        note(.error, shown, statement: statement, run: run)
        if text == run.text {
            editor.runProblem = ConsoleScript.problem(error.details.isEmpty ? error.message : error.details, shown: shown,
                                                      statement: statement, noBackslashEscapes: session.noBackslashEscapes)
        }
    }

    private func finish(_ run: ConsoleRun) {
        defer { noticeLostSession() }
        run.timer?.invalidate()
        run.activity?.end()
        if running === run { running = nil }
        if run.failed, run.replacing != nil { setAutoRefresh(nil) }
        if shared.runner == documentID { changeShared { $0.runner = nil } }
        LongQueryNotice.runEnded(after: Date().timeIntervalSince(run.started), failed: run.failed,
                                 place: "“\(tab?.title ?? "Query")” on \(connection?.displayName ?? "the server")")
        results.setRunning(nil)
        showResults()
        contentChanged()
    }

    /// The results bar while running: which statement, and the time so far.
    func updateRunning() {
        guard let run = running else { return }
        let seconds = Date().timeIntervalSince(run.started)
        let step = run.statements.count > 1 ? "Running statement \(run.index + 1) of \(run.statements.count)" : "Running"
        results.setRunning(run.cancelled ? "Cancelling…" : step + " · " + String(format: "%.1f s", seconds))
        run.activity?.detail = run.statements.count > 1 ? "Statement \(run.index + 1) of \(run.statements.count)" : nil
        run.activity?.progress = run.statements.count > 1 ? Double(run.index) / Double(run.statements.count) : nil
    }

    func milliseconds(_ duration: TimeInterval) -> String {
        duration < 1 ? "\(Int((duration * 1000).rounded())) ms" : String(format: "%.2f s", duration)
    }
}
