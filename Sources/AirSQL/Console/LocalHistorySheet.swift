import AirSQLCore
import AppKit

/// File ▸ Local History…: the states the tab's file was saved in, newest first. A click shows one, Restore (or a
/// double-click) puts it in the editor, the lines that differ from the editor's tinted, as an edit that ⌘Z takes back and nothing written until Save.
@MainActor
final class LocalHistorySheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let versions: [(date: Date, text: String)]
    private let restore: (String) -> Void
    /// The editor's text, which each state is compared with.
    private let current: String
    private let table = ContentTable()
    private let preview = NSTextView.scrollableTextView()

    init(versions: [(date: Date, text: String)], current: String, restore: @escaping (String) -> Void) {
        self.versions = versions
        self.current = current
        self.restore = restore
        super.init(nibName: nil, bundle: nil)
        title = "Local History"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("saved"))
        column.title = "Saved"
        column.width = 200
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(restoreSelected(_:))
        table.setAccessibilityIdentifier("localHistory.list")
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        list.borderType = .bezelBorder
        list.translatesAutoresizingMaskIntoConstraints = false
        let code = preview.documentView as! NSTextView
        code.isEditable = false
        code.backgroundColor = .content
        code.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        code.setAccessibilityIdentifier("localHistory.preview")
        preview.borderType = .bezelBorder
        preview.translatesAutoresizingMaskIntoConstraints = false
        let cancel = button("Cancel", id: "localHistory.cancel", tip: "Close without changing the text", target: self, action: #selector(close(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let use = button("Restore", id: "localHistory.restore", tip: "Put this saved state in the editor; ⌘Z takes it back",
                         target: self, action: #selector(restoreSelected(_:)), primary: true)
        use.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, use])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let root = SurfaceView(.ground)
        for view in [list, preview, buttons] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 720), root.heightAnchor.constraint(greaterThanOrEqualToConstant: 440),
            list.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            list.widthAnchor.constraint(equalToConstant: 210),
            preview.topAnchor.constraint(equalTo: list.topAnchor), preview.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 8),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: list.leadingAnchor), buttons.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        view = root
        table.selectRowIndexes([0], byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { versions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: versions[row].date.formatted(date: .abbreviated, time: .standard))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard versions.indices.contains(table.selectedRow) else { return }
        let lines = versions[table.selectedRow].text.components(separatedBy: "\n")
        let different = Set(lines.difference(from: current.components(separatedBy: "\n")).insertions.map(\.offset))
        let shown = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        for (index, line) in lines.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if different.contains(index) { attributes[.backgroundColor] = NSColor.statusWarning.withAlphaComponent(0.2) }
            shown.append(NSAttributedString(string: line + (index + 1 < lines.count ? "\n" : ""), attributes: attributes))
        }
        (preview.documentView as? NSTextView)?.textStorage?.setAttributedString(shown)
    }

    func select(row: Int) { table.selectRowIndexes([row], byExtendingSelection: false) }

    @objc private func restoreSelected(_ sender: Any?) {
        guard versions.indices.contains(table.selectedRow) else { return }
        let text = versions[table.selectedRow].text
        close(nil)
        restore(text)
    }

    @objc private func close(_ sender: Any?) {
        guard let sheet = view.window else { return }
        sheet.sheetParent?.endSheet(sheet)
    }
}

extension ConsoleViewController {
    @objc func showLocalHistory(_ sender: Any?) {
        guard let fileURL, let window = view.window, window.attachedSheet == nil else { return }
        Task { [weak self] in
            let versions = await Task.detached { () -> [(date: Date, text: String)] in
                LocalHistory.shared.versions(of: fileURL).compactMap { version in
                    (try? String(contentsOf: version.url, encoding: .utf8)).map { (version.date, $0) }
                }
            }.value
            guard let self else { return }
            guard !versions.isEmpty else { return self.note(.info, "This file has no saved states yet: they're kept each time you save it here.") }
            let sheet = LocalHistorySheet(versions: versions, current: self.text) { [weak self] text in
                guard let self else { return }
                self.editor.replace(NSRange(location: 0, length: (self.text as NSString).length), with: text,
                                    select: NSRange(location: 0, length: 0))
            }
            let panel = NSPanel(contentViewController: sheet)
            panel.styleMask = [.titled, .resizable]
            window.beginSheet(panel, completionHandler: nil)
        }
    }
}
