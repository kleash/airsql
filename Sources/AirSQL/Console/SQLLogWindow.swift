import AirSQLCore
import AppKit

/// The SQL log viewer (plan §2.6, View ▸ SQL Log, ⌥⌘L): the last statements AirSQL sent, as SQL.log has them (time,
/// connection, session and the statement, credentials masked), newest at the bottom and following new ones as they
/// come. Typing in the filter keeps the lines with those words. The file is read off the main thread, from where it
/// was last read.
@MainActor
final class SQLLogWindowController: NSWindowController, NSSearchFieldDelegate {
    private static var shown: SQLLogWindowController?
    let log: SQLLog
    private let filter = NSSearchField()
    let text: NSTextView
    private let status = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    private(set) var lines: [String] = []
    private var offset: UInt64 = 0
    private var reading = false
    /// The text must be made again from all the lines: the filter changed, or the file did.
    private var needsRebuild = true
    private var timer: Timer?
    /// Lines kept on screen: the newest.
    static let lineLimit = 5_000

    /// Shows the log's window (one for the app), reading the log again.
    @discardableResult
    static func show(_ log: SQLLog = .shared) -> SQLLogWindowController {
        let controller = shown?.log === log ? shown! : SQLLogWindowController(log: log)
        shown = controller
        controller.showWindow(nil)
        controller.refresh()
        return controller
    }

    init(log: SQLLog) {
        self.log = log
        let scroll = NSTextView.scrollableTextView()
        text = scroll.documentView as! NSTextView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SQL Log"
        window.minSize = NSSize(width: 560, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.setAccessibilityIdentifier("sqlLog.text")
        filter.placeholderString = "Filter: words a line contains"
        filter.toolTip = "Type words to show only the lines that contain them"
        filter.setAccessibilityIdentifier("sqlLog.filter")
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        let reveal = button("Show in Finder", id: "sqlLog.reveal", tip: "Show SQL.log in Finder", target: self,
                            action: #selector(revealLog(_:)))
        let clear = button("Clear Log…", id: "sqlLog.clear", tip: Commands.clearSQLLog.tip, target: self,
                           action: #selector(clearSQLLog(_:)))
        let bar = NSStackView(views: [filter, status, NSView(), reveal, clear])
        bar.spacing = Spacing.unit
        filter.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let root = SurfaceView(.ground)
        for view in [bar, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
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
        window.contentView = root
        window.open(size: NSSize(width: 920, height: 560), autosave: layoutName("SQLLog"))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.refresh()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
            : words.isEmpty ? "\(lines.count.formatted()) lines" : "\(matching.formatted()) of \(lines.count.formatted()) lines"
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

    /// Clear SQL Log: asks, then removes the log's files (the next statement starts a new one).
    @objc func clearSQLLog(_ sender: Any?) {
        guard let window else { return }
        ConsoleClosing.alert(window, "Clear the SQL log?", "Every statement listed is removed from SQL.log and SQL.1.log.",
                             buttons: [("Clear", "Remove the logged statements"), ("Cancel", "Keep the log")], destructive: 0) {
            [weak self] choice in
            guard choice == 0, let self else { return }
            Self.clear(self.log) { self.refresh() }
        }
    }

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
