import AirSQLCore
import AppKit

/// Keeps the open console tabs for the next launch (plan §2.6): after each change, a moment later, Consoles.json is
/// written off the main thread with every console tab's title, connection, file and unsaved text; at quit it is
/// written at once. `restore(into:)` opens them again (AppDelegate calls it once the main window is up).
@MainActor
final class ConsoleDocuments {
    static let shared = ConsoleDocuments()

    /// Where they are kept; tests use their own.
    var fileURL = ConsoleTabStore.fileURL
    /// The window whose console tabs are kept: the one they were restored into, else the first a console is shown in.
    weak var main: MainWindowController?
    /// The last session's consoles coming back: files opened meanwhile (from Finder, at launch) wait for them, so a file
    /// among them shows its tab instead of a second one.
    private(set) var restoring: Task<Void, Never>?
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.kleash.airsql.consoles")

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    /// A console changed (its text, file, connection or name), or closed: saved a moment later.
    func changed(_ console: ConsoleViewController) {
        if main == nil { main = console.mainWindow }
        schedule()
    }

    func closed(_ console: ConsoleViewController) { schedule() }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save(wait: false) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// The window's console tabs now, in their order (a console being closed, an empty one without a file, and a sync
    /// script, whose compare doesn't outlive the app, left out).
    var snapshot: [SavedConsole] {
        (main?.tabs ?? []).compactMap { tab in
            guard let console = tab.content as? ConsoleViewController, !console.closing, console.syncScript == nil else {
                return nil
            }
            let text = console.text
            guard console.fileURL != nil || !text.isEmpty else { return nil }
            return SavedConsole(id: console.documentID, title: tab.title, connection: console.connectionID,
                                path: console.fileURL?.path, text: console.isEdited || console.fileURL == nil ? text : nil,
                                caret: console.isViewLoaded ? console.editor.selectedRange().location : 0)
        }
    }

    /// Writes now and waits until it's on disk: quitting, so the last text isn't lost.
    func saveNow() { save(wait: true) }

    /// Takes the snapshot on the main thread, then writes it off it. `wait` blocks until the write is done (quit);
    /// otherwise, from the debounced path, the write runs on the queue without holding up the main thread.
    private func save(wait: Bool) {
        pending?.cancel()
        pending = nil
        let consoles = snapshot, url = fileURL
        let write: @Sendable () -> Void = {
            do {
                try ConsoleTabStore.save(consoles, to: url)
            } catch {
                log.error("can't save the console tabs: \(error.localizedDescription, privacy: .public)")
            }
        }
        if wait { queue.sync(execute: write) } else { queue.async(execute: write) }
    }

    /// Opens the consoles of the last session in `main`, reading them (and their files) off the main thread.
    func restore(into main: MainWindowController) {
        self.main = main
        let url = fileURL
        restoring = Task {
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
