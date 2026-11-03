import AirSQLCore
import AppKit
import UniformTypeIdentifiers

extension MainWindowController {
    /// Tools ▸ Compare… (and a connection's or a database's menu): a compare window, the selected connection, or the
    /// tree's database, as the source.
    @objc func compareDatabases(_ sender: Any?) {
        let compare = ReconWindowController.show(model: model, source: selectedConnections.first)
        compare.main = self
        if let (open, nodes) = sidebar.treeSelection {
            compare.source.choose(model.connection(open.id), database: nodes.first?.database)
        }
    }
}

/// The compare window's commands: the sync script, the report, the changeset, copying and leaving tables out.
extension ReconWindowController {
    /// The whole sync script in a console tab of the target marked "sync script" (plan §2.9), to review. It never runs
    /// on its own: Run there brings this window back with the script in the SQL preview.
    @objc func showSyncScript(_ sender: Any?) {
        guard let result, let window, let saved = target.connection, let main else { return }
        let destructive = results.detail.includeDestructive
        if let why = nothingToSync(result, destructive: destructive) { return showError(why, title: "Nothing to sync", on: window) }
        let script = result.script(destructive: destructive).map { $0 + ";" }.joined(separator: "\n\n")
        guard let console = main.openConsole(text: script, title: "Sync script · \(result.target.database)",
                                             connection: saved.id).content as? ConsoleViewController else { return }
        console.editor.isEditable = false
        console.syncScript = { [weak self] in self?.confirmSync(result, destructive: destructive, on: saved) != nil }
        console.syncChangesets = { [weak self] in self?.saveLiquibase(result, destructive: destructive) != nil }
        console.note(.info, "The compare's sync script, to review: it can't be edited here. Run shows it in the SQL preview "
                     + "in the compare window first; nothing runs on its own.")
        main.showWindow(nil)
    }

    /// Why the sync script is empty; nil when it has steps.
    private func nothingToSync(_ result: ReconResult, destructive: Bool) -> String? {
        guard result.steps(destructive: destructive).isEmpty else { return nil }
        return !result.objects.contains(where: \.differs) ? "The two databases match."
            : !destructive && !result.steps(destructive: true).isEmpty
            ? "What differs only goes away with destructive steps (DROP, DELETE): tick “Include destructive steps” to put "
                + "them in the script."
            : "The script can't change what differs (rows of tables without a key, or too many rows to list)."
    }

    /// The sync script in the SQL preview; run on a session of the target's own only when the person approves.
    private func confirmSync(_ result: ReconResult, destructive: Bool, on saved: SavedConnection) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        let steps = result.steps(destructive: destructive)
        let change = ChangeSQL(title: "Sync \(result.target.name) · \(result.target.database) with \(result.source.name)",
                               statements: result.script(destructive: destructive), connection: saved.id)
        var request = SQLPreviewRequest(
            change: change, heading: "Make \(result.target.name) · \(result.target.database) match \(result.source.name)?",
            caption: "Structure changes run first, each on its own (MySQL and MariaDB can't roll DDL back). Row changes then "
                + "run in one transaction: each must change exactly its rows, or they all roll back.")
        request.actionTitle = "Run Script"
        request.offersChangeset = true
        request.destructive = steps.contains(where: \.destructive)
        let tables = Set(steps.filter { $0.kind == .data }.map(\.object))
        request.warnings = result.objects.filter { object in
            tables.contains(object.name) && ["myisam", "aria", "memory"].contains(object.targetEngine?.lowercased() ?? "")
        }.map { "\($0.targetName) uses \($0.targetEngine ?? ""): a failed sync can't roll its rows back" }
        SQLPreviewSheet.show(request, connection: saved, on: window) { [weak self] answer in
            guard answer.approved else { return }
            self?.sync(result, destructive: destructive, change: change, saveAsChangeset: answer.saveAsChangeset, on: saved)
        }
    }

    private func sync(_ result: ReconResult, destructive: Bool, change: ChangeSQL, saveAsChangeset: Bool,
                      on saved: SavedConnection) {
        guard let connect = Self.connect else { return }
        let window = self.window
        let total = result.runnable(destructive: destructive).count
        let work = model.activity.start("Running the sync script on \(saved.displayName) · \(result.target.database)",
                                        connection: saved.id, cancel: nil)
        Task { [weak self] in
            var failure: Error?
            do {
                let session = try await connect(saved, window).toolsSession()
                do {
                    try await result.apply(destructive: destructive, on: session) { done in
                        DispatchQueue.main.async {
                            work.progress = Double(done) / Double(max(1, total))
                            work.detail = "\(done) of \(total) statements"
                        }
                    }
                } catch {
                    failure = error
                }
                await session.close()
            } catch {
                failure = error
            }
            work.end()
            guard let self, let window = self.window else { return }
            if let failure {
                showError(failure.localizedDescription, title: "The sync script stopped", on: window)
                return
            }
            if saveAsChangeset { self.saveLiquibase(result, destructive: destructive) }
            let alert = NSAlert()
            alert.messageText = "The sync script ran"
            alert.informativeText = "Compare again to check, and to copy the values of columns the script added."
            alert.addButton(withTitle: "Compare Again").toolTip = "Compare the two databases again (⌘R)"
            alert.addButton(withTitle: "Later").toolTip = "Keep the result of the last compare on screen"
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.refresh(nil) }
            }
        }
    }

    /// Saves the report as HTML, CSV or Markdown, written off the main thread.
    @objc func exportReport(_ sender: Any?) {
        guard let result, let window else { return }
        let panel = NSSavePanel()
        let chooser = ReportFormatChooser(panel)
        panel.accessoryView = chooser.view
        panel.nameFieldStringValue = "Compare \(result.source.database) with \(result.target.database).html"
        panel.allowedContentTypes = [.html]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let format = chooser.format
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try ReconReport.text(result, format: format).write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    DispatchQueue.main.async { showError(error.localizedDescription, title: "The report wasn't saved", on: window) }
                }
            }
        }
    }

    /// The sync script as Liquibase changesets: one per structure step, one per run of row changes on a table.
    @objc func saveChangeset(_ sender: Any?) {
        guard let result else { return }
        saveLiquibase(result, destructive: results.detail.includeDestructive)
    }

    private func saveLiquibase(_ result: ReconResult, destructive: Bool) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        if let why = nothingToSync(result, destructive: destructive) { return showError(why, title: "Nothing to save", on: window) }
        ChangesetSheet.show(Liquibase.changesets(result, destructive: destructive, rollback: model.data.settings.liquibase.rollback),
                            heading: "Save the sync script for \(result.target.name) · \(result.target.database) as changesets",
                            model: model, on: window)
    }

    /// Copies the selected objects' names (the grid of rows that differ copies its own cells).
    @objc func copy(_ sender: Any?) {
        put(results.selected.map(\.name).joined(separator: "\n"))
    }

    @objc func copySyncScript(_ sender: Any?) {
        guard let result else { return }
        let chosen = Set(results.selected.map { "\($0.kind) \($0.name)" })
        put(result.steps(destructive: results.detail.includeDestructive).filter { chosen.contains("\($0.objectKind) \($0.object)") }
            .map { $0.sql + ";" }.joined(separator: "\n\n"))
    }

    @objc func leaveOutOfCompare(_ sender: Any?) {
        for object in results.selected where object.kind == .table && object.status != .onlyInTarget {
            options.tables[object.name, default: ReconTableChoice()].included = false
        }
    }

    @objc func showTables(_ sender: Any?) {
        guard let result, let window else { return }
        ReconTablesSheet.show(for: self, tables: result.objects.filter { $0.kind == .table }, on: window)
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The report's format under the save panel; choosing one changes the file's extension.
@MainActor
final class ReportFormatChooser: NSObject {
    let view: NSStackView
    private let choice = popup(["HTML", "CSV", "Markdown"], selected: 0, id: "recon.reportFormat",
                               tip: "Choose the report's format: HTML to read, CSV for a spreadsheet, Markdown for a ticket",
                               target: nil, action: nil)
    private weak var panel: NSSavePanel?

    init(_ panel: NSSavePanel) {
        self.panel = panel
        view = NSStackView(views: [label("Format:"), choice])
        view.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        super.init()
        choice.target = self
        choice.action = #selector(chosen(_:))
    }

    var format: ReconReport.Format { ReconReport.Format.allCases[max(0, choice.indexOfSelectedItem)] }

    @objc private func chosen(_ sender: Any?) {
        panel?.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
    }
}
