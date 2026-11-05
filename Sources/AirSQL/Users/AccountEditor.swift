import AirSQLCore
import AppKit

/// The sheet that makes or changes an account: its login, limits, privileges and roles. Next shows the SQL; nothing runs
/// before that. A password lives in its secure fields and the statements made from them, and goes with the sheet.
@MainActor
final class AccountEditor: NSWindowController, NSTextFieldDelegate {
    private let old: ServerAccount?
    private var draft: ServerAccount
    private let base: AccountGrants
    private let content: UsersContent
    /// The roles on offer; nil: the server has none.
    private let roles: [AccountGrants.Role]?
    private let plugins: [String]
    let tree: GrantsTree
    let tabs = NSTabView()
    private let sections = NSSegmentedControl()
    let user = AirSQL.textField("", placeholder: "Name", id: "users.name", tip: "Type the name it logs in with", width: 260)
    let host = AirSQL.textField("", placeholder: "Host", id: "users.host", tip: "Type where it may log in from: a name, an address, or % for anywhere", width: 260)
    let password = NSSecureTextField()
    let repeated = NSSecureTextField()
    private lazy var pluginPopup = popup(["Server's default"] + pluginNames, selected: 0, id: "users.plugin",
                                         tip: "Choose how the server checks who it is", target: self, action: #selector(pluginChosen(_:)))
    private(set) lazy var generate = button("Generate", id: "users.generate", tip: "Fill both fields with a new random password", target: self,
                                            action: #selector(generatePassword(_:)))
    private(set) lazy var copyPassword = button("Copy", id: "users.copyPassword", tip: "Generate a password first", target: self,
                                                action: #selector(copyGenerated(_:)))
    private lazy var locked = checkbox("Locked: it can't log in", id: "users.locked", tip: "Keep the account but refuse its logins", on: draft.locked,
                                       target: nil, action: nil)
    private lazy var expired = checkbox("Password expired: it must change it at its next login", id: "users.expired",
                                        tip: "Make it choose a new password when it next logs in", on: draft.expired, target: nil, action: nil)
    private let queries = AirSQL.textField("", placeholder: "0", id: "users.maxQueries", tip: "Type how many statements an hour it may run; 0 is no limit", width: 90)
    private let updates = AirSQL.textField("", placeholder: "0", id: "users.maxUpdates", tip: "Type how many changes an hour it may make; 0 is no limit", width: 90)
    private let connections = AirSQL.textField("", placeholder: "0", id: "users.maxConnections", tip: "Type how many times an hour it may log in; 0 is no limit", width: 90)
    private let simultaneous = AirSQL.textField("", placeholder: "0", id: "users.maxSimultaneous", tip: "Type how many connections it may hold at once; 0 is the server's limit", width: 90)
    private lazy var tlsPopup = popup(["Not required", "Any TLS connection", "A valid client certificate", "These details"],
                                      selected: ServerAccount.TLS.Kind.allCases.firstIndex(of: draft.tls.kind) ?? 0, id: "users.tls",
                                      tip: "Choose what it must show of TLS to log in", target: self, action: #selector(tlsChosen(_:)))
    private let cipher = AirSQL.textField("", placeholder: "Cipher", id: "users.cipher", tip: "Type the cipher it must use; empty allows any", width: 320)
    private let issuer = AirSQL.textField("", placeholder: "Issuer", id: "users.issuer", tip: "Type who must have issued its certificate; empty allows any", width: 320)
    private let subject = AirSQL.textField("", placeholder: "Subject", id: "users.subject", tip: "Type the subject its certificate must have; empty allows any", width: 320)
    private let problem = label("", font: .systemFont(ofSize: 12), color: .statusBad, wraps: true)
    /// Each role's three ticks.
    private(set) var roleRows: [(role: AccountGrants.Role, granted: NSButton, admin: NSButton, isDefault: NSButton)] = []
    private var keeping: AccountEditor?

    @discardableResult
    static func show(_ old: ServerAccount?, _ draft: ServerAccount, grants: AccountGrants, base: AccountGrants, level: GrantLevel?,
                     content: UsersContent, roles: [ServerAccount]?, plugins: [String], on window: NSWindow) -> AccountEditor {
        let editor = AccountEditor(old, draft, grants: grants, base: base, level: level, content: content, roles: roles, plugins: plugins)
        window.beginSheet(editor.window!)
        editor.keeping = editor
        return editor
    }

    private init(_ old: ServerAccount?, _ draft: ServerAccount, grants: AccountGrants, base: AccountGrants, level: GrantLevel?,
                 content: UsersContent, roles: [ServerAccount]?, plugins: [String]) {
        self.old = old
        self.draft = draft
        self.base = base
        self.content = content
        self.plugins = plugins
        self.roles = roles.map { list in
            let known = list.map { AccountGrants.Role(user: $0.user, host: $0.host) }
            // One it holds that this login can't list stays, to be kept or taken away.
            return known + grants.roles.filter { held in !known.contains { $0.user == held.user && $0.host == held.host } }
                .map { AccountGrants.Role(user: $0.user, host: $0.host) }
        }
        tree = GrantsTree(content: content, levels: grants.levels)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540), styleMask: [.titled], backing: .buffered, defer: true)
        super.init(window: window)
        window.title = heading
        window.contentView = makeContent(grants)
        window.initialFirstResponder = old == nil ? user : nil
        if let level {
            tree.add(level)
            tabs.selectTabViewItem(withIdentifier: "privileges")
            sections.selectedSegment = tabs.indexOfTabViewItem(withIdentifier: "privileges")
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var heading: String {
        let what = draft.isRole ? "role" : "user"
        return old.map { "Edit \($0.name)" } ?? (draft.user.isEmpty && draft.plugin.isEmpty ? "New \(what)" : "New \(what) like this one")
    }

    private var pluginNames: [String] {
        var names = plugins
        if !draft.plugin.isEmpty && !names.contains(draft.plugin) { names.append(draft.plugin) }
        return names
    }

    private func makeContent(_ grants: AccountGrants) -> NSView {
        let title = label(heading, font: .systemFont(ofSize: 14, weight: .semibold))
        title.setAccessibilityIdentifier("users.heading")
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.tabViewType = .noTabsNoBorder
        var tips: [String] = []
        func tab(_ id: String, _ title: String, _ tip: String, _ view: NSView) {
            let item = NSTabViewItem(identifier: id)
            item.label = title
            item.view = view
            tabs.addTabViewItem(item)
            tips.append(tip)
        }
        tab("login", draft.isRole ? "Role" : "Login", "Show its name and how it logs in", loginTab())
        if !draft.isRole { tab("limits", "Limits", "Show what it may use and what it must show of TLS", limitsTab()) }
        tab("privileges", "Privileges", "Show what it may do, level by level", tree.view)
        if let roles, !roles.isEmpty { tab("roles", "Roles", "Show the roles it takes on", rolesTab(roles, grants)) }
        sections.segmentCount = tips.count
        sections.trackingMode = .selectOne
        sections.selectedSegmentBezelColor = .selectedSegment
        for (index, tip) in tips.enumerated() {
            sections.setLabel(tabs.tabViewItem(at: index).label, forSegment: index)
            sections.setToolTip(tip, forSegment: index)
        }
        sections.selectedSegment = 0
        sections.target = self
        sections.action = #selector(sectionChosen(_:))
        sections.setAccessibilityIdentifier("users.tabs")
        let cancel = button("Cancel", id: "users.cancel", tip: "Close this without changing anything", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let next = button("Next…", id: "users.next", tip: "Show the SQL; nothing runs before you say so", target: self, action: #selector(next(_:)), primary: true)
        next.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [helpButton(.users), spacer, cancel, next])
        row.spacing = Spacing.unit
        problem.setAccessibilityIdentifier("users.problem")
        let stack = NSStackView(views: [title, sections, tabs, problem, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        let root = SurfaceView(.ground)
        root.addSubview(stack)
        stack.pin(to: root, insets: NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20))
        NSLayoutConstraint.activate([
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor), row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            problem.widthAnchor.constraint(equalTo: stack.widthAnchor), tabs.heightAnchor.constraint(equalToConstant: 400),
            root.widthAnchor.constraint(equalToConstant: 640),
        ])
        return root
    }

    private func form(_ rows: [[NSView]]) -> NSView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = Spacing.unit
        grid.columnSpacing = Spacing.unit
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.addSubview(grid)
        NSLayoutConstraint.activate([grid.topAnchor.constraint(equalTo: holder.topAnchor, constant: Spacing.double),
                                     grid.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Spacing.double)])
        return holder
    }

    private func secure(_ field: NSSecureTextField, _ placeholder: String, id: String, tip: String) -> NSSecureTextField {
        field.placeholderString = placeholder
        field.toolTip = tip
        field.setAccessibilityIdentifier(id)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return field
    }

    private func loginTab() -> NSView {
        user.stringValue = draft.user
        host.stringValue = draft.host
        // A role keeps its name; only a login moves with RENAME USER on both servers.
        user.isEnabled = !(draft.isRole && old != nil)
        if !user.isEnabled { user.toolTip = "A role keeps its name: make a new one instead" }
        if draft.isRole { return form([[label("Name:"), user]]) }
        if let index = pluginNames.firstIndex(of: draft.plugin) { pluginPopup.selectItem(at: index + 1) }
        let new = old == nil ? "Password:" : "New password:"
        let empty = NSGridCell.emptyContentView
        let buttons = NSStackView(views: [generate, copyPassword])
        buttons.spacing = Spacing.unit
        copyPassword.isEnabled = false
        let view = form([
            [label("Name:"), user], [label("Host:"), host], [label("Login method:"), pluginPopup],
            [label(new), secure(password, old == nil ? "Password" : "Leave empty to keep it", id: "users.password",
                                tip: "Type the password: it goes to the server only, is masked wherever SQL shows, and isn't kept")],
            [label("Repeat:"), secure(repeated, "Password again", id: "users.repeat", tip: "Type it again, to catch a slip")],
            [empty, buttons], [empty, locked], [empty, expired],
        ])
        pluginChosen(nil)
        return view
    }

    private func limitsTab() -> NSView {
        queries.stringValue = String(draft.limits.queries)
        updates.stringValue = String(draft.limits.updates)
        connections.stringValue = String(draft.limits.connections)
        simultaneous.stringValue = String(draft.limits.simultaneous)
        cipher.stringValue = draft.tls.cipher
        issuer.stringValue = draft.tls.issuer
        subject.stringValue = draft.tls.subject
        let view = form([
            [label("Statements an hour:"), queries], [label("Changes an hour:"), updates], [label("Logins an hour:"), connections],
            [label("Connections at once:"), simultaneous], [label("TLS:"), tlsPopup], [label("Cipher:"), cipher], [label("Issuer:"), issuer],
            [label("Subject:"), subject],
        ])
        tlsChosen(nil)
        return view
    }

    private func rolesTab(_ roles: [AccountGrants.Role], _ grants: AccountGrants) -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.unit, bottom: Spacing.unit, right: Spacing.unit)
        for role in roles {
            let held = grants.roles.first { $0.user == role.user && $0.host == role.host }
            let granted = checkbox(role.user, id: "users.role." + role.user, tip: "Let it take on this role", on: held != nil, target: nil, action: nil)
            let admin = checkbox("Can pass it on", id: "users.roleAdmin." + role.user, tip: "Let it grant this role to others",
                                 on: held?.admin == true, target: nil, action: nil)
            let isDefault = checkbox("On at login", id: "users.roleDefault." + role.user, tip: "Turn this role on by itself when it logs in",
                                     on: grants.defaultRoles.contains(role.user), target: self, action: #selector(defaultChosen(_:)))
            isDefault.isHidden = draft.isRole
            granted.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
            let row = NSStackView(views: [granted, admin, isDefault])
            row.spacing = Spacing.double
            rows.addArrangedSubview(row)
            roleRows.append((role, granted, admin, isDefault))
        }
        let scroll = NSScrollView()
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.pin(to: document)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    @objc private func sectionChosen(_ sender: NSSegmentedControl) { tabs.selectTabViewItem(at: sender.selectedSegment) }

    @objc private func defaultChosen(_ sender: NSButton) {
        // MariaDB keeps one default role.
        guard content.sql.mariaDB, sender.state == .on else { return }
        for row in roleRows where row.isDefault !== sender { row.isDefault.state = .off }
    }

    /// The method chosen, as an account: whether it takes a password.
    private var chosenPlugin: String {
        pluginPopup.indexOfSelectedItem > 0 ? pluginNames[pluginPopup.indexOfSelectedItem - 1] : ""
    }

    @objc private func pluginChosen(_ sender: Any?) {
        var account = draft
        account.plugin = chosenPlugin
        let takes = account.takesPassword
        for control in [password, repeated, generate] as [NSControl] { control.isEnabled = takes }
        if !takes {
            password.stringValue = ""
            repeated.stringValue = ""
            generate.toolTip = "This login method takes no password"
        } else {
            generate.toolTip = "Fill both fields with a new random password"
        }
    }

    @objc private func tlsChosen(_ sender: Any?) {
        let specified = tlsPopup.indexOfSelectedItem == 3
        for field in [cipher, issuer, subject] {
            field.isEnabled = specified
        }
    }

    @objc func generatePassword(_ sender: Any?) {
        let generated = UserSQL.generatedPassword()
        password.stringValue = generated
        repeated.stringValue = generated
        copyPassword.isEnabled = true
        copyPassword.toolTip = "Copy the generated password, marked for clipboard managers to skip: it can't be shown again"
    }

    func controlTextDidChange(_ notification: Notification) {
        copyPassword.isEnabled = false
        copyPassword.toolTip = "Generate a password first"
    }

    /// The only way a password leaves the sheet but to the server: the person's own copy of one they couldn't have typed.
    @objc func copyGenerated(_ sender: Any?) {
        guard !AgentGuard.refuses("A password is the person's: agents can't copy it.") else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString(password.stringValue, forType: .string)
    }

    @objc private func cancel(_ sender: Any?) { close(sender) }

    private func close(_ sender: Any?) {
        if let sheet = window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        keeping = nil
    }

    /// The form as an account, or says why it can't be.
    private func account() -> ServerAccount? {
        var account = draft
        account.user = user.stringValue.trimmingCharacters(in: .whitespaces)
        account.host = draft.isRole ? draft.host : host.stringValue.trimmingCharacters(in: .whitespaces)
        guard !draft.isRole else { return account }
        account.plugin = chosenPlugin
        account.locked = locked.state == .on
        account.expired = expired.state == .on
        let figures = [queries, updates, connections, simultaneous].map { Int($0.stringValue.trimmingCharacters(in: .whitespaces)) }
        guard figures.allSatisfy({ ($0 ?? -1) >= 0 }) else {
            problem.stringValue = "Limits are whole numbers, 0 for none"
            return nil
        }
        account.limits.queries = figures[0] ?? 0
        account.limits.updates = figures[1] ?? 0
        account.limits.connections = figures[2] ?? 0
        account.limits.simultaneous = figures[3] ?? 0
        account.tls.kind = ServerAccount.TLS.Kind.allCases[max(0, tlsPopup.indexOfSelectedItem)]
        let specified = account.tls.kind == .specified
        account.tls.cipher = specified ? cipher.stringValue : ""
        account.tls.issuer = specified ? issuer.stringValue : ""
        account.tls.subject = specified ? subject.stringValue : ""
        return account
    }

    @objc func next(_ sender: Any?) {
        problem.stringValue = ""
        guard let new = account() else { return }
        let typed = password.stringValue
        if let words = UserSQL.problem(old, new, password: typed, repeated: repeated.stringValue) {
            problem.stringValue = words
            return
        }
        let sql = content.sql
        var statements = old.map { sql.alter($0, to: new, password: typed) } ?? [sql.create(new, password: typed)]
        statements += sql.changes(new, from: base.levels, to: tree.ticked)
        var after = AccountGrants()
        for row in roleRows where row.granted.state == .on {
            after.roles.append(AccountGrants.Role(user: row.role.user, host: row.role.host, admin: row.admin.state == .on))
            if row.isDefault.state == .on { after.defaultRoles.insert(row.role.user) }
        }
        statements += sql.changes(new, from: base, to: after)
        guard !statements.isEmpty else {
            problem.stringValue = "Nothing has changed"
            return
        }
        var warnings: [String] = []
        if old == nil, new.takesPassword, typed.isEmpty { warnings.append("It has no password: anyone who knows its name can log in from its host.") }
        if new.host == "%", old?.host != "%", !new.isRole { warnings.append("It can log in from anywhere.") }
        let title = old == nil ? "Create \(new.name)" : "Change \(old?.name ?? new.name)"
        content.run(statements, title: title, password: typed.isEmpty ? nil : typed, warnings: warnings, on: window) { [weak self] in self?.close(nil) }
    }
}

/// The privilege tree: each level with a tick for every privilege it can have, coloured by how far it reaches.
@MainActor
final class GrantsTree: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Row: NSObject {
        let level: GrantLevel
        let privilege: String?
        init(_ level: GrantLevel, _ privilege: String?) {
            self.level = level
            self.privilege = privilege
        }
    }

    private let content: UsersContent
    let outline = NSOutlineView()
    /// What the ticks say now.
    private(set) var ticked: [GrantLevel: Set<String>]
    private var levels: [Row] = []
    private var privilegeRows: [GrantLevel: [Row]] = [:]
    private(set) lazy var addButton = button("Add Level…", id: "users.addLevel", tip: "Add a database, table, column or routine to give privileges on",
                                             target: self, action: #selector(addLevel(_:)))

    init(content: UsersContent, levels: [GrantLevel: Set<String>]) {
        self.content = content
        ticked = levels
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("grant"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .fullWidth
        outline.rowHeight = 22
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(toggleLevel(_:))
        outline.setAccessibilityIdentifier("users.privileges")
        outline.setAccessibilityLabel("Privileges")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let legend = NSStackView(views: [ServerPrivilege.Reach.read, .write, .admin].map {
            label(Self.word($0), font: .systemFont(ofSize: 11), color: Self.colour($0))
        })
        let bar = NSStackView(views: [addButton, NSView(), legend])
        bar.spacing = Spacing.unit
        bar.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        [scroll, bar].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.unit),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.unit),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.unit),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: Spacing.unit),
            bar.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.unit),
        ])
        view = root
        arrange(expanding: .global)
    }

    private static func word(_ reach: ServerPrivilege.Reach) -> String {
        switch reach {
        case .read: return "reads"
        case .write: return "writes"
        case .admin: return "administers"
        }
    }

    private static func colour(_ reach: ServerPrivilege.Reach) -> NSColor {
        switch reach {
        case .read: return .systemGreen
        case .write: return .statusWarning
        case .admin: return .statusBad
        }
    }

    /// The levels held, and the whole server's always; what each can have, with what it holds that the server didn't list.
    private func arrange(expanding level: GrantLevel) {
        let shown = Set(ticked.keys).union([.global]).sorted()
        levels = shown.map { Row($0, nil) }
        privilegeRows = Dictionary(uniqueKeysWithValues: shown.map { level in
            let names = Set(level.offered(content.privileges)).union(ticked[level] ?? []).sorted()
            return (level, names.map { Row(level, $0) })
        })
        guard isViewLoaded else { return }
        outline.reloadData()
        if let row = levels.first(where: { $0.level == level }) { outline.expandItem(row) }
    }

    func add(_ level: GrantLevel) {
        if ticked[level] == nil { ticked[level] = [] }
        arrange(expanding: level)
    }

    /// Ticks or clears a privilege, as a click on its box does.
    func set(_ privilege: String, on level: GrantLevel, _ on: Bool) {
        if on { ticked[level, default: []].insert(privilege) } else { ticked[level]?.remove(privilege) }
        if let row = levels.first(where: { $0.level == level }) { outline.reloadItem(row) }
    }

    @objc private func tickChanged(_ sender: NSButton) {
        guard let row = sender.cell?.representedObject as? Row, let privilege = row.privilege else { return }
        set(privilege, on: row.level, sender.state == .on)
    }

    @objc private func toggleLevel(_ sender: Any?) {
        guard let row = outline.item(atRow: outline.clickedRow) as? Row, row.privilege == nil else { return }
        if outline.isItemExpanded(row) { gently(outline).collapseItem(row) } else { gently(outline).expandItem(row) }
    }

    @objc private func addLevel(_ sender: Any?) {
        guard let window = view.window else { return }
        let kind = popup(["Database", "Table", "Column", "Procedure", "Function"], selected: 0, id: "users.levelKind",
                         tip: "Choose what the privileges are on", target: nil, action: nil)
        let databases = NSComboBox()
        databases.addItems(withObjectValues: content.open.snapshot.databases.map(\.name))
        databases.placeholderString = "Database"
        databases.toolTip = "Choose or type the database; % and _ match several, \\_ a real underscore"
        databases.setAccessibilityIdentifier("users.levelDatabase")
        databases.translatesAutoresizingMaskIntoConstraints = false
        databases.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let object = AirSQL.textField("", placeholder: "Table or routine", id: "users.levelObject", tip: "Type the table's or routine's name", width: 300)
        let column = AirSQL.textField("", placeholder: "Column", id: "users.levelColumn", tip: "Type the column's name", width: 300)
        let fields = NSStackView(views: [kind, databases, object, column])
        fields.orientation = .vertical
        fields.alignment = .leading
        NavigatorActions.ask("Add a Level", "Name what the privileges are on.", field: fields, action: "Add",
                             tip: "Add it to the tree: nothing changes until you run the SQL", on: window) { [weak self] in
            let database = databases.stringValue.trimmingCharacters(in: .whitespaces)
            let name = object.stringValue.trimmingCharacters(in: .whitespaces)
            let columnName = column.stringValue.trimmingCharacters(in: .whitespaces)
            guard !database.isEmpty else { return }
            switch kind.indexOfSelectedItem {
            case 0: self?.add(.database(database))
            case 1 where !name.isEmpty: self?.add(.table(database, name))
            case 2 where !name.isEmpty && !columnName.isEmpty: self?.add(.column(database, name, columnName))
            case 3 where !name.isEmpty: self?.add(.routine(database, name, isFunction: false))
            case 4 where !name.isEmpty: self?.add(.routine(database, name, isFunction: true))
            default: break
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let row = item as? Row else { return levels.count }
        return row.privilege == nil ? privilegeRows[row.level]?.count ?? 0 : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let row = item as? Row else { return levels[index] }
        return privilegeRows[row.level]?[index] as Any
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Row)?.privilege == nil }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? Row else { return nil }
        guard let privilege = row.privilege else {
            let count = ticked[row.level]?.count ?? 0
            let title = label(row.level.title + (count == 0 ? "" : " (\(count))"), font: .systemFont(ofSize: 12, weight: .medium), truncates: true)
            title.toolTip = "Double-click to open or close; the figure is how many it holds here"
            return title
        }
        let reach = ServerPrivilege.reach(privilege)
        let tip = content.privileges.first { $0.name == privilege }?.comment
        let box = checkbox(privilege, id: "users.grant." + privilege, tip: tip ?? "Give it this privilege", on: ticked[row.level]?.contains(privilege) == true,
                           target: self, action: #selector(tickChanged(_:)))
        box.cell?.representedObject = row
        let stack = NSStackView(views: [box, label(Self.word(reach), font: .systemFont(ofSize: 11), color: Self.colour(reach))])
        stack.spacing = Spacing.unit
        return stack
    }
}
