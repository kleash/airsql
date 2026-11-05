import AirSQLCore
import AppKit

extension OpenConnection {
    /// Why this connection's users can't be changed from here; nil: they can. Accounts decide who reaches a server, so
    /// read-only, Production and agents all say no, and it fails closed.
    var usersRefusal: String? {
        if AgentGate.agent != nil { return "Only the person at the Mac can change users, roles and grants: nothing was changed." }
        guard let saved = model?.connection(id) else { return "Connect to the server again first" }
        if saved.readOnly { return "“\(saved.displayName)” is read-only: users can't be changed" }
        if saved.colour == .production || saved.safety == .production {
            return "“\(saved.displayName)” is Production: users can't be changed from here"
        }
        return nil
    }
}

/// The user manager (scope "server"): the server's logins and roles, with what the selected one holds. New, Edit and
/// Clone open `AccountEditor`; every write goes through the SQL preview. Reading runs on a session of its own.
@MainActor
final class UsersContent: NSViewController, TabContent, NSMenuItemValidation {
    let open: OpenConnection
    private let spinner = NSProgressIndicator()
    /// SHOW GRANTS of the selected account, with any password hash masked.
    let grantsText = NSTextView()
    private(set) lazy var newUserButton = button("New User…", id: "users.new", tip: Commands.newUser.tip, target: self, action: #selector(newUser(_:)))
    private(set) lazy var newRoleButton = button("New Role…", id: "users.newRole", tip: Commands.newRole.tip, target: self, action: #selector(newRole(_:)))
    private(set) lazy var editButton = button("Edit…", id: "users.edit", tip: Commands.editUser.tip, target: self, action: #selector(editUser(_:)))
    private(set) lazy var list = HostList(
        name: "Users and Roles",
        columns: [
            .init(id: "user", title: "Name", width: 170, tip: "The login or role"),
            .init(id: "host", title: "Host", width: 130, tip: "Where it may log in from; % is anywhere"),
            .init(id: "kind", title: "Kind", width: 60, tip: "A login, or a role that logins take on"),
            .init(id: "plugin", title: "Login Method", width: 170, tip: "How the server checks who it is"),
            .init(id: "password", title: "Password", width: 70, tip: "Whether it has one, never what it is"),
            .init(id: "state", title: "State", width: 110, tip: "Locked logins can't log in; an expired one must change its password"),
            .init(id: "limits", title: "Limits", width: 150, tip: "Queries, updates and connections an hour, and connections at once"),
            .init(id: "tls", title: "TLS", width: 80, tip: "What it must show of TLS to log in"),
        ],
        sort: NSSortDescriptor(key: "user", ascending: true), accessories: [newUserButton, newRoleButton, editButton])
    private(set) var accounts: [ServerAccount] = []
    var privileges: [ServerPrivilege] = []
    private var plugins: [String] = []
    private var session: DBConnection?
    private var reading: Task<Void, Never>?
    private var readingGrants: Task<Void, Never>?
    private var problem: String?
    /// Modify Grants waiting for the list.
    private var waitingLevel: GrantLevel?

    init(_ open: OpenConnection) {
        self.open = open
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var mariaDB: Bool { (session?.server?.flavor ?? open.snapshot.server?.flavour) == .mariadb }
    var hasRoles: Bool { mariaDB || session?.server?.atLeast(8) ?? open.snapshot.server?.atLeast(8) ?? false }
    var sql: UserSQL {
        UserSQL(mariaDB: mariaDB, noBackslashEscapes: session?.noBackslashEscapes ?? open.snapshot.server?.noBackslashEscapes ?? false)
    }

    override func loadView() {
        let root = SurfaceView(.content)
        root.setAccessibilityIdentifier("users")
        let heading = label("Users and Roles", font: .systemFont(ofSize: 15, weight: .semibold), truncates: true)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Reading")
        let top = NSStackView(views: [heading, spinner, NSView(), helpButton(.users)])
        top.spacing = Spacing.unit
        top.translatesAutoresizingMaskIntoConstraints = false
        addChild(list)
        list.view.translatesAutoresizingMaskIntoConstraints = false
        list.onOpen = { [weak self] _ in self?.editUser(nil) }
        list.onSelect = { [weak self] in self?.selectionChanged() }
        list.onMenu = { [weak self] in self?.contextMenu() }
        let scroll = NSScrollView()
        scroll.documentView = grantsText
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        grantsText.isEditable = false
        grantsText.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        grantsText.textContainerInset = NSSize(width: Spacing.unit, height: Spacing.unit)
        grantsText.autoresizingMask = .width
        grantsText.toolTip = "What the selected account holds, in the server's words"
        grantsText.setAccessibilityIdentifier("users.grants")
        [top, list.view, scroll].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double),
            list.view.topAnchor.constraint(equalTo: top.bottomAnchor, constant: Spacing.unit),
            list.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: list.view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 150),
        ])
        view = root
        updateButtons()
        read()
    }

    // MARK: Reading

    private func usersSession() async throws -> DBConnection {
        if let session, session.isConnected { return session }
        let opened = try await open.connection.toolsSession()
        session = opened
        return opened
    }

    private func read() {
        guard reading == nil else { return }
        spinner.startAnimation(nil)
        reading = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await usersSession()
                let mariaDB = session.server?.flavor == .mariadb
                let rows = try await session.rows(UserSQL.accounts(mariaDB: mariaDB))
                let roles = !mariaDB && session.server?.atLeast(8) == true ? try await session.rows(UserSQL.grantedRoles) : nil
                privileges = UserSQL.privileges(try await session.rows(UserSQL.privileges))
                plugins = (try await session.rows(UserSQL.plugins)).compactMap { $0.first ?? nil }
                problem = nil
                show(UserSQL.accounts(rows, roles: roles))
            } catch {
                problem = (error as? AirSQLError)?.kind == .accessDenied
                    ? "this login can't read the accounts: it needs SELECT on the mysql database"
                    : "couldn't read the accounts: " + error.localizedDescription
                show([])
            }
            spinner.stopAnimation(nil)
            reading = nil
            if let level = waitingLevel { modifyGrants(on: level) }
        }
    }

    /// Shows what was read.
    func show(_ accounts: [ServerAccount]) {
        self.accounts = accounts
        list.show(accounts.map { account in
            let limits = account.limits
            let figures = [limits.queries, limits.updates, limits.connections, limits.simultaneous]
            let state = [account.locked ? "Locked" : nil, account.expired ? "Expired" : nil].compactMap { $0 }
            return HostList.Row(key: account.key, cells: [
                "user": account.user, "host": account.host, "kind": account.isRole ? "Role" : "Login", "plugin": account.plugin,
                "password": !account.takesPassword ? "" : account.hasPassword ? "Set" : "None", "state": state.joined(separator: ", "),
                "limits": figures.allSatisfy { $0 == 0 } ? "" : figures.map(String.init).joined(separator: " / "),
                "tls": ["", "Any", "X509", "Specified"][ServerAccount.TLS.Kind.allCases.firstIndex(of: account.tls.kind) ?? 0],
            ])
        })
        updateButtons()
        selectionChanged()
    }

    private var selected: [ServerAccount] {
        let keys = Set(list.selected.map(\.key))
        return accounts.filter { keys.contains($0.key) }
    }

    /// The grants of the one selected account go under the list.
    private func selectionChanged() {
        updateButtons()
        readingGrants?.cancel()
        grantsText.string = ""
        guard selected.count == 1, let account = selected.first else { return }
        readingGrants = Task { [weak self] in
            guard let self else { return }
            do {
                let lines = try await grantLines(account)
                guard !Task.isCancelled else { return }
                grantsText.string = lines.map { SQLLog.mask($0, noBackslashEscapes: self.sql.noBackslashEscapes) + ";" }.joined(separator: "\n")
            } catch {
                if !Task.isCancelled { grantsText.string = "Couldn't read its grants: " + error.localizedDescription }
            }
        }
    }

    private func grantLines(_ account: ServerAccount) async throws -> [String] {
        try await usersSession().rows(sql.showGrants(account)).compactMap { $0.first ?? nil }
    }

    /// What `account` holds, for the editor.
    private func grants(_ account: ServerAccount) async throws -> AccountGrants {
        var grants = AccountGrants(lines: try await grantLines(account), privileges: privileges, noBackslashEscapes: sql.noBackslashEscapes)
        if !mariaDB, hasRoles {
            grants.defaultRoles = Set(try await usersSession().rows(sql.defaultRoles(account)).compactMap { $0.first ?? nil })
        }
        return grants
    }

    private func updateButtons() {
        let refusal = open.usersRefusal
        for (control, command) in [(newUserButton, Commands.newUser), (newRoleButton, Commands.newRole)] {
            let reason = reason(command.action)
            control.isEnabled = reason == nil
            control.toolTip = reason ?? command.tip
        }
        let reason = reason(Commands.editUser.action)
        editButton.isEnabled = reason == nil
        editButton.toolTip = reason ?? Commands.editUser.tip
        list.note = problem ?? refusal ?? "double-click one to change it; nothing is written until you run the SQL it shows"
    }

    // MARK: Commands

    /// Says why a write can't go on, to the agent or the person.
    private func refused() -> Bool {
        guard let refusal = open.usersRefusal else { return false }
        if !AgentGuard.refuses(refusal) { showError(refusal, title: "Couldn't change the users", on: view.window) }
        return true
    }

    @objc func newUser(_ sender: Any?) {
        guard !refused() else { return }
        var account = ServerAccount(user: "", host: "%")
        account.hasPassword = true
        present(nil, account, AccountGrants(), base: AccountGrants())
    }

    @objc func newRole(_ sender: Any?) {
        guard !refused() else { return }
        guard hasRoles else { return showError("This server has no roles: they came with MySQL 8.", title: "Couldn't add a role", on: view.window) }
        present(nil, ServerAccount(user: "", host: mariaDB ? "" : "%", isRole: true), AccountGrants(), base: AccountGrants())
    }

    @objc func editUser(_ sender: Any?) {
        guard !refused(), selected.count == 1, let account = selected.first else { return }
        withGrants(account) { [weak self] in self?.present(account, account, $0, base: $0) }
    }

    /// A new account with the selected one's settings, grants and roles, and no password: that one stays its own.
    @objc func cloneUser(_ sender: Any?) {
        guard !refused(), selected.count == 1, var account = selected.first else { return }
        withGrants(account) { [weak self] grants in
            account.user = ""
            account.expired = false
            self?.present(nil, account, grants, base: AccountGrants())
        }
    }

    private func withGrants(_ account: ServerAccount, then: @escaping (AccountGrants) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                then(try await grants(account))
            } catch {
                showError(error.localizedDescription, title: "Couldn't read its grants", on: view.window)
            }
        }
    }

    private func present(_ old: ServerAccount?, _ draft: ServerAccount, _ grants: AccountGrants, base: AccountGrants, level: GrantLevel? = nil) {
        guard let window = view.window else { return }
        let roles = accounts.filter { $0.isRole && $0.key != draft.key }
        AccountEditor.show(old, draft, grants: grants, base: base, level: level, content: self, roles: hasRoles ? roles : nil, plugins: plugins,
                           on: window)
    }

    /// Runs what the editor made, after the preview, from `window`; `done` once it ran.
    func run(_ statements: [String], title: String, password: String?, warnings: [String], on window: NSWindow?, done: @escaping () -> Void) {
        guard !refused() else { return }
        var request = SQLPreviewRequest(change: ChangeSQL(title: title, statements: statements, connection: open.id), heading: title + "?",
                                        caption: "Each statement runs on its own and takes effect at once; the first that fails stops the rest.")
        request.actionTitle = "Run"
        request.noBackslashEscapes = sql.noBackslashEscapes
        request.password = password
        request.warnings = warnings
        NavigatorActions.confirmAndRun(request, on: open, window: window, refreshing: []) { [weak self] _ in
            done()
            self?.read()
        }
    }

    @objc func dropUser(_ sender: Any?) {
        guard !refused(), let first = selected.first else { return }
        let chosen = selected
        let what = chosen.count == 1 ? first.name : "\(chosen.count) accounts"
        var request = SQLPreviewRequest(change: ChangeSQL(title: "Drop \(what)", statements: chosen.map(sql.drop), connection: open.id),
                                        heading: "Drop \(what)?",
                                        caption: "It can't log in again, and what it holds is gone. Sessions it has open stay until they end.")
        request.actionTitle = "Drop"
        request.destructive = true
        request.typeToConfirm = first.user
        request.noBackslashEscapes = sql.noBackslashEscapes
        if chosen.contains(where: { $0.user == open.connection.options.user }) {
            request.warnings.append("This is the login AirSQL is using: the next connection with it will fail.")
        }
        request.warnings.append("Views and routines that run as this account stop working.")
        NavigatorActions.confirmAndRun(request, on: open, window: view.window, refreshing: []) { [weak self] _ in self?.read() }
    }

    /// Asks whom, then opens their editor at `level`'s ticks.
    func modifyGrants(on level: GrantLevel) {
        guard !refused() else { return }
        guard reading == nil else {
            waitingLevel = level
            return
        }
        waitingLevel = nil
        guard let window = view.window, !accounts.isEmpty else { return }
        let names = accounts.sorted { $0.name < $1.name }
        let chosen = popup(names.map(\.name), selected: 0, id: "users.grantee", tip: "Choose the login or role to give it to", target: nil, action: nil)
        if let current = selected.first, let index = names.firstIndex(of: current) { chosen.selectItem(at: index) }
        NavigatorActions.ask("Modify Grants on \(level.title)", "Choose who it's for; the next step has the ticks.", field: chosen, action: "Next…",
                             tip: "Go on: nothing changes until you run the SQL it shows", on: window) { [weak self] in
            let account = names[chosen.indexOfSelectedItem]
            self?.withGrants(account) { self?.present(account, account, $0, base: $0, level: level) }
        }
    }

    @objc func refresh(_ sender: Any?) { read() }
    @objc func copyList(_ sender: Any?) { list.copyList(sender) }
    @objc func exportList(_ sender: Any?) { list.exportList(sender) }

    private func contextMenu() -> NSMenu? {
        let menu = NSMenu(title: "Users")
        menu.add([Commands.newUser, Commands.newRole, nil, Commands.editUser, Commands.cloneUser, Commands.dropUser, nil, Commands.copy,
                  Commands.copyList, Commands.exportList, nil, Commands.refresh])
        return menu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let reason = reason(item.action)
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    private func reason(_ action: Selector?) -> String? {
        switch action {
        case Commands.newUser.action?: return open.usersRefusal
        case Commands.newRole.action?: return open.usersRefusal ?? (hasRoles ? nil : "This server has no roles: they came with MySQL 8")
        case Commands.editUser.action?, Commands.cloneUser.action?:
            return open.usersRefusal ?? (selected.count == 1 ? nil : "Select one account first")
        case Commands.dropUser.action?: return open.usersRefusal ?? (selected.isEmpty ? "Select the accounts to drop first" : nil)
        default: return nil
        }
    }

    /// The tab closes or the preview shows something else: its session goes.
    func release() {
        if let session { Task { await session.close() } }
        session = nil
    }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        release()
        answer(true)
    }
}

extension MainWindowController {
    /// The connection's Users tab: the one it has, else in the preview tab.
    @discardableResult
    func showUsers(_ open: OpenConnection) -> UsersContent? {
        if let tab = tabs.first(where: { ($0.shown as? UsersContent)?.open === open }) {
            select(tab)
        } else {
            preview(UsersContent(open), title: "Users", connection: open.id)
        }
        return selectedTab?.shown as? UsersContent
    }
}
