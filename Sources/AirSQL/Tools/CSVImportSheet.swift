import AirSQLCore
import AppKit

/// Import CSV… (scope: CSV import with column mapping): a CSV file into a table, each of the table's columns taking a
/// field of the file or its default; the separator guessed, a first row of names, empty fields as NULL. The rows go in
/// one transaction: if one fails, none stay.
@MainActor
final class CSVImportSheet: ToolSheet {
    private let fileLabel = label("No file chosen", font: .systemFont(ofSize: 12.5), color: .secondaryLabelColor, truncates: true)
    private let fileInfo = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor)
    private let choose = button("Choose…", id: "csv.choose", tip: "Choose the CSV file to import", target: nil, action: nil)
    private let databaseMenu = popup([], selected: 0, id: "csv.database", tip: "Choose the database of the table", target: nil, action: nil)
    private let tableMenu = popup([], selected: 0, id: "csv.table", tip: "Choose the table the rows go into", target: nil, action: nil)
    private let separatorMenu = popup(["Comma", "Semicolon", "Tab", "Bar"], selected: 0, id: "csv.separator",
                                      tip: "Choose the character between fields (guessed from the file)", target: nil, action: nil)
    private let header = checkbox("The first row names the columns", id: "csv.header",
                                  tip: "Take the first row as the fields' names, not as data", on: true, target: nil, action: nil)
    private let emptyIsNull = checkbox("Empty fields become NULL", id: "csv.emptyIsNull",
                                       tip: "Store an empty field as NULL rather than as empty text", on: true, target: nil, action: nil)
    private let mappingGrid = NSGridView(numberOfColumns: 3, rows: 0)
    private static let separators: [UInt8] = [0x2C, 0x3B, 0x09, 0x7C]
    private var session: DBConnection?
    private var databases: [PickerNode] = []
    private var columns: [(name: String, type: String)] = []
    private var mapping: [NSPopUpButton] = []
    private var records: [[String]] = []
    private var file: URL?

    init(model: AppModel, connection: SavedConnection, options: ConnectOptions) {
        super.init(model: model, connection: connection, options: options, width: 720, action: "Import",
                   actionTip: "Add the file's rows to the table, all or none")
        heading.stringValue = "Import CSV into a table of \(connection.displayName)"
        choose.target = self
        choose.action = #selector(chooseFile(_:))
        databaseMenu.target = self
        databaseMenu.action = #selector(databaseChanged(_:))
        tableMenu.target = self
        tableMenu.action = #selector(tableChanged(_:))
        for control in [separatorMenu, header] as [NSControl] {
            control.target = self
            control.action = #selector(formatChanged(_:))
        }
        fileLabel.setAccessibilityIdentifier("csv.file")
        mappingGrid.translatesAutoresizingMaskIntoConstraints = false
        mappingGrid.rowSpacing = 6
        mappingGrid.columnSpacing = 10
        mappingGrid.rowAlignment = .firstBaseline
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeForm() -> NSView {
        let form = Form()
        form.row("File", [fileLabel, choose])
        form.grid.addRow(with: [NSGridCell.emptyContentView, fileInfo]).topPadding = -4
        form.row("Table", [databaseMenu, tableMenu])
        let format = NSStackView(views: [separatorMenu, header])
        format.spacing = Spacing.double
        format.alignment = .firstBaseline
        form.row("Format", [format])
        form.row("", [emptyIsNull])
        let grid = form.finish()
        fileLabel.widthAnchor.constraint(equalToConstant: 420).isActive = true
        // Long names are shortened in the menus' buttons, whole in the menus.
        databaseMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        tableMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
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
        let box = SurfaceView(.content, radius: Radius.card, border: .separatorColor)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        scroll.pin(to: box, insets: .all(Radius.card))
        box.heightAnchor.constraint(equalToConstant: 200).isActive = true
        box.setAccessibilityIdentifier("csv.mapping")
        let title = label("Each column takes:", font: .systemFont(ofSize: 12, weight: .semibold))
        let stack = NSStackView(views: [grid, title, box])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.unit
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    override func setFormEnabled(_ enabled: Bool) {
        for control in [choose, databaseMenu, tableMenu, separatorMenu, header, emptyIsNull] + mapping as [NSControl] {
            control.isEnabled = enabled
        }
    }

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
                let names = try await SQLExport.rows(session, PickerNode.databasesSQL).compactMap { $0[0] }
                let tables = try await SQLExport.rows(session, PickerNode.listSQL)
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
        self.databases = databases.filter { $0.tables.contains { !$0.isView } }
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
        tableChanged(nil)
    }

    @objc private func tableChanged(_ sender: Any?) {
        guard let database = databaseMenu.titleOfSelectedItem, let table = tableMenu.titleOfSelectedItem, let session else {
            show(columns: [])
            return
        }
        Task {
            let quote = { SQLQuote.string($0, noBackslashEscapes: session.noBackslashEscapes) }
            let rows = (try? await SQLExport.rows(session, "SELECT COLUMN_NAME, COLUMN_TYPE, EXTRA FROM information_schema.COLUMNS "
                + "WHERE TABLE_SCHEMA = \(quote(database)) AND TABLE_NAME = \(quote(table)) ORDER BY ORDINAL_POSITION")) ?? []
            show(columns: rows.filter { !SQLExport.isGenerated($0[2] ?? "") }.map { ($0[0] ?? "", $0[1] ?? "") })
        }
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
        panel.message = "Choose a CSV file."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.use(url)
        }
    }

    /// Takes `url` as the file, guessing its separator.
    func use(_ url: URL, separator: UInt8? = nil) {
        file = url
        fileLabel.stringValue = SettingsPaneController.shown(url)
        fileLabel.toolTip = url.path
        fileLabel.textColor = .labelColor
        Task {
            do {
                let (guessed, records) = try await Task.detached { try CSVImport.preview(url, separator: separator) }.value
                let size = await Task.detached { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }.value
                self.records = records
                separatorMenu.selectItem(at: Self.separators.firstIndex(of: guessed) ?? 0)
                fileInfo.stringValue = Self.bytes(size) + " · " + ObjectPicker.count(records.first?.count ?? 0, "field") + " a row"
                fileInfo.textColor = .secondaryLabelColor
            } catch {
                records = []
                fileInfo.stringValue = "Can't read it: " + error.localizedDescription
                fileInfo.textColor = .statusBad
            }
            remap()
        }
    }

    @objc private func formatChanged(_ sender: Any?) {
        if sender as? NSPopUpButton === separatorMenu, let file {
            use(file, separator: Self.separators[max(0, separatorMenu.indexOfSelectedItem)])
        } else {
            remap()
        }
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
        let sample = header.state == .on ? records.dropFirst().first : records.first
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
            mappingGrid.addRow(with: [label(tableMenu.numberOfItems == 0 ? "This database has no tables to import into."
                                            : "Choose a table.", color: .secondaryLabelColor)])
        }
        updateRunButton()
    }

    private func showSample(_ menu: NSPopUpButton, _ value: NSTextField, sample: [String]?) {
        let field = menu.indexOfSelectedItem - 1
        let text = field >= 0 ? sample?[safe: field] ?? "" : ""
        value.stringValue = field < 0 ? "" : text.isEmpty && emptyIsNull.state == .on ? "NULL" : text
        value.toolTip = value.stringValue.isEmpty ? nil : "From the first row: " + value.stringValue
    }

    @objc private func mappingChanged(_ sender: NSPopUpButton) {
        if let row = mapping.firstIndex(of: sender), let value = mappingGrid.cell(atColumnIndex: 2, rowIndex: row).contentView as? NSTextField {
            showSample(sender, value, sample: header.state == .on ? records.dropFirst().first : records.first)
        }
        updateRunButton()
    }

    override func updateRunButton() {
        guard !running else { return }
        var reason: String?
        if file == nil {
            reason = "Choose the CSV file first"
        } else if records.isEmpty {
            reason = "The file has no rows AirSQL can read"
        } else if columns.isEmpty {
            reason = "Choose the table the rows go into"
        } else if mapping.allSatisfy({ $0.indexOfSelectedItem == 0 }) {
            reason = "Choose the field at least one column takes"
        }
        runButton.isEnabled = reason == nil
        runButton.toolTip = reason ?? "Add the file's rows to \(tableMenu.titleOfSelectedItem ?? "the table"), all or none"
    }

    // MARK: Running

    override func run() {
        guard let file, let session, let window, let database = databaseMenu.titleOfSelectedItem,
              let table = tableMenu.titleOfSelectedItem else { return }
        var options = CSVImport.Options()
        options.separator = Self.separators[max(0, separatorMenu.indexOfSelectedItem)]
        options.header = header.state == .on
        options.emptyIsNull = emptyIsNull.state == .on
        let names = columns.map(\.name), fields = mapping.map { $0.indexOfSelectedItem > 0 ? $0.indexOfSelectedItem - 1 : nil }
        let start = { [self] in
            let cancellation = begin("Importing \(file.lastPathComponent) into \(table)")
            let updates = Throttle()
            Task {
                do {
                    let rows = try await CSVImport.run(file, options: options, into: session, database: database, table: table,
                                                       columns: names, mapping: fields, cancellation: cancellation) { state in
                        updates.send {
                            self.progress("Imported \(ObjectPicker.compact(state.rows)) rows · \(Self.bytes(state.bytes)) of "
                                          + Self.bytes(state.size), done: state.bytes, total: state.size)
                        }
                    }
                    updates.cancel()
                    finish("Imported \(rows) rows into \(table).", failed: false)
                } catch {
                    updates.cancel()
                    finish((cancellation.isCancelled ? "Stopped." : error.localizedDescription) + " Nothing of this file was kept.",
                           failed: true)
                }
            }
        }
        // Production asks, and so does what an agent set off (plan §2.8).
        let agent = AgentGate.agent != nil && model.data.safety(for: connection).askBeforeAgentChanges
        guard agent || connection.colour == .production else {
            start()
            return
        }
        let used = zip(names, fields).compactMap { name, field in field.map { _ in SQLQuote.identifier(name) } }
        var request = SQLPreviewRequest(change: ChangeSQL(title: "Import \(file.lastPathComponent)",
                                                          statements: ["INSERT INTO \(SQLQuote.identifier(database, table)) ("
                                                                       + used.joined(separator: ", ") + ") VALUES …"],
                                                          connection: connection.id),
                                        heading: "Import \(file.lastPathComponent) into \(table)?",
                                        caption: "The file's rows are added in one transaction: if one fails, none stay.")
        request.actionTitle = "Import"
        SQLPreviewSheet.show(request, connection: connection, on: window) { result in
            if result.approved { start() }
        }
    }
}
