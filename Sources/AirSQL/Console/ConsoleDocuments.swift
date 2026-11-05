import AirSQLCore
import AppKit

/// Keeps the open tabs for the next launch (plan §2.6): after each change, a moment later, Consoles.json is written off
/// the main thread with every console tab's title, connection, file and unsaved text, what the other tabs showed (by
/// name), the tab shown and the sidebar's selection; at quit it is written at once. `restore(into:)` opens them again
/// (AppDelegate calls it once the main window is up), the others as placeholders: nothing connects.
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

    /// The window's tabs or the sidebar's selection changed: saved a moment later.
    func tabsChanged(in window: MainWindowController) {
        if main == nil { main = window }
        if main === window { schedule() }
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save(wait: false) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// The window now: its tabs in their order (a console being closed, an empty one without a file, a sync script, whose
    /// compare doesn't outlive the app, and tabs without a `place` left out) and the sidebar's selection.
    var snapshot: SavedWindow {
        let tabs = (main?.tabs ?? []).compactMap { tab -> SavedConsole? in
            var saved: SavedConsole?
            if let console = tab.content as? ConsoleViewController {
                let text = console.text
                guard !console.closing, console.syncScript == nil, console.fileURL != nil || !text.isEmpty else { return nil }
                saved = SavedConsole(id: console.documentID, title: tab.title, connection: console.connectionID,
                                     path: console.fileURL?.path, text: console.isEdited || console.fileURL == nil ? text : nil,
                                     caret: console.isViewLoaded ? console.editor.selectedRange().location : 0,
                                     database: console.chosenDatabase)
            } else if let place = tab.place {
                saved = SavedConsole(id: tab.id, title: tab.title, connection: tab.connectionID, path: nil, text: nil, caret: 0,
                                     place: place, preview: tab.content is PreviewContent ? true : nil)
            }
            if tab === main?.selectedTab { saved?.selected = true }
            return saved
        }
        return SavedWindow(tabs: tabs, sidebar: main?.sidebar.selectedRowIDs ?? [])
    }

    /// Writes now and waits until it's on disk: quitting, so the last text isn't lost.
    func saveNow() { save(wait: true) }

    /// Takes the snapshot on the main thread, then writes it off it. `wait` blocks until the write is done (quit);
    /// otherwise, from the debounced path, the write runs on the queue without holding up the main thread.
    private func save(wait: Bool) {
        pending?.cancel()
        pending = nil
        let window = snapshot, url = fileURL
        let write: @Sendable () -> Void = {
            do {
                try ConsoleTabStore.save(window, to: url)
            } catch {
                log.error("can't save the tabs: \(error.localizedDescription, privacy: .public)")
            }
        }
        if wait { queue.sync(execute: write) } else { queue.async(execute: write) }
    }

    /// Opens the tabs of the last session in `main`, reading them (and their files) off the main thread. A tab whose
    /// connection is gone is dropped, and the rest are placeholders; none of it contacts a server.
    func restore(into main: MainWindowController) {
        self.main = main
        let url = fileURL
        restoring = Task {
            // Each console's text, and the text of its file (what was last saved).
            let (saved, sidebar) = await Task.detached { () -> ([(SavedConsole, String, String, ConsoleScript.FileFormat)], [UUID]) in
                let window = ConsoleTabStore.load(from: url)
                return (window.tabs.compactMap { console in
                    if console.place != nil { return (console, "", "", ConsoleScript.FileFormat()) }
                    let file = console.path.flatMap { path in (try? Data(contentsOf: URL(fileURLWithPath: path))).map(ConsoleScript.decoded) }
                    guard let text = console.text ?? file?.text else { return nil }
                    return (console, text, file?.text ?? "", file?.format ?? ConsoleScript.FileFormat())
                }, window.sidebar)
            }.value
            var selected: Tab?
            for (console, text, file, format) in saved {
                let tab: Tab
                if let place = console.place {
                    guard let id = main.model.connection(console.connection)?.id else { continue }
                    let content = RestoredTabContent(place, title: console.title, connection: id, main: main)
                    tab = main.open(console.preview == true ? PreviewContent(content) : content, title: console.title, connection: id)
                } else {
                    let controller = ConsoleViewController(model: main.model, connection: main.model.connection(console.connection)?.id,
                                                           text: text, fileURL: console.path.map { URL(fileURLWithPath: $0) },
                                                           documentID: console.id)
                    if console.path != nil { controller.savedText = file }
                    controller.chosenDatabase = console.database
                    controller.fileFormat = format
                    tab = main.open(controller, title: console.title, connection: controller.connectionID)
                    controller.editor.setSelectedRange(NSRange(location: min(console.caret, (text as NSString).length), length: 0))
                    changed(controller)
                }
                if console.selected == true { selected = tab }
            }
            main.sidebar.select(sidebar)
            if let selected { main.select(selected) }
        }
    }
}
