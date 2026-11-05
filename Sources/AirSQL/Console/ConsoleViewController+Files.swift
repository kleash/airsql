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
                    LocalHistory.shared.save(text, of: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                note(.error, "AirSQL couldn't save “\(url.lastPathComponent)”: \(failure)")
                return done(false)
            }
            fileDate = await Self.date(of: url)
            setFile(url, savedText: text)
            done(true)
        }
    }

    private nonisolated static func date(of url: URL) async -> Date? {
        await Task.detached { try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date }.value
    }

    /// The file changed on disk since it was read or saved: the text follows it, or with unsaved edits Messages warns.
    @objc func checkFile() {
        guard let url = fileURL, !closing else { return }
        Task { [weak self] in
            guard let date = await Self.date(of: url), let self, url == self.fileURL else { return }
            defer { self.fileDate = date }
            guard let known = self.fileDate, date != known else { return }
            if self.isEdited {
                return self.note(.warning, "“\(url.lastPathComponent)” changed on disk: saving here replaces that version.")
            }
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            guard let data else { return }
            let text = ConsoleScript.decoded(data).text
            self.editor.replace(NSRange(location: 0, length: (self.text as NSString).length), with: text)
            self.savedText = text
            self.note(.info, "“\(url.lastPathComponent)” changed on disk, so the tab shows the new text. ⌘Z brings back what it showed.")
        }
    }

    private static let fileConnections = "ConsoleFileConnections"

    /// The connection a .sql file was last used on, for the next time it opens.
    static func rememberedConnection(of url: URL) -> UUID? {
        (UserDefaults.standard.dictionary(forKey: fileConnections)?[url.path] as? String).flatMap(UUID.init(uuidString:))
    }

    static func rememberConnection(of url: URL, _ id: UUID?) {
        guard let id else { return }
        var all = UserDefaults.standard.dictionary(forKey: fileConnections) ?? [:]
        all[url.path] = id.uuidString
        UserDefaults.standard.set(all, forKey: fileConnections)
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
