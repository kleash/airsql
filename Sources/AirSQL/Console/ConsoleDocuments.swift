import AirSQLCore
import AppKit

/// Keeps the open console tabs for the next launch (plan §2.6): after each change, a moment later, Consoles.json is
/// written off the main thread with every console's title, connection, file and unsaved text; at quit it is written at
/// once. `restore(into:)` opens them again.
@MainActor
final class ConsoleDocuments {
    static let shared = ConsoleDocuments()

    /// Where they are kept; tests use their own.
    var fileURL = ConsoleTabStore.fileURL
    private var consoles: [Weak] = []
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.kleash.airsql.consoles")

    private struct Weak { weak var console: ConsoleViewController? }

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    /// A console changed (its text, file, connection or name): saved a moment later.
    func changed(_ console: ConsoleViewController) {
        consoles.removeAll { $0.console == nil }
        if !consoles.contains(where: { $0.console === console }) { consoles.append(Weak(console: console)) }
        schedule()
    }

    /// A console closed: it doesn't come back.
    func closed(_ console: ConsoleViewController) {
        consoles.removeAll { $0.console == nil || $0.console === console }
        schedule()
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// What is open now, in the tabs' order.
    var snapshot: [SavedConsole] {
        let open = consoles.compactMap(\.console)
        let ordered = open.sorted { a, b in
            let tabs = a.mainWindow?.tabs ?? []
            return (tabs.firstIndex { $0.content === a } ?? .max) < (tabs.firstIndex { $0.content === b } ?? .max)
        }
        return ordered.compactMap { console in
            let text = console.text
            // An empty console without a file isn't worth bringing back.
            guard console.fileURL != nil || !text.isEmpty else { return nil }
            return SavedConsole(id: console.documentID, title: console.tab?.title ?? "Query", connection: console.connectionID,
                                path: console.fileURL?.path, text: console.isEdited || console.fileURL == nil ? text : nil,
                                caret: console.isViewLoaded ? console.editor.selectedRange().location : 0)
        }
    }

    /// Writes now (and waits: quitting).
    func saveNow() {
        pending?.cancel()
        pending = nil
        let consoles = snapshot, url = fileURL
        queue.sync {
            do {
                try ConsoleTabStore.save(consoles, to: url)
            } catch {
                log.error("can't save the console tabs: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Opens the consoles of the last session in `main`, reading them (and their files) off the main thread.
    func restore(into main: MainWindowController) {
        let url = fileURL
        Task {
            // Each console's text, and the text of its file (what was last saved).
            let saved = await Task.detached { () -> [(SavedConsole, String, String)] in
                ConsoleTabStore.load(from: url).compactMap { console in
                    let file = console.path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
                    guard let text = console.text ?? file else { return nil }
                    return (console, text, file ?? "")
                }
            }.value
            for (console, text, file) in saved {
                let controller = ConsoleViewController(model: main.model, connection: main.model.connection(console.connection)?.id,
                                                       text: text, fileURL: console.path.map { URL(fileURLWithPath: $0) },
                                                       documentID: console.id)
                if console.path != nil { controller.savedText = file }
                main.open(controller, title: console.title, connection: controller.connectionID)
                controller.editor.setSelectedRange(NSRange(location: min(console.caret, (text as NSString).length), length: 0))
                changed(controller)
            }
        }
    }
}
