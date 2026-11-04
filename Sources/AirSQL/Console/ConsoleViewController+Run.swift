import AirSQLCore
import AppKit

/// A run under way: its statements, the one running, and how to stop it.
@MainActor
final class ConsoleRun {
    enum Kind { case run, explain, profile }

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

    init(kind: Kind, statements: [SQLStatement], text: String) {
        self.kind = kind
        self.statements = statements
        self.text = text
    }
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

    private func run(all: Bool, kind: ConsoleRun.Kind = .run) {
        if kind == .run, handedToCompare() { return }
        let selection = editor.selectedRange()
        let statements = ConsoleScript.statements(in: text, selection: selection.length > 0 ? Range(selection) : nil,
                                                  caret: selection.location, all: all,
                                                  noBackslashEscapes: editor.noBackslashEscapes)
        guard !statements.isEmpty else {
            note(.info, "There is no statement here to run: type one, or put the cursor in one.")
            return
        }
        let sent = kind == .explain ? [ExplainPlan.tableSQL(statements[0].sql)] : statements.map(\.sql)
        guard !ConsoleSafety.refusesOnReadOnly(sent, in: self) else { return }
        guard kind == .run else { return start(ConsoleRun(kind: kind, statements: [statements[0]], text: text)) }
        ConsoleSafety.check(statements, in: self) { [weak self] approved in
            guard approved, let self else { return }
            self.start(ConsoleRun(kind: kind, statements: statements, text: self.text))
        }
    }

    @objc func explain(_ sender: Any?) { run(all: false, kind: .explain) }

    /// A sync script runs only through its compare.
    private func handedToCompare() -> Bool {
        guard let syncScript else { return false }
        if !syncScript() { note(.info, "The compare window that made this script is closed: compare again to run a sync script.") }
        return true
    }

    @objc func profileQuery(_ sender: Any?) {
        guard !handedToCompare() else { return }
        let selection = editor.selectedRange()
        guard let statement = ConsoleScript.statements(in: text, selection: selection.length > 0 ? Range(selection) : nil,
                                                       caret: selection.location, all: false,
                                                       noBackslashEscapes: editor.noBackslashEscapes).first,
              !ConsoleSafety.refusesOnReadOnly([statement.sql], in: self) else { return }
        ConsoleSafety.check([statement], in: self) { [weak self] approved in
            guard approved, let self else { return }
            self.start(ConsoleRun(kind: .profile, statements: [statement], text: self.text))
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
        if run.kind == .run, run.statements.contains(where: { !$0.range.isEmpty }) {
            dropUnpinnedResults()
            resultsRuler?.errorLine = nil
            editor.runProblem = nil
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
                let session = try await connection.session(.main)
                run.session = session
                self?.changeShared { $0.session = session }
                self?.editor.noBackslashEscapes = session.noBackslashEscapes
                await self?.perform(run, on: session, connection: id)
            } catch {
                self?.note(.error, error.localizedDescription)
            }
            self?.finish(run)
            done?()
        }
    }

    private func perform(_ run: ConsoleRun, on session: DBConnection, connection id: UUID) async {
        // The database made current in the navigator or the toolbar since the session's last USE: used first, so the
        // statements run where the window says (and a run under way is never switched midway). If it fails, nothing runs.
        if run.statements.contains(where: { !$0.range.isEmpty }), let wanted = model.openConnection(id)?.currentDatabase,
           wanted != shared.database ?? session.options.database {
            let use = await ConsoleRunner.run(SQLStatement(sql: "USE " + SQLQuote.identifier(wanted)), in: run.text, on: session)
            show(use, title: nil, run: run, session: session)
            guard use.error == nil else { return }
        }
        if run.kind == .explain { return await explain(run, on: session) }
        let profile = run.kind == .profile ? await QueryProfile.start(on: session) : nil
        let all = SQLSplitter.statements(in: run.text, noBackslashEscapes: session.noBackslashEscapes)
        var schemaChanged = false
        defer { if schemaChanged { model.openConnection(id)?.load() } }  // the navigator's tree shows the change
        for (index, statement) in run.statements.enumerated() {
            guard !run.cancelled else { break }
            run.index = index
            updateRunning()
            if !statement.range.isEmpty, text == run.text { editor.flash(NSRange(statement.range)) }
            let outcome = await ConsoleRunner.run(statement, in: run.text, on: session, timeout: Self.queryTimeout(id))
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
        let table = await ConsoleRunner.run(SQLStatement(sql: ExplainPlan.tableSQL(statement.sql)), in: run.text, on: session)
        if let error = table.error {
            let shown = error.localizedDescription
            note(.error, shown, statement: statement, run: run)
            if self.text == run.text {
                editor.runProblem = ConsoleScript.problem(error.details.isEmpty ? error.message : error.details, shown: shown,
                                                          statement: statement, noBackslashEscapes: session.noBackslashEscapes)
            }
            return
        }
        let (sql, json) = ExplainPlan.treeSQL(statement.sql, server: session.server)
        let tree = (await runQuery(sql, on: session))?.first?.rows.flatMap { $0.rowCount > 0 ? $0.string(0, 0) : nil } ?? ""
        addPlan(table: table.results.first?.rows, tree: json ? ExplainPlan.tree(fromJSON: tree) : tree,
                title: "Plan")
        note(.ok, "Plan shown · \(milliseconds(table.duration))", statement: statement, run: run)
    }

    private func finish(_ run: ConsoleRun) {
        run.timer?.invalidate()
        run.activity?.end()
        if running === run { running = nil }
        if shared.runner == documentID { changeShared { $0.runner = nil } }
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
