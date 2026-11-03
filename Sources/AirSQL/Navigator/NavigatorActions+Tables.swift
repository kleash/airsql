import AirSQLCore
import AppKit

/// What a server offers for new databases and tables: its character sets and collations, and its storage engines.
struct ServerChoices {
    var charsets: [String] = []
    var collations: [String: [String]] = [:]
    var defaultCollation: [String: String] = [:]
    var serverCharset = ""
    var serverCollation = ""
    var engines: [String] = []

    static func read(_ open: OpenConnection) async throws -> ServerChoices {
        let session = try await open.connection.session(.schema)
        func rows(_ sql: String) async throws -> [[String?]] { try await session.rows(sql) }
        var choices = ServerChoices()
        for row in try await rows("SHOW CHARACTER SET") where row.count > 2 {
            guard let name = row[0] else { continue }
            choices.charsets.append(name)
            choices.defaultCollation[name] = row[2]
        }
        choices.charsets.sort()
        for row in try await rows("SHOW COLLATION") where row.count > 1 {
            guard let name = row[0], let charset = row[1] else { continue }
            choices.collations[charset, default: []].append(name)
        }
        for key in choices.collations.keys { choices.collations[key]?.sort() }
        if let row = try await rows("SELECT @@character_set_server, @@collation_server").first, row.count == 2 {
            choices.serverCharset = row[0] ?? ""
            choices.serverCollation = row[1] ?? ""
        }
        choices.engines = try await rows("SHOW ENGINES").compactMap { row in
            row.count > 1 && (row[1] == "YES" || row[1] == "DEFAULT") ? row[0] : nil
        }.sorted()
        return choices
    }
}

/// A character set pop-up and the collation pop-up that follows it.
@MainActor
final class CharsetPicker: NSObject {
    let charset: NSPopUpButton
    let collation: NSPopUpButton
    private let choices: ServerChoices
    private let keep: String?

    /// `keep`: a first item that changes nothing ("Don't change"); else the server's default is chosen.
    init(_ choices: ServerChoices, keep: String? = nil, id: String) {
        self.choices = choices
        self.keep = keep
        charset = popup((keep.map { [$0] } ?? []) + choices.charsets, selected: 0, id: id + ".charset",
                        tip: "The character set: which characters it can hold (utf8mb4 holds them all)", target: nil, action: nil)
        collation = popup([], selected: 0, id: id + ".collation", tip: "How text is compared and sorted", target: nil, action: nil)
        super.init()
        charset.target = self
        charset.action = #selector(charsetChosen)
        if keep == nil, let index = choices.charsets.firstIndex(of: choices.serverCharset) { charset.selectItem(at: index) }
        charsetChosen()
    }

    var chosenCharset: String? { charset.indexOfSelectedItem == 0 && keep != nil ? nil : charset.titleOfSelectedItem }
    var chosenCollation: String? { chosenCharset == nil ? nil : collation.titleOfSelectedItem }

    @objc private func charsetChosen() {
        collation.removeAllItems()
        guard let name = chosenCharset else {
            collation.addItem(withTitle: keep ?? "")
            collation.isEnabled = false
            return
        }
        collation.isEnabled = true
        collation.addItems(withTitles: choices.collations[name] ?? [])
        let preferred = name == choices.serverCharset ? choices.serverCollation : choices.defaultCollation[name] ?? ""
        collation.selectItem(withTitle: preferred)
    }
}

extension NavigatorActions {
    /// Reads what the server offers, then calls `body` on the main thread; says so if it can't.
    static func withChoices(_ open: OpenConnection, window: NSWindow?, _ body: @escaping (ServerChoices) -> Void) {
        Task {
            do {
                body(try await ServerChoices.read(open))
            } catch {
                showError((error as? AirSQLError)?.message ?? error.localizedDescription, title: "Couldn't read the server's options",
                          on: window)
            }
        }
    }

    static func newDatabase(on open: OpenConnection, window: NSWindow?) {
        guard let window else { return }
        withChoices(open, window: window) { choices in
            let name = textField("", placeholder: "Name", id: "newDatabase.name", tip: "The new database's name", width: 260)
            let picker = CharsetPicker(choices, id: "newDatabase")
            let form = Form()
            form.row("Name", [name])
            form.row("Character set", [picker.charset])
            form.row("Collation", [picker.collation])
            ask("New database", "Create a database on \(open.model?.connection(open.id)?.displayName ?? "the server").",
                field: form.finish(), action: "Create", on: window) {
                let text = name.stringValue.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return }
                let sql = NavigatorSQL.createDatabase(text, charset: picker.chosenCharset, collation: picker.chosenCollation)
                let request = SQLPreviewRequest(change: ChangeSQL(title: "Create database \(text)", statements: [sql],
                                                                  connection: open.id),
                                                heading: "", caption: "")
                confirmAndRun(request, on: open, window: window, ask: false, refreshing: [.database(text)])
            }
        }
    }

    static func copyTable(_ table: DatabaseObject, on open: OpenConnection, window: NSWindow?) {
        guard let window else { return }
        let databases = open.snapshot.databases.map(\.name)
        let target = popup(databases, selected: databases.firstIndex(of: table.database) ?? 0, id: "copyTable.database",
                           tip: "The database the copy goes in", target: nil, action: nil)
        let name = textField(table.name + "_copy", placeholder: "Name", id: "copyTable.name", tip: "The copy's name", width: 260)
        let rows = checkbox("Copy the rows", id: "copyTable.rows", tip: "Copy the rows too, not only the table's definition", on: true,
                            target: nil, action: nil)
        let condition = textField("", placeholder: "All rows", id: "copyTable.where",
                                  tip: "Only the rows where this holds, as SQL after WHERE (empty: every row)", width: 260)
        let form = Form()
        form.row("Into", [target])
        form.row("Name", [name])
        form.row("", [rows])
        form.row("Where", [condition], caption: "Indexes come along; foreign keys don't.")
        ask("Copy \(table.name)", "Copy \(table.database).\(table.name) to a new table.", field: form.finish(), action: "Next…",
            on: window) {
            let database = target.titleOfSelectedItem ?? table.database
            let copy = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard !copy.isEmpty else { return }
            let withRows = rows.state == .on, filter = condition.stringValue
            Task {
                // The columns to copy (generated ones are made again by the server): load them where they aren't yet.
                try? await open.schema.loadDetails([table.database])
                let columns = open.schema.snapshot.table(table.database, table.name)?.columns.filter { $0.generated == nil }.map(\.name)
                let statements = NavigatorSQL.copyTable(table, to: database, name: copy, columns: withRows ? columns ?? [] : nil,
                                                        where: filter)
                var request = SQLPreviewRequest(change: ChangeSQL(title: "Copy \(table.name)", statements: statements,
                                                                  connection: open.id),
                                                heading: "Copy \(table.name) to \(database).\(copy)?",
                                                caption: "The copy is made first, then the rows are copied into it.")
                request.actionTitle = "Copy"
                confirmAndRun(request, on: open, window: window, refreshing: [.table(database: database, name: copy)])
            }
        }
    }

    static func bulkEdit(_ tables: [DatabaseObject], on open: OpenConnection, window: NSWindow?) {
        guard let window, let first = tables.first else { return }
        withChoices(open, window: window) { choices in
            let keep = "Don’t change"
            let databases = open.snapshot.databases.map(\.name).filter { $0 != first.database }
            let move = popup(["Don’t move"] + databases, selected: 0, id: "bulk.database", tip: "Move the tables to this database",
                             target: nil, action: nil)
            let engine = popup([keep] + choices.engines, selected: 0, id: "bulk.engine", tip: "Change the tables' storage engine",
                               target: nil, action: nil)
            let picker = CharsetPicker(choices, keep: keep, id: "bulk")
            let form = Form()
            form.row("Move to", [move])
            form.row("Engine", [engine])
            form.row("Character set", [picker.charset])
            form.row("Collation", [picker.collation], caption: "Converts every text column too.")
            let what = tables.count == 1 ? first.name : "\(tables.count) tables"
            ask("Change \(what)", "Choose what to change; the next step shows the SQL.", field: form.finish(), action: "Next…",
                on: window) {
                var statements: [String] = []
                if engine.indexOfSelectedItem > 0, let name = engine.titleOfSelectedItem {
                    statements += tables.map { NavigatorSQL.changeEngine($0, to: name) }
                }
                if let charset = picker.chosenCharset, let collation = picker.chosenCollation {
                    statements += tables.map { NavigatorSQL.convert($0, charset: charset, collation: collation) }
                }
                var refreshed = tables.map(\.schemaObject)
                if move.indexOfSelectedItem > 0, let database = move.titleOfSelectedItem {
                    statements.append(NavigatorSQL.move(tables, to: database))
                    refreshed += tables.map { SchemaObject.table(database: database, name: $0.name) }
                }
                guard !statements.isEmpty else { return }
                var request = SQLPreviewRequest(change: ChangeSQL(title: "Change \(what)", statements: statements, connection: open.id),
                                                heading: "Change \(what)?",
                                                caption: "Each table is rebuilt; big tables take a while and are locked meanwhile.")
                request.actionTitle = "Change"
                confirmAndRun(request, on: open, window: window, refreshing: refreshed)
            }
        }
    }

    /// Runs a maintenance statement on the tables (asking first for those that change them) and shows what the server
    /// said in a tab.
    static func maintain(_ tables: [DatabaseObject], _ operation: Maintenance, on open: OpenConnection, main: MainWindowController?) {
        guard let main, !tables.isEmpty else { return }
        let what = tables.count == 1 ? tables[0].name : "\(tables.count) tables"
        var request = SQLPreviewRequest(change: ChangeSQL(title: "\(operation.title) \(what)",
                                                          statements: [NavigatorSQL.maintenance(operation, tables)], connection: open.id),
                                        heading: "\(operation.title) \(what)?", caption: NavigatorMenus.tips[operation] ?? "")
        request.actionTitle = operation.title
        confirmAndRun(request, on: open, window: main.window, ask: operation.changesTables, refreshing: []) { results in
            let lines = results.flatMap { $0 }.compactMap(\.rows).flatMap { store in
                (0..<store.rowCount).map { row in (0..<store.columns.count).map { store.display(row, $0) ?? "NULL" }.joined(separator: "   ") }
            }
            let content = TextContent(title: "\(operation.title) · \(what)", caption: "What the server said", text: lines.joined(separator: "\n"))
            main.open(content, title: "\(operation.title) · \(what)", connection: open.id)
        }
    }
}
