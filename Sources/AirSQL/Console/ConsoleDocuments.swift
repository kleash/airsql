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
    /// The first window, whose model says what the others are: the one tabs were restored into, else the first a console
    /// is shown in.
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
        if main?.model === window.model { schedule() }
    }

    /// A window went: the next first window takes over if it was this.
    func windowClosed(_ window: MainWindowController) {
        if main === window { main = window.model.windows.first }
        schedule()
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save(wait: false) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// The windows now, the first with the others in it.
    var snapshot: SavedWindow {
        guard let main else { return SavedWindow() }
        var saved = snapshot(of: main)
        let others = main.model.windows.filter { $0 !== main }.map { window -> SavedWindow in
            var other = snapshot(of: window)
            other.frame = window.window.map { NSStringFromRect($0.frame) }
            return other
        }
        saved.others = others.isEmpty ? nil : others
        return saved
    }

    /// A window now: its tabs in their order (a console being closed, an empty one without a file, a sync script, whose
    /// compare doesn't outlive the app, and tabs without a `place` left out) and the sidebar's selection.
    private func snapshot(of main: MainWindowController) -> SavedWindow {
        let tabs = main.tabs.compactMap { tab -> SavedConsole? in
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
            if tab === main.selectedTab { saved?.selected = true }
            if tab.pinned { saved?.pinned = true }
            return saved
        }
        return SavedWindow(tabs: tabs, sidebar: main.sidebar.selectedRowIDs)
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

    /// A kept tab with its text, and the text and format of its file (what was last saved).
    private typealias Loaded = (console: SavedConsole, text: String, file: String, format: ConsoleScript.FileFormat)

    private nonisolated static func load(_ window: SavedWindow) -> [Loaded] {
        window.tabs.compactMap { console in
            if console.place != nil { return (console, "", "", ConsoleScript.FileFormat()) }
            let file = console.path.flatMap { path in (try? Data(contentsOf: URL(fileURLWithPath: path))).map(ConsoleScript.decoded) }
            guard let text = console.text ?? file?.text else { return nil }
            return (console, text, file?.text ?? "", file?.format ?? ConsoleScript.FileFormat())
        }
    }

    /// Opens the tabs of the last session in `main` and windows like it for the others, reading them (and their files)
    /// off the main thread. A tab whose connection is gone is dropped, and the rest are placeholders; none of it contacts a
    /// server.
    func restore(into main: MainWindowController) {
        self.main = main
        let url = fileURL
        restoring = Task {
            let (windows, loaded) = await Task.detached { () -> ([SavedWindow], [[Loaded]]) in
                let first = ConsoleTabStore.load(from: url)
                let windows = [first] + (first.others ?? [])
                return (windows, windows.map(Self.load))
            }.value
            for (index, (saved, tabs)) in zip(windows, loaded).enumerated() where index == 0 || !tabs.isEmpty {
                let window = index == 0 ? main : main.anotherWindow()
                if let frame = saved.frame.map(NSRectFromString), NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                    window.window?.setFrame(frame, display: false)
                }
                fill(window, with: tabs, sidebar: saved.sidebar)
                if index > 0 { window.showWindow(nil) }
            }
        }
    }

    private func fill(_ main: MainWindowController, with saved: [Loaded], sidebar: [UUID]) {
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
            if console.pinned == true { main.setPinned(true, tab) }
        }
        main.sidebar.select(sidebar)
        if let selected { main.select(selected) }
    }
}
