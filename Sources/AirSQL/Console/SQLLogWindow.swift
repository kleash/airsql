import AirSQLCore
import AppKit

/// The SQL log viewer (plan §2.6, View ▸ SQL Log, ⌥⌘L), docked under the main window's tabs or in `SQLLogWindowController`:
/// the last statements AirSQL sent, as SQL.log has them (time, connection, session and the statement, credentials
/// masked), newest at the bottom and following new ones as they come. Typing in the filter keeps the lines with those
/// words. The file is read off the main thread, from where it was last read.
@MainActor
final class SQLLogViewController: NSViewController, NSSearchFieldDelegate {
    let log: SQLLog
    private let filter = NSSearchField()
    let text: NSTextView
    private let scroll = NSTextView.scrollableTextView()
    private let status = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    private(set) var lines: [String] = []
    private var offset: UInt64 = 0
    private var reading = false
    /// The text must be made again from all the lines: the filter changed, or the file did.
    private var needsRebuild = true
    private var timer: Timer?
    /// Lines kept on screen: the newest.
    static let lineLimit = 5_000
    /// Docked: its bar offers the window.
    private let docked: Bool

    init(log: SQLLog, docked: Bool) {
        self.log = log
        self.docked = docked
        text = scroll.documentView as! NSTextView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { timer?.invalidate() }

    override func loadView() {
        text.isEditable = false
        text.backgroundColor = .content
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: docked ? 4 : 8)
        text.setAccessibilityIdentifier("sqlLog.text")
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        filter.placeholderString = "Filter lines"
        filter.toolTip = "Type words to show only the lines that contain them"
        filter.setAccessibilityIdentifier("sqlLog.filter")
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        let reveal = button("Show in Finder", id: "sqlLog.reveal", tip: "Show SQL.log in Finder", target: self,
                            action: #selector(revealLog(_:)))
        let clear = button("Clear Log…", id: "sqlLog.clear", tip: Commands.clearSQLLog.tip, target: self,
                           action: #selector(clearSQLLog(_:)))
        let root = SurfaceView(.ground)
        if docked {
            // Docked it is all lines: its buttons stand in a strip beside them, the filter is in its window.
            let window = button("Open in Window", id: "sqlLog.window", tip: "Show the log in a window of its own, with its filter", target: self,
                                action: #selector(openInWindow(_:)))
            let strip = NSStackView(views: [window.onBar("macwindow"), reveal.onBar("folder"), clear.onBar("trash")])
            strip.orientation = .vertical
            strip.spacing = 0
            for part in [strip, scroll] as [NSView] {
                part.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(part)
            }
            NSLayoutConstraint.activate([
                strip.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
                strip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.half),
                scroll.topAnchor.constraint(equalTo: root.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: strip.leadingAnchor, constant: -Spacing.half),
                scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        } else {
            let bar = NSStackView(views: [filter, status, NSView(), reveal, clear, helpButton(.sqlLog)])
            bar.spacing = Spacing.unit
            let width = filter.widthAnchor.constraint(equalToConstant: 280)
            width.priority = .defaultLow
            width.isActive = true
            filter.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            for part in [bar, scroll] {
                part.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(part)
            }
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
                bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
                bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
                scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
                scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        view = root
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view.window?.isVisible == true, !self.view.isHiddenOrHasHiddenAncestor else { return }
                self.refresh()
            }
        }
    }

    /// Reads what was added to the file since the last read (all of it after it was cleared or started again) and adds
    /// it to the text; nothing new leaves the text and its selection alone. One update at a time, colouring off the main
    /// thread: a filter typed meanwhile is picked up as it ends.
    func refresh() {
        guard !reading else { return }
        reading = true
        let url = log.fileURL, from = offset
        Task {
            let (data, size) = await Task.detached { () -> (Data, UInt64) in
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
                guard size != from, let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), size) }
                defer { try? handle.close() }
                // A smaller file is a new one: read it again from its start, at most its last 2 MB.
                let start = size < from ? max(0, Int64(size) - 2 << 20) : Int64(from)
                try? handle.seek(toOffset: UInt64(max(0, start)))
                return (handle.readDataToEndOfFile(), size)
            }.value
            if size < offset {
                lines = []
                needsRebuild = true
            }
            offset = size
            var new = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if new.count >= Self.lineLimit { needsRebuild = true }
            lines += new
            let dropped = Array(lines.prefix(max(0, lines.count - Self.lineLimit)))
            lines.removeFirst(dropped.count)
            repeat {
                let rebuild = needsRebuild
                needsRebuild = false
                await show(rebuild ? nil : new, dropped: rebuild ? [] : dropped)
                new = []
            } while needsRebuild
            reading = false
        }
    }

    /// `new`, coloured, goes after the lines shown and `dropped` leaves the top; `new` nil: all the lines, from the start.
    private func show(_ new: [String]?, dropped: [String]) async {
        let words = filter.stringValue.lowercased().split(separator: " ").map(String.init)
        let matches = { (line: String) in words.allSatisfy { line.lowercased().contains($0) } }
        let matching = lines.filter(matches).count
        status.stringValue = lines.isEmpty ? "Nothing sent yet: statements show here once you connect"
            : words.isEmpty ? "\(lines.count.formatted()) line\(lines.count == 1 ? "" : "s")" : "\(matching.formatted()) of \(lines.count.formatted()) lines"
        status.toolTip = status.stringValue  // whole, when a narrow window shortens it
        let added = (new ?? lines).filter(matches)
        guard new == nil || !added.isEmpty || !dropped.isEmpty else { return }
        let coloured = await Task.detached { Coloured(text: Self.coloured(added)) }.value.text
        guard let storage = text.textStorage else { return }
        let atEnd = text.enclosingScrollView.map { $0.documentVisibleRect.maxY >= text.bounds.maxY - 20 } ?? true
        if new == nil {
            storage.setAttributedString(coloured)
        } else {
            storage.append(coloured)
            let string = storage.string as NSString
            var end = 0
            for _ in dropped.filter(matches) { end = NSMaxRange(string.lineRange(for: NSRange(location: end, length: 0))) }
            storage.deleteCharacters(in: NSRange(location: 0, length: end))
        }
        if atEnd { text.scrollToEndOfDocument(nil) }
    }

    /// Handed over once by the task that made it, then only read.
    private struct Coloured: @unchecked Sendable { let text: NSAttributedString }

    /// The lines coloured: the time and context grey, the statement as SQL.
    private nonisolated static func coloured(_ lines: [String]) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let result = NSMutableAttributedString()
        for line in lines {
            // "2026-11-03 14:03:12.345 [Shop production main:12] SELECT …"
            let split = line.range(of: "] ").map { line.distance(from: line.startIndex, to: $0.upperBound) } ?? 0
            let head = String(line.prefix(split)), sql = String(line.dropFirst(split))
            result.append(NSAttributedString(string: head, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            if sql.hasPrefix("--") {
                result.append(NSAttributedString(string: sql, attributes: [.font: font, .foregroundColor: NSColor.sqlComment]))
            } else {
                result.append(SQLPreviewSheet.coloured(sql, font: font, noBackslashEscapes: false))
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        }
        return result
    }

    func controlTextDidChange(_ notification: Notification) {
        needsRebuild = true
        refresh()
    }

    @objc private func revealLog(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
    }

    @objc private func openInWindow(_ sender: Any?) { SQLLogWindowController.show(log) }

    /// Clear SQL Log: asks, then removes the log's files (the next statement starts a new one).
    @objc func clearSQLLog(_ sender: Any?) {
        guard let window = view.window else { return }
        ConsoleClosing.alert(window, "Clear the SQL log?", "Every statement listed is removed from SQL.log and SQL.1.log.",
                             buttons: [("Clear", "Remove the logged statements"), ("Cancel", "Keep the log")], destructive: 0) {
            [weak self] choice in
            guard choice == 0, let self else { return }
            SQLLogWindowController.clear(self.log) { self.refresh() }
        }
    }
}

/// The log in a window of its own: one for the app.
@MainActor
final class SQLLogWindowController: NSWindowController {
    private static var shown: SQLLogWindowController?
    let viewer: SQLLogViewController
    var log: SQLLog { viewer.log }
    var text: NSTextView { viewer.text }
    var lines: [String] { viewer.lines }

    /// Shows the log's window, reading the log again.
    @discardableResult
    static func show(_ log: SQLLog = .shared) -> SQLLogWindowController {
        let controller = shown?.log === log ? shown! : SQLLogWindowController(log: log)
        shown = controller
        controller.showWindow(nil)
        controller.viewer.refresh()
        return controller
    }

    init(log: SQLLog) {
        viewer = SQLLogViewController(log: log, docked: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SQL Log"
        window.backgroundColor = .ground
        window.minSize = NSSize(width: 560, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = viewer.view
        window.initialFirstResponder = viewer.text  // where ⌘F finds; the filter's field has no find bar
        window.open(size: NSSize(width: 920, height: 560), autosave: layoutName("SQLLog"))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func refresh() { viewer.refresh() }

    /// Removes the log's files, off the main thread.
    static func clear(_ log: SQLLog, then done: @escaping () -> Void = {}) {
        // The gate (plan §2.8): the log is the person's record, files on this Mac.
        guard !AgentGuard.refuses("The SQL log is the person's: only they can clear it.") else { return }
        let urls = [log.fileURL, log.previousFileURL]
        Task {
            await Task.detached { urls.forEach { try? FileManager.default.removeItem(at: $0) } }.value
            done()
        }
    }
}

extension AppDelegate {
    @objc func showSQLLog(_ sender: Any?) { SQLLogWindowController.show() }

    @objc func clearSQLLog(_ sender: Any?) {
        guard let window = NSApp.keyWindow ?? main?.window else { return SQLLogWindowController.clear(.shared) }
        ConsoleClosing.alert(window, "Clear the SQL log?", "Every statement listed is removed from SQL.log and SQL.1.log.",
                             buttons: [("Clear", "Remove the logged statements"), ("Cancel", "Keep the log")], destructive: 0) {
            choice in
            if choice == 0 { SQLLogWindowController.clear(.shared) }
        }
    }
}
