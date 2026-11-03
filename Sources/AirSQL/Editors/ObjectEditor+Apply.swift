import AirSQLCore
import AppKit

// The object editor's Apply (the statements in the preview sheet, then run on a tools session), Revert and closing.
extension ObjectEditorController {
    @objc func applyChanges(_ sender: Any?) {
        guard let window = view.window, applyReason == nil, case .success(let statements) = statements else { return }
        let header = CreateHeader(code.string)
        let shown = header?.name ?? name ?? kind.rawValue
        let change = ChangeSQL(title: (name == nil ? "Create " : "Replace ") + kind.rawValue + " " + database + "." + shown,
                               statements: statements, connection: context.connection.id)
        var request = SQLPreviewRequest(change: change,
                                        heading: (name == nil ? "Create the \(kind.rawValue) " : "Replace the \(kind.rawValue) ")
                                            + database + "." + shown + "?",
                                        caption: "It takes effect as soon as this runs; the database is chosen first, and the "
                                            + "\(kind.rawValue)'s own settings set, so it behaves as before.")
        request.actionTitle = name == nil ? "Create" : "Apply"
        request.offersChangeset = true
        if ObjectCode.dropsFirst(kind, server: server), name != nil {
            request.warnings.append("MySQL can't replace a \(kind.rawValue) in one step: it is dropped first, so if the new code fails "
                                    + "it is gone. Your code stays here to fix and apply again, and Revert puts the old code back.")
        }
        if let name, let header, header.name != name {
            request.warnings.append("This renames it: the \(kind.rawValue) \(name) is dropped once \(header.name) is in place.")
            request.destructive = true
        }
        if let definer = header?.definerAccount, let account, definer != account, definer.uppercased() != "CURRENT_USER" {
            request.warnings.append("It runs as \(definer), not as you (\(account)): that needs the SET_USER_ID privilege (MySQL) or "
                                    + "SET USER (MariaDB). Choose Runs as ▸ Me to make it yours.")
        }
        SQLPreviewSheet.show(request, connection: context.connection, on: window) { [weak self] result in
            guard result.approved else { return }
            self?.run(change, newName: header?.name, saveAsChangeset: result.saveAsChangeset)
        }
    }

    @objc func previewChanges(_ sender: Any?) { applyChanges(sender) }

    @objc func revertChanges(_ sender: Any?) {
        guard revertButton.isEnabled else { return }
        let text = original
        guard code.shouldChangeText(in: NSRange(location: 0, length: code.string.utf16.count), replacementString: text) else { return }
        code.textStorage?.replaceCharacters(in: NSRange(location: 0, length: code.string.utf16.count), with: text)
        code.didChangeText()
    }

    /// Runs the statements, then reads the object back under its (new) name.
    func run(_ change: ChangeSQL, newName: String?, saveAsChangeset: Bool) {
        isBusyNow(true)
        let running = RunningSession()
        let work = activity.start(change.title, connection: context.connection.id) {
            Task { _ = try? await running.session?.cancel() }
        }
        let context = self.context, kind = self.kind, database = self.database, oldName = name
        Task {
            var failure: Error?
            var done = 0
            do {
                try await context.withTools { session in
                    running.session = session
                    for statement in change.statements {
                        _ = try await session.query(statement)
                        done += 1
                    }
                }
            } catch {
                failure = error
            }
            work.end()
            let names = Set([oldName, newName].compactMap { $0 })
            try? await context.schema.refresh(names.map { kind.schemaObject(database: database, name: $0) })
            if failure == nil, let newName {
                let fresh = try? await context.read { try await ObjectDefinition.load(kind, database: database, name: newName, from: $0) }
                setLoaded(name: newName, definition: fresh)
                if saveAsChangeset { SQLPreviewSheet.changesetWriter?(change) }
            }
            isBusyNow(false)
            if let failure {
                let message = (failure as? AirSQLError).map { $0.message + "\n\n" + $0.details } ?? failure.localizedDescription
                let dropped = change.statements.prefix(done).contains { $0.hasPrefix("DROP ") }
                showError(message + "\n\n" + (dropped ? "The old \(kind.rawValue) was dropped before the new code failed: fix the code "
                                                  + "and Apply again, or Revert to put the old code back and Apply that."
                                                  : "Nothing was changed."),
                          title: "The server didn't take the \(kind.rawValue)", on: view.window)
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        var enabled = true, reason: String?
        switch item.action {
        case Commands.apply.action?, Commands.previewChanges.action?:
            reason = applyReason
            enabled = reason == nil
        case Commands.revert.action?:
            enabled = revertButton.isEnabled
            reason = revertButton.toolTip
        default:
            break
        }
        item.explain(enabled: enabled, reason: enabled ? nil : reason)
        return enabled
    }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        guard isEdited, let window = view.window else { return answer(true) }
        let alert = NSAlert()
        alert.messageText = name == nil ? "Close without creating the \(kind.rawValue)?" : "Close without applying your changes?"
        alert.informativeText = "The code isn't on the server yet; closing throws it away."
        let close = alert.addButton(withTitle: "Close")
        close.hasDestructiveAction = true
        close.toolTip = "Throw the code away and close the tab"
        alert.addButton(withTitle: "Cancel").toolTip = "Keep the tab and the code"
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }
}

extension ObjectKind {
    /// What the schema cache refreshes after DDL on an object of this kind.
    func schemaObject(database: String, name: String) -> SchemaObject {
        switch self {
        case .view: return .table(database: database, name: name)
        case .procedure, .function: return .routine(database: database, name: name)
        case .trigger: return .trigger(database: database, name: name)
        case .event: return .event(database: database, name: name)
        }
    }
}
