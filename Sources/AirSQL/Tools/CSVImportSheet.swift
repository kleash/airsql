import AirSQLCore
import AppKit

/// Import File… (scope: CSV import with column mapping): a delimited text file, an Excel workbook, JSON, the clipboard
/// or a result into a table: an existing one, each column taking a field or its default, or a new one, whose CREATE TABLE
/// is proposed from every value and can be edited. The separator is guessed; the format, encoding, duplicates and what
/// to do with refused rows are chosen here, with the first rows shown as they'll be read. The rows go in one transaction:
/// if one fails, none stay, unless refused rows are to be skipped into a file.
@MainActor
final class CSVImportSheet: ToolSheet, NSTextFieldDelegate, NSTextViewDelegate, NSTableViewDataSource {
    private let fileLabel = label("No file chosen", font: .systemFont(ofSize: 12.5), color: .secondaryLabelColor, truncates: true)
    private let fileInfo = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor)
    private let choose = button("Choose…", id: "csv.choose", tip: "Choose the file to import: CSV or other text, Excel (.xlsx) or JSON",
                                target: nil, action: nil)
    private let paste = button("Paste", id: "csv.paste", tip: "Import the rows on the clipboard instead of a file", target: nil, action: nil)
    private let databaseMenu = popup([], selected: 0, id: "csv.database", tip: "Choose the database of the table", target: nil, action: nil)
    private let tableMenu = popup([], selected: 0, id: "csv.table", tip: "Choose the table the rows go into, or make a new one", target: nil, action: nil)
    private let newName = AirSQL.textField("", placeholder: "Name of the new table", id: "csv.newTable", tip: "Type the new table's name", width: 200)
    private let separatorMenu = popup(["Comma", "Semicolon", "Tab", "Bar", "Other"], selected: 0, id: "csv.separator",
                                      tip: "Choose the character between fields (guessed from the file)", target: nil, action: nil)
    private let otherSeparator = AirSQL.textField("", placeholder: "One character", id: "csv.otherSeparator",
                                                  tip: "Type the character between fields", width: 90)
    private let quoteMenu = popup(["Double quotes", "Single quotes", "No quotes"], selected: 0, id: "csv.quote",
                                  tip: "Choose what encloses a field that holds separators or line breaks", target: nil, action: nil)
    private let encodingMenu = popup(CSVImportSheet.encodings.map(\.title), selected: 0, id: "csv.encoding",
                                     tip: "Choose the file's text encoding (Automatic reads UTF-8, UTF-16 with a BOM, then Windows-1252)",
                                     target: nil, action: nil)
    private let header = checkbox("The first row names the columns", id: "csv.header",
                                  tip: "Take the first row as the fields' names, not as data", on: true, target: nil, action: nil)
    private let skipRows = AirSQL.textField("0", placeholder: "0", id: "csv.skip", tip: "Type how many rows to skip at the start, before the names", width: 44)
    private let trim = checkbox("Trim spaces", id: "csv.trim", tip: "Remove the spaces around fields without quotes", on: false,
                                target: nil, action: nil)
    private let backslash = checkbox("Backslash escapes", id: "csv.backslash", tip: "Read a backslash inside quotes as escaping the next character",
                                     on: false, target: nil, action: nil)
    private let emptyIsNull = checkbox("Empty fields become NULL", id: "csv.emptyIsNull",
                                       tip: "Store an empty field as NULL rather than as empty text", on: true, target: nil, action: nil)
    private let decimalComma = checkbox("Numbers use a decimal comma", id: "csv.decimalComma",
                                        tip: "Read 1.234,56 as 1234.56 in number columns", on: false, target: nil, action: nil)
    private let duplicates = popup(["Stop at a duplicate", "Skip duplicates (INSERT IGNORE)", "Replace duplicates (REPLACE)"], selected: 0,
                                   id: "csv.duplicates", tip: "Choose what happens to a row whose key the table already has",
                                   target: nil, action: nil)
    private let emptyFirst = checkbox("Delete the table's rows first", id: "csv.emptyFirst",
                                      tip: "Delete every row of the table before importing: if the import fails, they come back",
                                      on: false, target: nil, action: nil)
    private let keepGoing = checkbox("Skip rows the server refuses", id: "csv.keepGoing",
                                     tip: "Keep the good rows, and write the refused ones with the reason to a file in Downloads",
                                     on: false, target: nil, action: nil)
    private lazy var reveal = button("Show Skipped Rows", id: "csv.reveal", tip: "Show the file of refused rows in Finder", target: self,
                                     action: #selector(showSkipped(_:)))
    private let mappingGrid = NSGridView(numberOfColumns: 3, rows: 0)
    private let mappingBox = SurfaceView(.content, radius: Radius.card, border: .separatorColor)
    private let mappingTitle = label("Each column takes:", font: .systemFont(ofSize: 12, weight: .semibold))
    private var ddlBox = NSView()
    private var ddl: NSTextView?
    private let preview = NSTableView()
    private static let separators: [UInt8] = [0x2C, 0x3B, 0x09, 0x7C]
    private static let quotes: [UInt8?] = [0x22, 0x27, nil]
    private static let encodings: [(title: String, encoding: String.Encoding?)] = [
        ("Automatic", nil), ("UTF-8", .utf8), ("UTF-16 Little Endian", .utf16LittleEndian), ("UTF-16 Big Endian", .utf16BigEndian),
        ("Windows-1252", .windowsCP1252), ("ISO Latin 1", .isoLatin1), ("Mac Roman", .macOSRoman), ("Windows-1250", .windowsCP1250),
        ("Windows-1251", .windowsCP1251), ("Shift JIS", .shiftJIS), ("EUC-JP", .japaneseEUC),
    ]
    private static let newTable = "New Table…"
    private var session: DBConnection?
    private var databases: [PickerNode] = []
    private var columns: [(name: String, type: String)] = []
    private var mapping: [NSPopUpButton] = []
    private var records: [[String]] = []
    private var source: ImportSource?
    private var detected: [ImportDetect.Column] = []
    private var detection: Cancellation?
    /// The person has typed in the CREATE TABLE: a new name no longer rewrites it.
    private var ddlEdited = false
    /// The file of the last run's refused rows.
    private var skipped: URL?

    init(model: AppModel, connection: SavedConnection, options: ConnectOptions) {
        super.init(model: model, connection: connection, options: options, width: 760, action: "Import",
                   actionTip: "Add the file's rows to the table, all or none")
        heading.stringValue = "Import into a table of \(connection.displayName)"
        choose.target = self
        choose.action = #selector(chooseFile(_:))
        paste.target = self
        paste.action = #selector(pasteRows(_:))
        databaseMenu.target = self
        databaseMenu.action = #selector(databaseChanged(_:))
        tableMenu.target = self
        tableMenu.action = #selector(tableChanged(_:))
        for control in [separatorMenu, quoteMenu, encodingMenu, header, trim, backslash, decimalComma, emptyIsNull] as [NSControl] {
            control.target = self
            control.action = #selector(formatChanged(_:))
        }
        for control in [duplicates, emptyFirst, keepGoing] as [NSControl] {
            control.target = self
            control.action = #selector(optionChanged(_:))
        }
        newName.delegate = self
        otherSeparator.delegate = self
        skipRows.delegate = self
        otherSeparator.isHidden = true
        newName.isHidden = true
        reveal.isHidden = true
        fileLabel.setAccessibilityIdentifier("csv.file")
        fileLabel.lineBreakMode = .byTruncatingMiddle  // a path: its file name stays in sight
        mappingGrid.translatesAutoresizingMaskIntoConstraints = false
        mappingGrid.rowSpacing = 6
        mappingGrid.columnSpacing = 10
        mappingGrid.rowAlignment = .firstBaseline
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var writes: Bool { true }

    override func makeForm() -> NSView {
        let form = Form()
        form.row("Source", [fileLabel, choose, paste])
        form.grid.addRow(with: [NSGridCell.emptyContentView, fileInfo]).topPadding = -4
        form.row("Table", [databaseMenu, tableMenu, newName])
        form.row("Format", [separatorMenu, otherSeparator, quoteMenu, encodingMenu])
        form.row("", [header, label("Skip rows:", font: .systemFont(ofSize: 12.5)), skipRows, trim, backslash])
        form.row("Values", [emptyIsNull, decimalComma])
        form.row("Rows", [duplicates, emptyFirst, keepGoing])
        let grid = form.finish()
        fileLabel.widthAnchor.constraint(equalToConstant: 440).isActive = true
        // Long names are shortened in the menus' buttons, whole in the menus.
        databaseMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        tableMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(mappingGrid)
        // Pinned on three sides: the columns keep to their content rather than spread over the width.
        NSLayoutConstraint.activate([
            mappingGrid.topAnchor.constraint(equalTo: document.topAnchor, constant: Spacing.unit),
            mappingGrid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Spacing.unit),
            mappingGrid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Spacing.unit),
            mappingGrid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -Spacing.unit),
        ])
        scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        mappingBox.translatesAutoresizingMaskIntoConstraints = false
        mappingBox.addSubview(scroll)
        scroll.pin(to: mappingBox, insets: .all(Radius.card))
        mappingBox.heightAnchor.constraint(equalToConstant: 160).isActive = true
        mappingBox.setAccessibilityIdentifier("csv.mapping")
        let (box, text) = codeBox(id: "csv.ddl", tip: "Edit the new table's definition: AirSQL proposed it from every value of the file", lines: 9)
        text.isEditable = true
        text.delegate = self
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        ddl = text
        ddlBox = box
        ddlBox.isHidden = true
        preview.dataSource = self
        preview.usesAlternatingRowBackgroundColors = true
        preview.columnAutoresizingStyle = .noColumnAutoresizing
        preview.allowsColumnReordering = false
        preview.backgroundColor = .clear
        preview.setAccessibilityIdentifier("csv.preview")
        preview.toolTip = "The first rows, as they'll be read"
        let rows = NSScrollView()
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.documentView = preview
        rows.hasVerticalScroller = true
        rows.hasHorizontalScroller = true
        rows.drawsBackground = false
        let rowsBox = SurfaceView(.content, radius: Radius.card, border: .separatorColor)
        rowsBox.translatesAutoresizingMaskIntoConstraints = false
        rowsBox.addSubview(rows)
        rows.pin(to: rowsBox, insets: .all(Radius.card))
        rowsBox.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let stack = NSStackView(views: [grid, mappingTitle, mappingBox, ddlBox, rowsBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.unit
        for view in [mappingBox, ddlBox, rowsBox] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    override func extraButtons() -> [NSButton] { [reveal] }

    /// The controls' own tooltips, while running says why they are off.
    private var ownTips: [NSControl: String] = [:]

    private var formControls: [NSControl] {
        [choose, paste, databaseMenu, tableMenu, newName, separatorMenu, otherSeparator, quoteMenu, encodingMenu, header, skipRows, trim,
         backslash, emptyIsNull, decimalComma, duplicates, emptyFirst, keepGoing]
    }

    override func setFormEnabled(_ enabled: Bool) {
        for control in formControls + mapping as [NSControl] {
            control.isEnabled = enabled
            if enabled {
                if let tip = ownTips[control] { control.toolTip = tip.isEmpty ? nil : tip }
            } else {
                if ownTips[control] == nil { ownTips[control] = control.toolTip ?? "" }
                control.toolTip = "It is running: wait for it, or Stop it"
            }
        }
        ddl?.isEditable = enabled
        if enabled {
            ownTips = [:]
            fitControls()
        }
    }

    /// Text formats' controls are off for what has its own; a new table has no rows to delete.
    private func fitControls() {
        guard !running else { return }
        let delimited = isDelimited
        for control in [separatorMenu, otherSeparator, quoteMenu, encodingMenu, trim, backslash] as [NSControl] {
            control.isEnabled = delimited
        }
        header.isEnabled = !hasNames
        skipRows.isEnabled = !hasNames
        if hasNames { header.state = .on }
        emptyFirst.isEnabled = !isNew
        if isNew { emptyFirst.state = .off }
        emptyFirst.toolTip = isNew ? "A new table has no rows to delete"
            : "Delete every row of the table before importing: if the import fails, they come back"
    }

    private func isRows(_ source: ImportSource) -> Bool {
        if case .rows = source { return true }
        return false
    }

    /// JSON's keys and a result's columns always come first.
    private var hasNames: Bool { source.map { $0.kind == .json || isRows($0) } ?? false }

    private var isDelimited: Bool { source.map { $0.kind == .delimited && !isRows($0) } ?? true }

    private var isNew: Bool { tableMenu.indexOfSelectedItem == 0 }

    override func close() {
        let session = self.session
        Task { await session?.close() }
        super.close()
    }

    // MARK: Loading

    override func load() {
        loading("Reading the tables of \(connection.displayName)…")
        let options = self.options
        Task {
            do {
                let session = DBConnection(options: options, role: .tools)
                _ = try await session.connect()
                self.session = session
                let names = try await session.rows(PickerNode.databasesSQL).compactMap { $0[0] }
                let tables = try await session.rows(PickerNode.listSQL)
                show(databases: PickerNode.databases(names, tables: tables))
            } catch {
                loading(nil)
                status.textColor = .statusBad
                status.stringValue = "Can't read the tables: " + error.localizedDescription
                updateRunButton()
            }
        }
    }

    /// Fills the table menus; the connection's database first.
    func show(databases: [PickerNode]) {
        self.databases = databases
        databaseMenu.removeAllItems()
        databaseMenu.addItems(withTitles: self.databases.map(\.name))
        for item in databaseMenu.itemArray { item.toolTip = "Import into a table of \(item.title)" }
        databaseMenu.selectItem(withTitle: connection.database)
        if databaseMenu.indexOfSelectedItem < 0, databaseMenu.numberOfItems > 0 { databaseMenu.selectItem(at: 0) }
        loading(nil)
        databaseChanged(nil)
    }

    @objc private func databaseChanged(_ sender: Any?) {
        let tables = databases.first { $0.name == databaseMenu.titleOfSelectedItem }?.tables.filter { !$0.isView } ?? []
        tableMenu.removeAllItems()
        tableMenu.addItems(withTitles: tables.map(\.name))
        for item in tableMenu.itemArray { item.toolTip = "Import into \(item.title)" }
        // First, so a database of hundreds of tables doesn't hide it past the menu's end.
        if !tables.isEmpty { tableMenu.menu?.insertItem(.separator(), at: 0) }
        tableMenu.menu?.insertItem(withTitle: Self.newTable, action: nil, keyEquivalent: "", at: 0).toolTip = "Make a new table from the file's columns"
        tableMenu.selectItem(at: tables.isEmpty ? 0 : 2)
        tableChanged(nil)
    }

    @objc private func tableChanged(_ sender: Any?) {
        newName.isHidden = !isNew
        mappingBox.isHidden = isNew
        mappingTitle.stringValue = isNew ? "The new table (edit it as you like):" : "Each column takes:"
        ddlBox.isHidden = !isNew
        fitControls()
        if isNew {
            show(columns: [])
            detect()
            return
        }
        guard let database = databaseMenu.titleOfSelectedItem, let table = tableMenu.titleOfSelectedItem, let session else {
            show(columns: [])
            return
        }
        Task {
            let rows = (try? await Self.columns(of: table, in: database, session: session)) ?? []
            show(columns: rows)
        }
    }

    /// The table's columns but its generated ones, which take no value.
    private static func columns(of table: String, in database: String, session: DBConnection) async throws -> [(name: String, type: String)] {
        let quote = { SQLQuote.string($0, noBackslashEscapes: session.noBackslashEscapes) }
        let rows = try await session.rows("SELECT COLUMN_NAME, COLUMN_TYPE, EXTRA FROM information_schema.COLUMNS "
            + "WHERE TABLE_SCHEMA = \(quote(database)) AND TABLE_NAME = \(quote(table)) ORDER BY ORDINAL_POSITION")
        return rows.filter { !SQLExport.isGenerated($0[2] ?? "") }.map { ($0[0] ?? "", $0[1] ?? "") }
    }

    /// The mapping rows for the table's columns (generated ones left out: they take no value).
    func show(columns: [(name: String, type: String)]) {
        self.columns = columns
        remap()
    }

    // MARK: The file

    @objc private func chooseFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a CSV or other text file, an Excel workbook (.xlsx) or JSON."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.use(url)
        }
    }

    /// The clipboard's text is the person's: an agent can't send it to a server (plan §2.8).
    @objc func pasteRows(_ sender: Any?) {
        guard !AgentGuard.refuses("Only the person at the Mac can import what is on the clipboard.") else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            fileInfo.stringValue = "The clipboard has no text to import."
            fileInfo.textColor = .statusBad
            return
        }
        use(text: text)
    }

    /// Takes `url` as the source, guessing its separator.
    func use(_ url: URL) {
        fileLabel.stringValue = SettingsPaneController.shown(url)
        fileLabel.toolTip = url.path
        take(.file(url), named: url.deletingPathExtension().lastPathComponent)
    }

    /// Takes text at hand, such as the clipboard's, as the source, guessing its separator.
    func use(text: String) {
        fileLabel.stringValue = "The clipboard"
        fileLabel.toolTip = "The text on the clipboard when you pressed Paste"
        take(.text(text), named: "imported_rows")
    }

    /// Takes rows at hand (a result: names first) as the source.
    func use(rows: [[String?]], title: String) {
        fileLabel.stringValue = title
        fileLabel.toolTip = title
        take(.rows(rows), named: "result_copy")
    }

    private func take(_ source: ImportSource, named name: String) {
        self.source = source
        fileLabel.textColor = .labelColor
        newName.stringValue = String(name.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(60))
        ddlEdited = false
        fitControls()
        read(guess: isDelimited)
    }

    /// Reads the first rows with the form's format, then shows them and the mapping or the new table.
    private func read(guess: Bool = false) {
        guard let source else { return }
        let options = formOptions
        Task {
            do {
                let (guessed, records) = try await Task.detached { try CSVImport.preview(source, options: options, guess: guess) }.value
                var size = Int64(0)
                if case .file(let url) = source {
                    size = await Task.detached { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }.value
                }
                self.records = records
                if guess { separatorMenu.selectItem(at: Self.separators.firstIndex(of: guessed) ?? 0) }
                fileInfo.stringValue = (size > 0 ? Self.bytes(size) + " · " : "") + ObjectPicker.count(records.first?.count ?? 0, "field") + " a row"
                fileInfo.textColor = .secondaryLabelColor
            } catch {
                records = []
                fileInfo.stringValue = "Can't read it: " + error.localizedDescription
                fileInfo.textColor = .statusBad
            }
            showPreview()
            remap()
            detect()
        }
    }

    /// The form's format, values and rows.
    private var formOptions: CSVImport.Options {
        var options = CSVImport.Options()
        options.separator = separatorByte ?? 0x2C
        options.quote = Self.quotes[max(0, quoteMenu.indexOfSelectedItem)]
        options.escape = backslash.state == .on ? 0x5C : nil
        options.encoding = Self.encodings[max(0, encodingMenu.indexOfSelectedItem)].encoding
        options.trim = trim.state == .on
        options.skipRecords = hasNames ? 0 : max(0, skipRows.integerValue)
        options.header = header.state == .on
        options.emptyIsNull = emptyIsNull.state == .on
        options.decimalComma = decimalComma.state == .on
        if let source, isRows(source) { options.hexIsBinary = true }
        options.duplicates = CSVImport.Duplicates(rawValue: duplicates.indexOfSelectedItem) ?? .stop
        options.emptyFirst = emptyFirst.state == .on
        return options
    }

    /// The separator chosen; nil while Other holds anything but one plain character.
    private var separatorByte: UInt8? {
        let index = max(0, separatorMenu.indexOfSelectedItem)
        if index < Self.separators.count { return Self.separators[index] }
        let typed = Array(otherSeparator.stringValue.utf8)
        return typed.count == 1 && typed[0] != 0x0A && typed[0] != 0x0D ? typed[0] : nil
    }

    @objc private func formatChanged(_ sender: Any?) {
        otherSeparator.isHidden = separatorMenu.indexOfSelectedItem < Self.separators.count
        ddlEdited = false
        fitControls()
        read()
    }

    @objc private func optionChanged(_ sender: Any?) { updateRunButton() }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === newName {
            proposeTable()
            updateRunButton()
        } else if separatorByte != nil {
            read()
        } else {
            updateRunButton()
        }
    }

    func textDidChange(_ notification: Notification) {
        ddlEdited = true
        updateRunButton()
    }

    // MARK: The new table

    /// Reads the whole source for the new table's columns, off the main thread.
    private func detect() {
        guard isNew, let source else { return updateRunButton() }
        detection?.cancel()
        let cancellation = Cancellation(), options = formOptions
        detection = cancellation
        loading("Reading every value to choose the columns…")
        Task {
            do {
                let found = try await Task.detached { try ImportDetect.columns(source, options: options, cancellation: cancellation) }.value
                guard detection === cancellation else { return }
                detected = found
                loading(nil)
                proposeTable()
            } catch {
                guard detection === cancellation else { return }
                loading(nil)
                status.textColor = .statusBad
                status.stringValue = "Can't read it: " + error.localizedDescription
            }
            updateRunButton()
        }
    }

    private func proposeTable() {
        guard !ddlEdited, let database = databaseMenu.titleOfSelectedItem else { return }
        ddl?.string = detected.isEmpty ? "" : ImportDetect.createTable(database: database, table: newName.stringValue, columns: detected)
    }

    /// The fields of a table just made: by name, or by position when the columns have kept their number.
    private func fields(of made: [(name: String, type: String)]) -> [Int?] {
        made.enumerated().map { index, column in
            detected.firstIndex { $0.name.lowercased() == column.name.lowercased() } ?? (made.count == detected.count ? index : nil)
        }
    }

    // MARK: The first rows

    private var shownRecords: [[String]] { header.state == .on ? Array(records.dropFirst()) : records }

    private func showPreview() {
        for column in preview.tableColumns { preview.removeTableColumn(column) }
        for (index, name) in fieldNames.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            column.title = name
            column.width = 130
            preview.addTableColumn(column)
        }
        preview.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shownRecords.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let index = tableColumn.flatMap({ Int($0.identifier.rawValue) }) else { return nil }
        let value = shownRecords[safe: row]?[safe: index] ?? ""
        return value == ImportSource.null || (value.isEmpty && emptyIsNull.state == .on) ? "NULL" : value
    }

    /// The fields as the menus name them: by the first row's names, or by number.
    private var fieldNames: [String] {
        let count = records.map(\.count).max() ?? 0
        return (0..<count).map { index in
            let name = header.state == .on ? records.first?[safe: index]?.trimmingCharacters(in: .whitespaces) ?? "" : ""
            return name.isEmpty ? "Field \(index + 1)" : "\(name) (field \(index + 1))"
        }
    }

    /// One row per column: its name and type, the field it takes (by name, else by position without names), a sample.
    private func remap() {
        // A grid keeps the views of rows it removes: they go first.
        while mappingGrid.numberOfRows > 0 {
            for column in 0..<mappingGrid.numberOfColumns {
                mappingGrid.cell(atColumnIndex: column, rowIndex: 0).contentView?.removeFromSuperview()
            }
            mappingGrid.removeRow(at: 0)
        }
        mapping = []
        let names = fieldNames
        let firstNames = header.state == .on ? (records.first ?? []).map { $0.trimmingCharacters(in: .whitespaces).lowercased() } : []
        let sample = shownRecords.first
        for (index, column) in columns.enumerated() {
            let menu = popup(["Leave out (its default)"] + names, selected: 0, id: "csv.map." + column.name,
                             tip: "Choose the field of the file \(column.name) takes, or leave it to its default", target: self,
                             action: #selector(mappingChanged(_:)))
            let match = firstNames.firstIndex(of: column.name.lowercased()) ?? (firstNames.isEmpty && index < names.count ? index : nil)
            menu.selectItem(at: match.map { $0 + 1 } ?? 0)
            mapping.append(menu)
            let name = label(column.name, truncates: true)
            name.toolTip = column.name + " · " + column.type
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
            let value = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
            value.setAccessibilityIdentifier("csv.sample." + column.name)
            mappingGrid.addRow(with: [name, menu, value])
            showSample(menu, value, sample: sample)
        }
        if columns.isEmpty {
            mappingGrid.addRow(with: [label("Choose a table.", color: .secondaryLabelColor)])
        }
        updateRunButton()
    }

    private func showSample(_ menu: NSPopUpButton, _ value: NSTextField, sample: [String]?) {
        let field = menu.indexOfSelectedItem - 1
        let text = field >= 0 ? sample?[safe: field] ?? "" : ""
        value.stringValue = field < 0 ? "" : text == ImportSource.null || (text.isEmpty && emptyIsNull.state == .on) ? "NULL" : text
        value.toolTip = value.stringValue.isEmpty ? nil : "From the first row: " + value.stringValue
    }

    @objc private func mappingChanged(_ sender: NSPopUpButton) {
        if let row = mapping.firstIndex(of: sender), let value = mappingGrid.cell(atColumnIndex: 2, rowIndex: row).contentView as? NSTextField {
            showSample(sender, value, sample: shownRecords.first)
        }
        updateRunButton()
    }

    override func updateRunButton() {
        guard !running else { return }
        var reason: String?
        if connection.readOnly {
            reason = "\(connection.displayName) is read-only: turn that off in the connection's settings to write to it"
        } else if source == nil {
            reason = "Choose a file first, or Paste the rows"
        } else if separatorByte == nil {
            reason = "Type one plain character as the separator"
        } else if records.isEmpty {
            reason = "The source has no rows AirSQL can read"
        } else if isNew {
            if ImportDetect.createdTable(ddl?.string ?? "") == nil {
                reason = "The new table needs one CREATE TABLE statement with its columns"
            }
        } else if columns.isEmpty {
            reason = "Choose the table the rows go into"
        } else if mapping.allSatisfy({ $0.indexOfSelectedItem == 0 }) {
            reason = "Choose the field at least one column takes"
        }
        runButton.isEnabled = reason == nil
        runButton.toolTip = reason ?? "Add the rows to \(isNew ? "the new table" : tableMenu.titleOfSelectedItem ?? "the table")"
            + (keepGoing.state == .on ? ", skipping those the server refuses" : ", all or none")
    }

    /// A new file in Downloads for the refused rows.
    private func rejectsFile() -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let stamp = ExportSheet.fileName("skipped", gzip: false).replacingOccurrences(of: ".sql", with: ".csv")
        return folder.appendingPathComponent(SQLFolderSink.fileName(newName.stringValue + "-" + stamp))
    }

    @objc private func showSkipped(_ sender: Any?) {
        if let skipped { NSWorkspace.shared.activateFileViewerSelecting([skipped]) }
    }

    // MARK: Running

    override func run() {
        guard let source, let session, window != nil, let chosenDatabase = databaseMenu.titleOfSelectedItem,
              let chosenTable = tableMenu.titleOfSelectedItem else { return }
        // The gate (plan §2.8): a file on this Mac is the person's to write.
        if keepGoing.state == .on, AgentGuard.refuses("Skipping refused rows writes a file on this Mac: only the person at the Mac can "
                                                      + "start that. Untick it, or leave the sheet for them.") { return }
        let create = isNew ? ddl?.string : nil
        let made = create.flatMap(ImportDetect.createdTable)
        if create != nil && made == nil { return }
        let database = made?.database ?? chosenDatabase, table = made?.table ?? chosenTable
        var options = formOptions
        if keepGoing.state == .on { options.rejects = rejectsFile() }
        let what = fileLabel.stringValue
        let names = columns.map(\.name), fields = mapping.map { $0.indexOfSelectedItem > 0 ? $0.indexOfSelectedItem - 1 : nil }
        let types = columns
        var rollsBack = true
        let start = { [self] in
            reveal.isHidden = true
            let cancellation = begin("Importing \(what) into \(table)")
            let updates = Throttle()
            Task {
                var created = false
                do {
                    var names = names, fields = fields, types = types
                    if let create {
                        _ = try await session.query("USE " + SQLQuote.identifier(database))
                        _ = try await session.query(create)
                        created = true
                        types = try await Self.columns(of: table, in: database, session: session)
                        names = types.map(\.name)
                        fields = self.fields(of: types)
                    }
                    options.binaryColumns = Set(types.filter { $0.type.lowercased().contains("binary") || $0.type.lowercased().contains("blob") }.map(\.name))
                    let numbers = ["tinyint", "smallint", "mediumint", "int", "bigint", "dec", "numeric", "float", "double"]
                    options.numberColumns = Set(types.filter { column in numbers.contains { column.type.lowercased().hasPrefix($0) } }.map(\.name))
                    let done = try await CSVImport.run(source, options: options, into: session, database: database, table: table,
                                                       columns: names, mapping: fields, cancellation: cancellation) { state in
                        updates.send {
                            self.progress("Imported \(ObjectPicker.compact(state.rows)) rows · \(Self.bytes(state.bytes)) of "
                                          + Self.bytes(state.size), done: state.bytes, total: state.size)
                        }
                    }
                    updates.cancel()
                    if done.rejected > 0, let url = options.rejects {
                        skipped = url
                        reveal.isHidden = false
                    }
                    finish("Imported \(done.rows) rows into \(table)." + done.note, failed: false)
                } catch {
                    updates.cancel()
                    finish((cancellation.isCancelled ? "Stopped." : error.localizedDescription)
                           + (created ? " The table \(table) stays, empty." : rollsBack ? " Nothing of this import was kept."
                              : " \(table) can't roll back: what happened before the failure stays."), failed: true)
                }
                if created {
                    detection = nil
                    model.openConnection(connection.id)?.refresh([.table(database: database, name: table)])
                }
            }
        }
        // Production asks, and so does what an agent set off (plan §2.8), and deleting the table's rows.
        let agent = AgentGate.agent != nil && model.data.safety(for: connection).askBeforeAgentChanges
        let target = SQLQuote.identifier(database, table)
        let used = zip(names, fields).compactMap { name, field in field.map { _ in SQLQuote.identifier(name) } }
        var statements = create.map { [$0] } ?? []
        if options.emptyFirst { statements.append("DELETE FROM " + target) }
        statements.append("\(options.duplicates.verb) \(target) " + (used.isEmpty ? "" : "(" + used.joined(separator: ", ") + ") ") + "VALUES …")
        let emptyFirst = options.emptyFirst, literal = { SQLQuote.string($0, noBackslashEscapes: session.noBackslashEscapes) }
        Task { [self] in
            let engine = create != nil ? nil : try? await session.rows("SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = "
                                                                       + literal(database) + " AND TABLE_NAME = " + literal(table)).first?.first ?? nil
            let warnings = Self.warnings(table: table, engine: engine, emptyFirst: emptyFirst)
            rollsBack = warnings.count == (emptyFirst ? 1 : 0)
            guard agent || emptyFirst || !rollsBack || connection.isProduction else { return start() }
            confirm(statements, what: what, table: table, warnings: warnings, destructive: emptyFirst, then: start)
        }
    }

    /// What the preview warns of: the rows deleted first, and an engine that can't undo the import when a row fails.
    static func warnings(table: String, engine: String?, emptyFirst: Bool) -> [String] {
        (emptyFirst ? ["Every row \(table) has now is deleted first."] : [])
            + (engine.map { !TableEditing.transactional.contains($0.lowercased()) } == true
                ? ["\(table) uses \(engine ?? ""), which can't roll back: if a row fails, " + (emptyFirst ? "its old rows are gone and " : "")
                    + "the rows before it stay."] : [])
    }

    private func confirm(_ statements: [String], what: String, table: String, warnings: [String], destructive: Bool, then start: @escaping () -> Void) {
        guard let window else { return }
        var request = SQLPreviewRequest(change: ChangeSQL(title: "Import \(what)", statements: statements, connection: connection.id),
                                        heading: "Import \(what) into \(table)?",
                                        caption: keepGoing.state == .on ? "Rows the server refuses are skipped; the rest are kept."
                                            : "The rows are added in one transaction: if one fails, none stay.")
        request.actionTitle = "Import"
        request.destructive = destructive
        request.warnings = warnings
        SQLPreviewSheet.show(request, connection: connection, on: window) { result in
            if result.approved { start() }
        }
    }
}
