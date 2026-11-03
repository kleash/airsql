import AirSQLCore
import AppKit

/// Tools ▸ Generate Liquibase Changelog… (plan §2.9, mockups screen 9): a database's objects and rows as a formatted SQL
/// changelog, structure (DDL), rows (DML) or both, a changeset per object in an order that runs cleanly, previewed beside
/// the form as it will be written. Definitions are read once, off the main thread; rows are read when it is saved.
@MainActor
final class LiquibaseSheet: ToolSheet, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    /// An object of the database and what the changelog takes of it.
    final class Item {
        let object: LiquibaseSchema.Object
        var included = true
        var rows = false
        var filter = ""
        init(_ object: LiquibaseSchema.Object) { self.object = object }
        var isTable: Bool { object.kind == .table }
    }

    private let content = NSSegmentedControl(labels: ["DDL", "DML", "DDL + DML"], trackingMode: .selectOne, target: nil, action: nil)
    private let databaseMenu = popup([], selected: 0, id: "liquibase.database", tip: "Choose the database to write a changelog of",
                                     target: nil, action: nil)
    private let list = LiquibaseObjectTable()
    private let author = AirSQL.textField("", placeholder: "Your Mac account's name", id: "liquibase.author",
                                          tip: "Who the changesets are by, as Liquibase records it", width: 200)
    private let ids = AirSQL.textField("", placeholder: "{date}-{n}-{object}", id: "liquibase.ids",
                                       tip: "How changeset ids are made: {date}, {time}, {n} (001, 002…) and {object}", width: 200)
    private let rollback = checkbox("Add --rollback for DDL", id: "liquibase.rollback",
                                    tip: "Write the DROP that undoes each object, so liquibase rollback works", on: true, target: nil, action: nil)
    private let preconditions = checkbox("Skip what already exists", id: "liquibase.preconditions",
                                         tip: "Add preconditions that mark a changeset as ran when its object is already there", on: false,
                                         target: nil, action: nil)
    private let layoutMenu = popup(["One file", "A folder: a file per changeset"], selected: 0, id: "liquibase.layout",
                                   tip: "Write one changelog file, or a folder with a file per changeset and a master changelog",
                                   target: nil, action: nil)
    private let saveTo = label("", font: .systemFont(ofSize: 12.5), truncates: true)
    private let choose = button("Choose…", id: "liquibase.choose", tip: "Choose where to save the changelog", target: nil, action: nil)
    private let preview = NSTextView.scrollableTextView()
    private var schema: LiquibaseSchema?
    private var items: [Item] = []
    /// Where the changelog goes: a file, or a folder in the folder layout (Save to).
    private var url: URL
    /// Whether the person chose `url` (else it follows the database and the layout).
    private var chosen = false
    /// The database chosen first: the tree's, else the connection's own.
    private let preferred: String
    private var reading: Task<Void, Never>?

    init(model: AppModel, connection: SavedConnection, options: ConnectOptions, database: String? = nil) {
        preferred = database ?? connection.database
        url = (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("changelog.sql")
        super.init(model: model, connection: connection, options: options, width: 960, action: "Save Changelog",
                   actionTip: "Write the changelog to the place chosen in Save to")
        heading.stringValue = "Generate a Liquibase changelog"
        let settings = model.data.settings.liquibase
        author.stringValue = settings.author
        ids.stringValue = settings.ids
        rollback.state = settings.rollback ? .on : .off
        layoutMenu.selectItem(at: settings.layout == .folder ? 1 : 0)
        content.selectedSegment = 0
        content.setAccessibilityIdentifier("liquibase.content")
        content.toolTip = "Write the objects' structure (DDL), their rows (DML), or both"
        for control in [content, databaseMenu, rollback, preconditions, layoutMenu] as [NSControl] {
            control.target = self
            control.action = #selector(formChanged(_:))
        }
        author.delegate = self
        ids.delegate = self
        choose.target = self
        choose.action = #selector(chooseLocation(_:))
        list.onSpace = { [weak self] in self?.toggle(nil) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var helpPage: HelpPage { .liquibase }

    // MARK: Form

    override func makeForm() -> NSView {
        let top = Form()
        top.row("Content", [content])
        top.row("Database", [databaseMenu])
        databaseMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        let bottom = Form()
        bottom.row("Author", [author])
        bottom.row("Ids", [ids])
        bottom.row("Rollback", [rollback])
        bottom.row("Preconditions", [preconditions])
        bottom.row("Files", [layoutMenu])
        saveTo.setAccessibilityIdentifier("liquibase.saveTo")
        saveTo.widthAnchor.constraint(equalToConstant: 200).isActive = true
        bottom.row("Save to", [saveTo, choose])
        let left = NSStackView(views: [top.finish(), makeList(), bottom.finish()])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 10
        left.widthAnchor.constraint(equalToConstant: 420).isActive = true
        left.arrangedSubviews[1].widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        let columns = NSStackView(views: [left, makePreview()])
        columns.alignment = .top
        columns.spacing = 14
        columns.arrangedSubviews[1].heightAnchor.constraint(equalTo: left.heightAnchor).isActive = true
        showLocation()
        return columns
    }

    /// The objects with a box each to include them, and for tables whether their rows go too and a WHERE for them.
    private func makeList() -> NSView {
        for (id, title, width) in [("object", "Object", 180.0), ("rows", "Rows", 40.0), ("where", "WHERE", 110.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "object" ? 120 : width
            column.resizingMask = id == "object" ? .autoresizingMask : []
            column.headerToolTip = ["object": "Tick the objects whose structure the changelog creates",
                                    "rows": "Tick the tables whose rows the changelog inserts",
                                    "where": "Only the rows that match this condition (double-click to type one)"][id]
            list.addTableColumn(column)
        }
        list.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        list.rowHeight = 22
        list.style = .inset
        list.allowsMultipleSelection = true
        list.usesAlternatingRowBackgroundColors = false
        list.backgroundColor = .clear
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(toggle(_:))
        list.menu = NSMenu()
        list.menu?.delegate = self
        list.setAccessibilityIdentifier("liquibase.objects")
        list.toolTip = "Tick what the changelog takes; space ticks the selected rows"
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let box = SurfaceView(.content, radius: Radius.card, border: .separatorColor)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        scroll.pin(to: box, insets: .all(Radius.card))
        box.heightAnchor.constraint(equalToConstant: 230).isActive = true
        return box
    }

    private func makePreview() -> NSView {
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.borderType = .noBorder
        preview.drawsBackground = false
        let text = preview.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.setAccessibilityIdentifier("liquibase.preview")
        text.toolTip = "The changelog as it will be written; each table's rows are read when you save"
        let box = SurfaceView(.content, radius: Radius.control, border: .separatorColor)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(preview)
        preview.pin(to: box, insets: .all(Radius.control))
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        return box
    }

    override func extraButtons() -> [NSButton] {
        [button("Copy", id: "liquibase.copy", tip: "Copy the changelog as previewed (each table's rows are read when you save)",
                target: self, action: #selector(copyPreview(_:)))]
    }

    override func setFormEnabled(_ enabled: Bool) {
        for control in [content, databaseMenu, author, ids, rollback, preconditions, layoutMenu, choose] as [NSControl] {
            control.isEnabled = enabled
        }
        list.isEnabled = enabled
        list.reloadData()
    }

    // MARK: Loading

    override func load() {
        loading("Reading the databases of \(connection.displayName)…")
        let options = self.options
        Task {
            do {
                let session = DBConnection(options: options, role: .tools)
                _ = try await session.connect()
                let names = try await SQLExport.rows(session, PickerNode.databasesSQL).compactMap { $0[0] }
                await session.close()
                databaseMenu.removeAllItems()
                databaseMenu.addItems(withTitles: names)
                databaseMenu.selectItem(withTitle: preferred)
                if databaseMenu.indexOfSelectedItem < 0 { databaseMenu.selectItem(at: 0) }
                readSchema()
            } catch {
                failLoading("Can't read the databases: " + error.localizedDescription)
            }
        }
    }

    /// Reads the chosen database's definitions (SHOW CREATE of each object) on a session of its own.
    private func readSchema() {
        guard let name = databaseMenu.titleOfSelectedItem else { return failLoading("\(connection.displayName) has no database to read") }
        reading?.cancel()
        schema = nil
        items = []
        list.reloadData()
        loading("Reading the definitions in \(name)…")
        refresh()
        let options = self.options, updates = Throttle()
        reading = Task {
            let session = DBConnection(options: options, role: .tools)
            do {
                _ = try await session.connect()
                let read = try await LiquibaseSchema.read(name, from: session, progress: { done, total in
                    updates.send { self.loading("Reading the definitions in \(name)… \(done) of \(total)") }
                })
                updates.cancel()
                await session.close()
                guard !Task.isCancelled, databaseMenu.titleOfSelectedItem == name else { return }
                show(read)
            } catch {
                updates.cancel()
                await session.close()
                guard !Task.isCancelled else { return }
                failLoading("Can't read \(name): " + error.localizedDescription)
            }
        }
    }

    private func failLoading(_ message: String) {
        loading(nil)
        status.textColor = .statusBad
        status.stringValue = message
        updateRunButton()
    }

    /// Lists `read`'s objects (tables first, then views, routines, triggers, events), each ticked.
    func show(_ read: LiquibaseSchema) {
        schema = read
        heading.stringValue = "Generate a Liquibase changelog of \(read.database)"
        if databaseMenu.item(withTitle: read.database) == nil { databaseMenu.addItem(withTitle: read.database) }
        databaseMenu.selectItem(withTitle: read.database)
        let order = LiquibaseSchema.Object.Kind.allCases
        items = read.objects.sorted { ($0.kind == .sequence ? 9 : order.firstIndex(of: $0.kind) ?? 0, $0.name)
            < ($1.kind == .sequence ? 9 : order.firstIndex(of: $1.kind) ?? 0, $1.name) }.map(Item.init)
        for item in items where item.object.create.isEmpty { item.included = false }
        loading(nil)
        if !chosen { url = url.deletingLastPathComponent().appendingPathComponent(defaultName(read.database)) }
        showLocation()
        list.reloadData()
        refresh()
    }

    // MARK: Changes

    private var contentChoice: LiquibaseSchema.Content { [.structure, .data, .both][max(0, content.selectedSegment)] }

    @objc private func formChanged(_ sender: Any?) {
        if sender as? NSPopUpButton === databaseMenu { return readSchema() }
        model.data.settings.liquibase.rollback = rollback.state == .on
        let layout: LiquibaseSettings.Layout = layoutMenu.indexOfSelectedItem == 1 ? .folder : .oneFile
        if layout != model.data.settings.liquibase.layout {
            model.data.settings.liquibase.layout = layout
            if let schema, !chosen { url = url.deletingLastPathComponent().appendingPathComponent(defaultName(schema.database)) }
            showLocation()
        }
        // Rows want something to write: ticking DML with none chosen takes every included table's.
        if sender as? NSSegmentedControl === content, contentChoice != .structure, !items.contains(where: \.rows) {
            for item in items where item.isTable && item.included { item.rows = true }
        }
        list.reloadData()
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === author { model.data.settings.liquibase.author = author.stringValue }
        if field === ids { model.data.settings.liquibase.ids = ids.stringValue }
        if field === author || field === ids { refresh() }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field !== author, field !== ids else { return }
        let row = list.row(for: field)
        guard items.indices.contains(row) else { return }
        items[row].filter = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        refresh()
    }

    /// What the form asks for: the changelog's parts and the WHERE conditions by table.
    func plan() -> (pieces: [LiquibasePiece], filters: [String: String], tables: Int, rows: Int64) {
        guard let schema else { return ([], [:], 0, 0) }
        let content = contentChoice
        let picked = content == .data ? items.filter(\.isTable) : items.filter(\.included)
        let rows = content == .structure ? [] : items.filter { $0.isTable && $0.rows && (content == .data || $0.included) }
        let part = LiquibaseSchema(database: schema.database, objects: picked.map(\.object))
        let pieces = part.pieces(content, rows: Set(rows.map(\.object.name)), settings: model.data.settings.liquibase,
                                 preconditions: preconditions.state == .on)
        let filters = Dictionary(rows.filter { !$0.filter.isEmpty }.map { ($0.object.name, $0.filter) }) { first, _ in first }
        return (pieces, filters, rows.count, rows.reduce(0) { $0 + $1.object.rows })
    }

    /// The preview, the summary under it and the Save button, from the form.
    private func refresh() {
        let showsRows = contentChoice != .structure
        if list.tableColumns[1].isHidden == showsRows {
            list.tableColumns[1].isHidden = !showsRows
            list.tableColumns[2].isHidden = !showsRows
            list.sizeToFit()  // the object column takes the room the others leave
        }
        let (pieces, _, tables, rows) = plan()
        let shown = 150
        var text = schema.map { $0.preview(Array(pieces.prefix(shown)), settings: model.data.settings.liquibase) } ?? ""
        if pieces.count > shown { text += "\n-- … and \(pieces.count - shown) more changesets, written when you save\n" }
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        (preview.documentView as? NSTextView)?.textStorage?.setAttributedString(
            SQLPreviewSheet.coloured(text, font: font, noBackslashEscapes: false))
        if !running, schema != nil {
            let ddl = pieces.count - tables
            status.textColor = .secondaryLabelColor
            status.stringValue = (contentChoice == .data ? "" : ObjectPicker.count(ddl, "changeset"))
                + (tables == 0 ? "" : (contentChoice == .data ? "" : " · ") + "rows of " + ObjectPicker.count(tables, "table")
                   + " (≈\(ObjectPicker.compact(rows)) rows)")
        }
        updateRunButton()
    }

    override func updateRunButton() {
        guard !running else { return }
        let (pieces, _, _, _) = plan()
        let reason = schema == nil ? "AirSQL is still reading the database"
            : pieces.isEmpty ? (contentChoice == .structure ? "Tick the objects to write" : "Tick Rows for the tables whose rows to write")
            : nil
        runButton.isEnabled = reason == nil
        runButton.toolTip = reason ?? "Write the changelog to the place chosen in Save to"
    }

    // MARK: Where it goes

    private func defaultName(_ database: String) -> String {
        let name = ExportSheet.fileName(database + "-changelog", gzip: false)
        return model.data.settings.liquibase.layout == .folder ? String(name.dropLast(4)) : name
    }

    private func showLocation() {
        saveTo.stringValue = SettingsPaneController.shown(url) + (model.data.settings.liquibase.layout == .folder ? "/" : "")
        saveTo.toolTip = saveTo.stringValue
    }

    @objc private func chooseLocation(_ sender: Any?) {
        guard let window else { return }
        let panel: NSSavePanel
        if model.data.settings.liquibase.layout == .folder {
            let open = NSOpenPanel()
            open.canChooseDirectories = true
            open.canChooseFiles = false
            open.canCreateDirectories = true
            open.prompt = "Choose"
            open.message = "Choose the folder for the changesets' files and \(Liquibase.masterName)."
            panel = open
        } else {
            panel = NSSavePanel()
            panel.nameFieldStringValue = url.lastPathComponent
            panel.message = "Choose where to save the changelog."
        }
        panel.directoryURL = url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let picked = panel.url else { return }
            self.url = picked
            self.chosen = true
            self.showLocation()
        }
    }

    override func close() {
        reading?.cancel()  // a database still being read is let go
        super.close()
    }

    @objc private func copyPreview(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((preview.documentView as? NSTextView)?.string ?? "", forType: .string)
    }

    // MARK: Running

    override func run() {
        guard let schema else { return }
        // The gate (plan §2.8): files on this Mac are the person's.
        guard !AgentGuard.refuses("A changelog is a file on this Mac: only the person at the Mac can save one. Leave the "
                                  + "sheet for them.") else { return }
        let (pieces, filters, _, _) = plan()
        let settings = model.data.settings.liquibase, url = self.url, options = self.options
        let needsRows = pieces.contains { if case .rows = $0 { return true } else { return false } }
        let cancellation = begin("Writing a Liquibase changelog of \(schema.database)")
        let updates = Throttle()
        Task {
            let session = needsRows ? DBConnection(options: options, role: .tools) : nil
            do {
                if let session { _ = try await session.connect() }
                let outcome = try await schema.write(pieces, settings: settings, filters: filters, to: url, from: session,
                                                     cancellation: cancellation) { state in
                    updates.send {
                        self.progress(state.table.isEmpty ? "Writing changesets…"
                                       : "Reading the rows of \(state.table) · \(ObjectPicker.compact(state.rows)) rows",
                                       done: Int64(state.changesets), total: Int64(state.total))
                    }
                }
                updates.cancel()
                await session?.close()
                finish("Saved " + ObjectPicker.count(outcome.changesets, "changeset") + (outcome.rows > 0 ? " with \(outcome.rows) rows" : "")
                       + " in \(url.lastPathComponent)" + (settings.layout == .folder ? " (start from \(Liquibase.masterName))." : "."),
                       failed: false)
            } catch {
                updates.cancel()
                await session?.close()
                finish(error.localizedDescription, failed: true)
            }
        }
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row], enabled = list.isEnabled
        switch tableColumn?.identifier.rawValue {
        case "rows":
            guard item.isTable else { return nil }
            let box = checkbox("", id: "liquibase.rows." + item.object.name, tip: "Insert the rows of \(item.object.name)",
                               on: item.rows, target: self, action: #selector(rowsClicked(_:)))
            box.isEnabled = enabled
            box.setAccessibilityLabel("Rows of \(item.object.name)")
            return box
        case "where":
            guard item.isTable else { return nil }
            let field = AirSQL.textField(item.filter, placeholder: "every row", id: "liquibase.where." + item.object.name,
                                         tip: "Only the rows of \(item.object.name) that match this condition, such as active = 1")
            field.isBordered = false
            field.drawsBackground = false
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.isEnabled = enabled && item.rows
            field.delegate = self
            // Centred in the row, as the names beside it are.
            let cell = NSTableCellView()
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        default:
            let cell = tableView.makeView(withIdentifier: PickerCell.id, owner: nil) as? PickerCell ?? PickerCell()
            let readable = !item.object.create.isEmpty
            cell.name.stringValue = item.object.name
            cell.name.toolTip = item.object.name
            cell.name.textColor = enabled && readable ? .labelColor : .disabledControlTextColor
            cell.box.state = item.included ? .on : .off
            cell.box.isEnabled = enabled && readable && contentChoice != .data
            cell.box.target = self
            cell.box.action = #selector(boxClicked(_:))
            cell.box.setAccessibilityLabel(item.object.name)
            cell.box.setAccessibilityIdentifier("liquibase.include." + item.object.name)
            cell.box.toolTip = !readable ? "This login can't read the definition of \(item.object.name)"
                : contentChoice == .data ? "DML writes rows only: tick Rows" : "Create \(item.object.name) in the changelog"
            cell.detail.stringValue = item.isTable ? ObjectPicker.compact(item.object.rows) + " rows" : item.object.kind.rawValue
            cell.detail.toolTip = item.isTable ? "About \(item.object.rows) rows" : nil
            return cell
        }
    }

    @objc private func boxClicked(_ sender: NSButton) {
        let row = list.row(for: sender)
        guard items.indices.contains(row) else { return }
        include([items[row]], !items[row].included)
    }

    @objc private func rowsClicked(_ sender: NSButton) {
        let row = list.row(for: sender)
        guard items.indices.contains(row) else { return }
        withRows([items[row]], sender.state == .on)
    }

    private func include(_ chosen: [Item], _ on: Bool) {
        for item in chosen where !item.object.create.isEmpty {
            item.included = on
            if !on, contentChoice == .both { item.rows = false }
        }
        list.reloadData()
        refresh()
    }

    private func withRows(_ chosen: [Item], _ on: Bool) {
        for item in chosen where item.isTable {
            item.rows = on
            if on, contentChoice == .both { item.included = true }  // the rows need their table
        }
        list.reloadData()
        refresh()
    }

    /// The rows a command acts on: the clicked row and, when it is selected, the whole selection.
    private var targetItems: [Item] {
        let clicked = list.clickedRow
        let rows = clicked >= 0 && !list.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : list.selectedRowIndexes
        return rows.filter { items.indices.contains($0) }.map { items[$0] }
    }

    /// Double-click and space: tick or untick (rows, for DML).
    @objc private func toggle(_ sender: Any?) {
        let chosen = targetItems
        guard list.isEnabled, !chosen.isEmpty else { return }
        if contentChoice == .data {
            withRows(chosen, !chosen.allSatisfy(\.rows))
        } else {
            include(chosen, !chosen.allSatisfy(\.included))
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let showsRows = contentChoice != .structure
        for (title, action, tip, shown) in [
            ("Include", #selector(includeChosen(_:)), "Tick the selected objects", contentChoice != .data),
            ("Leave Out", #selector(leaveOutChosen(_:)), "Untick the selected objects", contentChoice != .data),
            ("Include All", #selector(includeAll(_:)), "Tick every object", contentChoice != .data),
            ("Include None", #selector(includeNone(_:)), "Untick every object", contentChoice != .data),
            ("Insert Rows", #selector(rowsOfChosen(_:)), "Insert the rows of the selected tables", showsRows),
            ("No Rows", #selector(noRowsOfChosen(_:)), "Leave the rows of the selected tables out", showsRows),
        ] where shown {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.toolTip = tip
            item.isEnabled = list.isEnabled && schema != nil
            menu.addItem(item)
        }
    }

    @objc private func includeChosen(_ sender: Any?) { include(targetItems, true) }
    @objc private func leaveOutChosen(_ sender: Any?) { include(targetItems, false) }
    @objc private func includeAll(_ sender: Any?) { include(items, true) }
    @objc private func includeNone(_ sender: Any?) { include(items, false) }
    @objc private func rowsOfChosen(_ sender: Any?) { withRows(targetItems, true) }
    @objc private func noRowsOfChosen(_ sender: Any?) { withRows(targetItems, false) }
}

/// The object list: space ticks the selected rows.
final class LiquibaseObjectTable: NSTableView {
    var onSpace: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            onSpace()
        } else {
            super.keyDown(with: event)
        }
    }
}
