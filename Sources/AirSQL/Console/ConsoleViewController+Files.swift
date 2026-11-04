import AirSQLCore
import AppKit
import UniformTypeIdentifiers

/// A console as a document: Save (⌘S) to its .sql file, Save As… to a new one, Change Connection…. Files are read and
/// written off the main thread.
extension ConsoleViewController {
    @objc func saveQuery(_ sender: Any?) { save(as: fileURL == nil) { _ in } }
    @objc func saveQueryAs(_ sender: Any?) { save(as: true) { _ in } }

    /// Saves the text (to a file chosen first when `as`); `done` says whether it was saved.
    func save(as choose: Bool, done: @escaping (Bool) -> Void) {
        guard choose || fileURL == nil, let window = view.window else {
            if let url = fileURL { write(text, to: url, done: done) } else { done(false) }
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? tab?.title ?? "Query") + ".sql"
        panel.message = "Save the tab's SQL in a file"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return done(false) }
            self.write(self.text, to: url, done: done)
        }
    }

    private func write(_ text: String, to url: URL, done: @escaping (Bool) -> Void) {
        // The gate (plan §2.8): files on this Mac are the person's to write.
        guard !AgentGuard.refuses("Saving writes a file on this Mac: only the person at the Mac can save (⌘S).") else {
            return done(false)
        }
        Task {
            let failure = await Task.detached { () -> String? in
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                note(.error, "AirSQL couldn't save “\(url.lastPathComponent)”: \(failure)")
                return done(false)
            }
            setFile(url, savedText: text)
            done(true)
        }
    }

    @objc func changeConnection(_ sender: Any?) {
        guard let window = view.window else { return }
        let choices = model.data.connections.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let menu = popup(choices.map(\.displayName), selected: choices.firstIndex { $0.id == connectionID } ?? 0,
                         id: "console.connectionChoice", tip: "Choose the connection this console's statements run on",
                         target: nil, action: nil)
        menu.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
        menu.translatesAutoresizingMaskIntoConstraints = true
        ConsoleClosing.alert(window, "Run this tab's statements on another connection",
                             "Results and the transaction stay with the connection they belong to.",
                             buttons: [("Change", "Use the connection chosen above"), ("Cancel", "Keep the connection it has")],
                             destructive: nil, accessory: menu) { [weak self] choice in
            guard choice == 0, let self, choices.indices.contains(menu.indexOfSelectedItem) else { return }
            self.setConnection(choices[menu.indexOfSelectedItem].id)
            self.showResults()
        }
    }
}
