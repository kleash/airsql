import AirSQLCore
import AppKit

/// Copy to Another Server… (scope: copy straight to another server): the databases and tables to copy, the connection
/// and database they go to, structure and data, and whether tables already there are replaced (destructive: off unless
/// ticked, and the SQL preview asks first). AirSQL reads with a session of its own and writes through another on the
/// target, as its built-in export would write a file.
@MainActor
final class CopySheet: ToolSheet, NSTextFieldDelegate {
    private let picker = ObjectPicker()
    private let targetMenu = popup([], selected: 0, id: "copy.target", tip: "Choose the connection to copy to", target: nil,
                                   action: nil)
    private let databaseField = AirSQL.textField("", placeholder: "Database name", id: "copy.database",
                                                 tip: "The database the copy goes into on the other server (made if it isn't there)")
    private let content = popup(DumpRequest.Content.allCases.map(\.title), selected: 0, id: "copy.content",
                                tip: "Choose what to copy: the tables' structure, their rows, or both", target: nil, action: nil)
    private let replace = checkbox("Replace tables that are there (DROP TABLE first)", id: "copy.replace",
                                   tip: "Drop the other server's tables of the same name before copying: their rows are lost",
                                   on: false, target: nil, action: nil)
    private let objects = checkbox("Views, routines, triggers and events", id: "copy.objects",
                                   tip: "Copy the databases' views, procedures, functions, triggers and events too", on: true,
                                   target: nil, action: nil)
    private var summary: NSTextView?
    private var targets: [SavedConnection] = []
    private var filledName = ""

    init(model: AppModel, connection: SavedConnection, options: ConnectOptions) {
        super.init(model: model, connection: connection, options: options, width: 780, action: "Copy",
                   actionTip: "Copy the ticked databases and tables to the other server")
        heading.stringValue = "Copy from \(connection.displayName) to another server"
        for control in [targetMenu, content, replace, objects] as [NSControl] {
            control.target = self
            control.action = #selector(formChanged(_:))
        }
        databaseField.delegate = self
        picker.onChange = { [weak self] in self?.formChanged(nil) }
        targets = model.data.connections.filter { $0.id != connection.id }
        targetMenu.removeAllItems()
        for target in targets {
            targetMenu.addItem(withTitle: target.displayName)
            targetMenu.lastItem?.toolTip = "Copy to \(target.displayName)"
        }
        replace.contentTintColor = .statusBad
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeForm() -> NSView {
        let form = Form()
        form.row("To", [targetMenu])
        form.row("Database", [databaseField])
        form.row("Content", [content])
        let options = NSStackView(views: [replace, objects])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 4
        form.row("Options", [options]).yPlacement = .top
        let grid = form.finish()
        grid.setContentHuggingPriority(.defaultHigh, for: .vertical)  // its rows stay together at the top
        databaseField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        // Long connection names are shortened in the menu's button, whole in the menu.
        targetMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        let columns = NSStackView(views: [picker.view(height: 250), grid])
        columns.alignment = .top
        columns.spacing = 14
        columns.arrangedSubviews[0].widthAnchor.constraint(equalToConstant: 260).isActive = true
        return columns
    }

    override func makeCodeBox() -> NSView? {
        let (box, text) = codeBox(id: "copy.summary", tip: "What the other server is sent, in this order", lines: 5)
        summary = text
        return box
    }

    override func setFormEnabled(_ enabled: Bool) {
        for control in [targetMenu, databaseField, content, replace, objects] as [NSControl] { control.isEnabled = enabled }
        picker.isEnabled = enabled
        let why = "It is running: wait for it, or Stop it"
        targetMenu.toolTip = enabled ? "Choose the connection to copy to" : why
        databaseField.toolTip = enabled ? "The database the copy goes into on the other server (made if it isn't there)" : why
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
                let tables = try await SQLExport.rows(session, PickerNode.listSQL)
                await session.close()
                show(databases: PickerNode.databases(names, tables: tables))
            } catch {
                loading(nil)
                status.textColor = .statusBad
                status.stringValue = "Can't read the databases: " + error.localizedDescription
                updateRunButton()
            }
        }
    }

    func show(databases: [PickerNode]) {
        let current = connection.database.isEmpty ? (databases.count == 1 ? databases.first?.name : nil) : connection.database
        if let node = databases.first(where: { $0.name == current }) { picker.include(node, true) }
        picker.show(databases, expanding: current)
        loading(nil)
        formChanged(nil)
    }

    // MARK: Changes

    private var target: SavedConnection? {
        let index = targetMenu.indexOfSelectedItem
        return index >= 0 && index < targets.count ? targets[index] : nil
    }

    private var request: DumpRequest? {
        let included = picker.included
        guard !included.isEmpty else { return nil }
        var request = DumpRequest(databases: included.map(\.database))
        if included.count == 1, !included[0].all { request.tables = included[0].tables }
        request.content = DumpRequest.Content.allCases[max(0, content.indexOfSelectedItem)]
        request.addDropTable = replace.state == .on && request.content != .data
        request.objects = objects.state == .on
        return request
    }

    /// The database each copied database goes into: the field's name for one, their own names for several.
    private var names: [String: String] {
        let included = picker.included.map(\.database)
        let typed = databaseField.stringValue.trimmingCharacters(in: .whitespaces)
        return Dictionary(uniqueKeysWithValues: included.map { ($0, included.count == 1 && !typed.isEmpty ? typed : $0) })
    }

    func controlTextDidChange(_ notification: Notification) { updateSummary() }

    @objc private func formChanged(_ sender: Any?) {
        let included = picker.included
        databaseField.isEnabled = !running && included.count <= 1
        // The field follows the ticked database until the person types a name of their own.
        let typed = databaseField.stringValue
        if typed.isEmpty || typed == filledName {
            filledName = included.count == 1 ? included[0].database : ""
            databaseField.stringValue = filledName
        }
        databaseField.placeholderString = included.count > 1 ? "Each keeps its name" : "Database name"
        replace.isEnabled = !running && content.indexOfSelectedItem != 2
        updateSummary()
    }

    private func updateSummary() {
        guard let request else {
            summary?.string = "Tick the databases or tables to copy."
            updateRunButton()
            return
        }
        var lines: [String] = []
        for database in request.databases {
            let name = names[database] ?? database
            if request.content != .data { lines.append("CREATE DATABASE IF NOT EXISTS \(SQLQuote.identifier(name)) …;") }
            lines.append("USE \(SQLQuote.identifier(name));")
            let tables = picker.databases.first { $0.name == database }?.tables.filter { $0.included && !$0.isView } ?? []
            let rows = tables.reduce(Int64(0)) { $0 + $1.rows }
            if request.addDropTable { lines.append("DROP TABLE IF EXISTS … (\(ObjectPicker.count(tables.count, "table")));") }
            if request.content != .data { lines.append("CREATE TABLE … (\(ObjectPicker.count(tables.count, "table")));") }
            if request.content != .structure { lines.append("INSERT INTO … (about \(ObjectPicker.compact(rows)) rows);") }
        }
        summary?.string = lines.joined(separator: "\n")
        updateRunButton()
    }

    override func updateRunButton() {
        guard !running else { return }
        var reason: String?
        if picker.databases.isEmpty {
            reason = "AirSQL couldn't read the databases yet"
        } else if target == nil {
            reason = "Add the other server as a connection first"
        } else if request == nil {
            reason = "Tick the databases or tables to copy"
        } else if picker.included.count > 1 && picker.included.contains(where: { !$0.all }) {
            reason = "Several databases are copied whole: tick all of each one's tables, or pick tables of one database"
        } else if names.values.contains(where: \.isEmpty) {
            reason = "Type the name of the database to copy into"
        } else if let target, target.readOnly {
            reason = "\(target.displayName) is read-only: turn that off in its settings to copy to it"
        } else if let target, target.route != .direct {
            reason = "Copies reach SSH and proxy routes once AirSQL has connected through them"
        } else if let target, target.host == connection.host, target.port == connection.port, target.socket == connection.socket,
                  names.contains(where: { $0.key == $0.value }) {
            reason = "That is this server: type another database name to copy into"
        }
        runButton.isEnabled = reason == nil
        runButton.toolTip = reason ?? "Copy the ticked databases and tables to the other server"
    }

    // MARK: Running

    override func run() {
        guard let request, let target, let window else { return }
        let names = self.names, options = self.options
        Task {
            guard let targetOptions = await ToolsResponder.options(for: target, model: model, on: window) else { return }
            let destination = names.values.sorted().joined(separator: ", ")
            var preview = SQLPreviewRequest(change: ChangeSQL(title: "Copy to \(target.displayName)",
                                                              statements: summary?.string.components(separatedBy: "\n") ?? [],
                                                              connection: target.id),
                                            heading: "Copy to \(destination) on \(target.displayName)?",
                                            caption: "AirSQL reads from \(connection.displayName) and runs these on "
                                                + "\(target.displayName). If a statement fails, what ran before it stays.")
            preview.actionTitle = "Copy"
            if request.addDropTable {
                preview.destructive = true
                preview.warnings = ["Tables of the same name on \(target.displayName) are dropped first: their rows are lost."]
            }
            // The other server is written to: the preview asks when that drops tables or the server is production.
            guard request.addDropTable || target.colour == .production else {
                start(request, names: names, source: options, target: targetOptions, to: target)
                return
            }
            SQLPreviewSheet.show(preview, connection: target, on: window) { result in
                if result.approved { self.start(request, names: names, source: options, target: targetOptions, to: target) }
            }
        }
    }

    private func start(_ request: DumpRequest, names: [String: String], source: ConnectOptions, target: ConnectOptions,
                       to saved: SavedConnection) {
        let cancellation = begin("Copying to \(saved.displayName)")
        let updates = Throttle()
        Task {
            let reader = DBConnection(options: source, role: .tools), writer = DBConnection(options: target, role: .tools)
            do {
                _ = try await reader.connect()
                _ = try await writer.connect()
                // Another saved connection may reach this very server (another name for the host): never onto itself.
                let identity = "SELECT @@hostname, @@port, @@datadir"
                if try await SQLExport.rows(reader, identity) == SQLExport.rows(writer, identity),
                   names.contains(where: { $0.key == $0.value }) {
                    throw AirSQLError(.other, "\(saved.displayName) is this same server: copy into another database.")
                }
                try await SQLExport.run(request, from: reader, into: SQLServerSink(writer), names: names,
                                        cancellation: cancellation) { done in
                    updates.send {
                        let rows = ObjectPicker.compact(done.rows) + (done.totalRows > 0 ? " of ≈" + ObjectPicker.compact(done.totalRows) : "")
                        self.progress("Copying \(done.table) · \(rows) rows", done: done.rows, total: done.totalRows > 0 ? done.totalRows : nil)
                    }
                }
                updates.cancel()
                finish("Copied to \(names.values.sorted().joined(separator: ", ")) on \(saved.displayName).", failed: false)
            } catch {
                updates.cancel()
                finish(cancellation.isCancelled ? "Stopped. What was copied before stays." : error.localizedDescription, failed: true)
            }
            await reader.close()
            await writer.close()
        }
    }
}
