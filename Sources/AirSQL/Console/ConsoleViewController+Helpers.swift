import AirSQLCore
import AppKit

/// The helpers panel beside the editor and results (View ▸ Query Helpers): it follows the statement at the cursor.
extension ConsoleViewController {
    func makeHelpers() -> HelpersPanel {
        let panel = HelpersPanel()
        panel.source = { [weak self] in
            guard let self else { return ([], nil) }
            let snapshot = self.connectionID.flatMap { Self.schemaCache($0)?.snapshot }
            let columns = SQLCompletion.columns(text: self.text, caret: self.editor.selectedRange().location, snapshot: snapshot,
                                                database: self.database, noBackslashEscapes: self.editor.noBackslashEscapes)
            return (columns.isEmpty ? self.columnsOfTheTreesTable(snapshot) : columns, snapshot?.server)
        }
        panel.snippets = { [weak self] in self?.model.data.settings.snippets ?? [] }
        panel.insertSnippet = { [weak self] snippet in self?.insertSnippet(snippet) }
        panel.editSnippet = { [weak self] snippet in self?.showSnippetSheet(snippet ?? SQLSnippet(name: "", body: "")) }
        panel.removeSnippet = { [weak self] snippet in
            self?.model.data.settings.snippets.removeAll { $0.id == snippet.id }
            self?.helpers.reload()
        }
        panel.history = { [weak self] in
            guard let id = self?.connectionID else { return [] }
            return await QueryHistory.shared.entries(id)
        }
        panel.insert = { [weak self] text in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.editor)
            self.editor.insertText(text, replacementRange: self.editor.selectedRange())
        }
        return panel
    }

    /// The table selected in the tree, on this console's connection, for a statement that names none.
    private func columnsOfTheTreesTable(_ snapshot: SchemaSnapshot?) -> [(table: String, columns: [SQLColumnInfo])] {
        guard let node = mainWindow?.sidebar.selectedNodes.first, case .object(let id, let object) = node.kind, id == connectionID,
              let table = snapshot?.table(object.database, object.name) else { return [] }
        return [(table.name, SQLCompletion.columns(of: table))]
    }

    /// Puts a snippet at the cursor, around the selection if it's written to go around one.
    func insertSnippet(_ snippet: SQLSnippet) {
        view.window?.makeFirstResponder(editor)
        let selection = editor.selectedRange()
        editor.insertTemplate(snippet.body, replacing: selection, selection: (text as NSString).substring(with: selection))
    }

    func showSnippetSheet(_ snippet: SQLSnippet) {
        presentAsSheet(SnippetSheet(snippet) { [weak self] saved in
            guard let self else { return }
            if let index = self.model.data.settings.snippets.firstIndex(where: { $0.id == saved.id }) {
                self.model.data.settings.snippets[index] = saved
            } else {
                self.model.data.settings.snippets.append(saved)
            }
            self.helpers.reload()
        })
    }

    /// Query ▸ Save as Snippet…: the selection, else the statement at the cursor.
    @objc func saveAsSnippet(_ sender: Any?) {
        let selection = editor.selectedRange()
        let sql = selection.length > 0 ? (text as NSString).substring(with: selection)
            : SQLSplitter.statement(at: selection.location, in: text, noBackslashEscapes: editor.noBackslashEscapes)?.sql ?? text
        showSnippetSheet(SQLSnippet(name: "", body: SQLTemplate.escape(sql)))
    }

    /// Reads them off the main thread, for the next suggestions: their file may not be loaded yet.
    func refreshVirtualKeys() {
        guard let id = connectionID else { return }
        Task { [weak self] in
            let keys = await Task.detached { TableViewSettingsStore.shared.virtualKeys(connection: id) }.value
            self?.virtualKeys = keys
        }
    }

    var helpersShown: Bool { outer.arrangedSubviews.contains(helpers) }

    @objc func toggleHelpers(_ sender: Any?) {
        if helpersShown {
            Self.helpersWidth = helpers.frame.width
            outer.removeArrangedSubview(helpers)
            helpers.removeFromSuperview()
            editor.onSelectionChange = nil
            if let treeObserver { NotificationCenter.default.removeObserver(treeObserver) }
            treeObserver = nil
        } else {
            outer.addArrangedSubview(helpers)
            outer.setHoldingPriority(.defaultLow + 10, forSubviewAt: 1)
            outer.layoutSubtreeIfNeeded()
            outer.setPosition(max(320, outer.bounds.width - Self.helpersWidth), ofDividerAt: 0)
            helpers.reload()
            // Follows the statement at the cursor, a moment after it moves.
            editor.onSelectionChange = { [weak self] in
                guard let self else { return }
                NSObject.cancelPreviousPerformRequests(withTarget: self.helpers, selector: #selector(HelpersPanel.reload), object: nil)
                self.helpers.perform(#selector(HelpersPanel.reload), with: nil, afterDelay: 0.3)
            }
            // And the table selected in the tree.
            treeObserver = NotificationCenter.default.addObserver(forName: NSOutlineView.selectionDidChangeNotification, object: mainWindow?.sidebar.outline,
                                                                  queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.helpers.reload() }
            }
        }
    }
}
