import AirSQLCore
import AppKit

/// Find in Tabs and Files: a text in every query tab and, when a folder is chosen, its .sql files, read off the main
/// thread. A double-click goes to the place. Replace works on the tabs only, with Undo, and saves nothing.
@MainActor
final class FindInFilesContent: NSViewController, TabContent, NSTableViewDataSource, NSTableViewDelegate {
    struct Hit {
        var title: String
        /// A query tab's, else a file's.
        var console: ConsoleViewController?
        var file: URL?
        var match: TextSearch.Match
    }

    private weak var main: MainWindowController?
    let field = NSSearchField()
    let replacement = NSTextField()
    let table = ReturnTable()
    private(set) var hits: [Hit] = []
    private(set) var folder: URL?
    private var searched = ""
    private var search: Task<Void, Never>?
    private lazy var folderButton = button("Folder…", id: "findFiles.folder", tip: "Choose a folder whose .sql files are searched too", target: self,
                                           action: #selector(chooseFolder(_:)))
    private let status = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    private let spinner = NSProgressIndicator()
    /// Files bigger than this are left out: a dump isn't what's being looked for.
    private nonisolated static let largestFile = 20 << 20

    init(main: MainWindowController) {
        self.main = main
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.content)
        root.setAccessibilityIdentifier("findFiles")
        field.placeholderString = "Text to find"
        field.toolTip = "Type the text to look for; press Return to search"
        field.setAccessibilityIdentifier("findFiles.text")
        field.sendsWholeSearchString = true
        field.target = self
        field.action = #selector(find(_:))
        replacement.placeholderString = "Replace with"
        replacement.toolTip = "Type what Replace in Tabs puts in place of the text"
        replacement.setAccessibilityIdentifier("findFiles.replacement")
        let replace = button("Replace in Tabs", id: "findFiles.replace", tip: "Replace every match in the query tabs; Undo there takes it back, and nothing is saved",
                             target: self, action: #selector(replaceInTabs(_:)))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Searching")
        status.stringValue = "Searches every query tab. Choose a folder to search its .sql files too."
        status.toolTip = status.stringValue
        status.setAccessibilityIdentifier("findFiles.status")
        let bar = NSStackView(views: [field, replacement, folderButton, replace, spinner])
        bar.spacing = Spacing.unit
        bar.translatesAutoresizingMaskIntoConstraints = false
        for (id, title, width) in [("place", "Where", 220.0), ("line", "Line", 60.0), ("text", "Text", 520.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.style = .fullWidth
        table.stripes = true
        table.centreText(rowHeight: 24)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openHit(_:))
        table.onReturn = { [weak self] in self?.openHit(nil) }
        table.setAccessibilityIdentifier("findFiles.results")
        table.setAccessibilityLabel("Matches")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        [bar, status, scroll].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.double),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            replacement.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            status.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: Spacing.unit),
            status.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.double),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: Spacing.unit),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    private var consoles: [(title: String, console: ConsoleViewController)] {
        (main?.model.allTabs ?? []).compactMap { tab in (tab.content as? ConsoleViewController).map { (tab.title, $0) } }
    }

    @objc func chooseFolder(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.use(folder: url)
        }
    }

    func use(folder url: URL) {
        folder = url
        folderButton.title = url.lastPathComponent
        folderButton.toolTip = "Searching the .sql files of " + url.path + ": click to choose another folder"
    }

    @objc func find(_ sender: Any?) {
        let text = field.stringValue
        search?.cancel()
        guard !text.isEmpty else { return }
        searched = text
        hits = consoles.flatMap { title, console in
            TextSearch.matches(of: text, in: console.text).map { Hit(title: title, console: console, match: $0) }
        }
        table.reloadData()
        spinner.startAnimation(nil)
        let folder = folder, open = Set(consoles.compactMap { $0.console.fileURL?.standardizedFileURL })
        search = Task { [weak self] in
            let found = await Task.detached { () -> [Hit] in
                guard let folder else { return [] }
                var hits: [Hit] = []
                for file in TextSearch.sqlFiles(in: folder) where !open.contains(file.standardizedFileURL) {
                    if Task.isCancelled { break }
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= Self.largestFile, let data = try? Data(contentsOf: file) else { continue }
                    let matches = TextSearch.matches(of: text, in: String(decoding: data, as: UTF8.self))
                    hits += matches.map { Hit(title: file.lastPathComponent, file: file, match: $0) }
                }
                return hits
            }.value
            guard let self, !Task.isCancelled else { return }
            hits += found
            table.reloadData()
            spinner.stopAnimation(nil)
            status.stringValue = hits.isEmpty ? "“\(text)” isn't in the tabs\(folder == nil ? "" : " or the folder's files")."
                : "\(hits.count.formatted()) match\(hits.count == 1 ? "" : "es"). Double-click one to go there."
            status.toolTip = status.stringValue
            announce(status.stringValue)
        }
    }

    @objc func openHit(_ sender: Any?) {
        guard let hit = hits[safe: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow], let main else { return }
        func show(_ console: ConsoleViewController) {
            _ = console.view
            console.editor.setSelectedRange(hit.match.range)
            console.editor.scrollRangeToVisible(hit.match.range)
            console.view.window?.makeFirstResponder(console.editor)
        }
        if let console = hit.console, let tab = main.model.allTabs.first(where: { $0.content === console }) {
            main.show(tab)
            show(console)
        } else if let file = hit.file {
            Task {
                await main.openFiles([file]).value
                if let console = main.selectedTab?.content as? ConsoleViewController, console.fileURL == file { show(console) }
            }
        }
    }

    /// Last match first, so the ranges before it stay right; one Undo step per tab.
    @objc func replaceInTabs(_ sender: Any?) {
        guard !searched.isEmpty, !AgentGuard.refuses("Replacing in query tabs is the person's: use type or set on a tab.") else { return }
        let new = replacement.stringValue
        var count = 0
        for (_, console) in consoles {
            _ = console.view  // a tab not shown yet has no editor
            let matches = TextSearch.matches(of: searched, in: console.text)
            guard !matches.isEmpty, let editor = console.editor else { continue }
            editor.undoManager?.beginUndoGrouping()
            for match in matches.reversed() where editor.shouldChangeText(in: match.range, replacementString: new) {
                editor.textStorage?.replaceCharacters(in: match.range, with: new)
                editor.didChangeText()
                count += 1
            }
            editor.undoManager?.endUndoGrouping()
        }
        find(nil)
        status.stringValue = "Replaced \(count.formatted()) in the query tabs. Undo there takes it back; nothing is saved until you save."
        status.toolTip = status.stringValue
    }

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let hit = hits[safe: row], let id = tableColumn?.identifier.rawValue else { return nil }
        let value = id == "place" ? hit.title : id == "line" ? "\(hit.match.line)" : hit.match.preview
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = id == "place" ? hit.file?.path ?? value : value
        field.font = id == "text" ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        return field
    }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        search?.cancel()
        answer(true)
    }
}

extension MainWindowController {
    @objc func findInFiles(_ sender: Any?) {
        if let tab = tabs.first(where: { $0.content is FindInFilesContent }) { return select(tab) }
        let content = FindInFilesContent(main: self)
        open(content, title: "Find in Tabs and Files", connection: nil)
        window?.makeFirstResponder(content.field)
    }
}
