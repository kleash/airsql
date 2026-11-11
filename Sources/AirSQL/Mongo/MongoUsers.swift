import AirSQLCore
import AppKit

/// A MongoDB server's users and custom roles (mongo-plan, Phase 4 "users"), laid out as MySQL's Users page
/// (`UsersContent`): the list, what the selected one holds under it, and New User…, Change Password…, Grant Role…,
/// Revoke Role… and Drop…. Each write asks what it needs in a small sheet (`MongoAdminSheet`), shows its exact command
/// with the password as the command log has it, and runs only on Run (`MongoAdminActions.run`). Custom roles are listed
/// read-only, with Drop. Read-only, Production and agents are refused (`SavedConnection.usersRefusal`).
@MainActor
final class MongoUsersContent: NSViewController, TabContent, NSMenuItemValidation {
    let open: OpenMongoConnection
    let model: AppModel
    private let spinner = NSProgressIndicator()
    /// The selected user's or role's document, as the server gave it.
    let details = NSTextView()
    private(set) lazy var newButton = button("New User…", id: "mongoUsers.new", tip: Commands.newMongoUser.tip, target: self,
                                             action: #selector(newMongoUser(_:))).onBar("person.badge.plus")
    private(set) lazy var passwordButton = button("Change Password…", id: "mongoUsers.password", tip: Commands.changeMongoPassword.tip,
                                                  target: self, action: #selector(changeMongoPassword(_:))).onBar("key")
    private(set) lazy var grantButton = button("Grant Role…", id: "mongoUsers.grant", tip: Commands.grantMongoRole.tip, target: self,
                                               action: #selector(grantMongoRole(_:))).onBar("checkmark.shield")
    private(set) lazy var list = HostList(
        name: "Mongo Users",
        columns: [
            .init(id: "name", title: "Name", width: 160, tip: "The user or custom role"),
            .init(id: "db", title: "Database", width: 110, tip: "The database it is defined in: a user logs in with it as its auth source"),
            .init(id: "kind", title: "Kind", width: 60, tip: "A user that logs in, or a custom role that users take on"),
            .init(id: "roles", title: "Roles", width: 280, tip: "The roles it holds, each on its database"),
            .init(id: "how", title: "Login Methods", width: 180, tip: "How a user's password is checked; a role's own privileges"),
        ],
        sort: NSSortDescriptor(key: "name", ascending: true), accessories: [newButton, passwordButton, grantButton])
    private(set) var accounts: [MongoAccount] = []
    /// What the last read couldn't see, or why it failed.
    private(set) var problems: [String] = []
    private(set) var reads = 0
    private var reading: Task<Void, Never>?
    private var session: MongoSession?
    private let slot = "users-" + UUID().uuidString

    init(_ open: OpenMongoConnection, model: AppModel) {
        self.open = open
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.content)
        root.setAccessibilityIdentifier("mongoUsers")
        let heading = label("Users and Roles", font: .systemFont(ofSize: 15, weight: .semibold), truncates: true)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Reading")
        let top = NSStackView(views: [heading, spinner, NSView()])
        top.spacing = Spacing.unit
        top.translatesAutoresizingMaskIntoConstraints = false
        addChild(list)
        list.view.translatesAutoresizingMaskIntoConstraints = false
        list.onOpen = { [weak self] _ in self?.grantMongoRole(nil) }
        list.onSelect = { [weak self] in self?.selectionChanged() }
        list.onMenu = { [weak self] in self?.contextMenu() }
        let scroll = NSScrollView()
        scroll.documentView = details
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        details.isEditable = false
        details.backgroundColor = .content
        details.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        details.textContainerInset = NSSize(width: Spacing.unit, height: Spacing.unit)
        details.autoresizingMask = .width
        details.toolTip = "What the selected user or role holds, as the server describes it"
        details.setAccessibilityIdentifier("mongoUsers.details")
        let detailsTitle = label("Details", font: .systemFont(ofSize: 11.5, weight: .semibold), color: .secondaryLabelColor)
        let line = Hairline()
        for part in [detailsTitle, line] { part.translatesAutoresizingMaskIntoConstraints = false }
        [top, list.view, line, detailsTitle, scroll].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double),
            list.view.topAnchor.constraint(equalTo: top.bottomAnchor, constant: Spacing.unit),
            list.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.topAnchor.constraint(equalTo: list.view.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor), line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            detailsTitle.topAnchor.constraint(equalTo: line.bottomAnchor, constant: Spacing.half),
            detailsTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            scroll.topAnchor.constraint(equalTo: detailsTitle.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 150),
        ])
        view = root
        list.note = "reading…"
        updateButtons()
        refresh(nil)
    }

    // MARK: Reading

    var isReading: Bool { reading != nil }

    @objc func refresh(_ sender: Any?) {
        guard reading == nil else { return }
        spinner.startAnimation(nil)
        reading = Task { [weak self] in
            guard let self else { return }
            do {
                let session: MongoSession
                if let existing = self.session { session = existing } else { session = try await open.connection.session(.data, slot: slot) }
                self.session = session
                let (found, missing) = try await session.usersAndRoles()
                show(found, problems: missing)
            } catch {
                show([], problems: ["couldn't read the users: " + error.localizedDescription])
            }
            spinner.stopAnimation(nil)
            reading = nil
            reads += 1
        }
    }

    func show(_ accounts: [MongoAccount], problems: [String]) {
        self.accounts = accounts
        self.problems = problems
        list.show(accounts.map { account in
            HostList.Row(key: account.key, cells: [
                "name": account.name, "db": account.database, "kind": account.isRole ? "Role" : "User",
                "roles": account.roles.map(\.text).joined(separator: ", "),
                "how": account.isRole ? (account.privileges == 1 ? "1 privilege" : "\(account.privileges) privileges")
                    : account.mechanisms.joined(separator: ", "),
            ])
        })
        updateButtons()
        selectionChanged()
    }

    var selected: [MongoAccount] {
        let keys = Set(list.selected.map(\.key))
        return accounts.filter { keys.contains($0.key) }
    }

    private var selectedUser: MongoAccount? { selected.count == 1 && !selected[0].isRole ? selected[0] : nil }

    private func selectionChanged() {
        updateButtons()
        guard selected.count == 1 else { return details.string = "Select a user or role to see what it holds." }
        details.string = selected[0].info.shellForm(pretty: true)
    }

    // MARK: Commands

    /// The connection as saved now (read-only or Production may have been turned on since it connected); nil: deleted.
    private var saved: SavedConnection? { model.connection(open.saved.id) }

    /// It fails closed: a connection it can't find can't be changed.
    private var refusal: String? { saved.map(\.usersRefusal) ?? "Connect to the server again first" }

    /// Says why a write can't go on, to the agent or the person.
    private func refused() -> Bool {
        guard let refusal else { return false }
        if !AgentGuard.refuses(refusal) { showError(refusal, title: "Couldn't change the users", on: view.window) }
        return true
    }

    private func reason(_ action: Selector?) -> String? {
        switch action {
        case Commands.newMongoUser.action?: return refusal
        case Commands.changeMongoPassword.action?, Commands.grantMongoRole.action?:
            return refusal ?? (selectedUser == nil ? "Select one user first" : nil)
        case Commands.revokeMongoRole.action?:
            return refusal ?? (selectedUser == nil ? "Select one user first" : selectedUser!.roles.isEmpty ? "The user holds no roles" : nil)
        case Commands.dropMongoAccount.action?: return refusal ?? (selected.count == 1 ? nil : "Select one user or role first")
        default: return nil
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == Commands.dropMongoAccount.action { item.title = selected.first?.isRole == true ? "Drop Role…" : Commands.dropMongoAccount.title }
        let why = reason(item.action)
        item.explain(enabled: why == nil, reason: why)
        return why == nil
    }

    private func updateButtons() {
        for (control, command) in [(newButton, Commands.newMongoUser), (passwordButton, Commands.changeMongoPassword),
                                   (grantButton, Commands.grantMongoRole)] {
            let why = reason(command.action)
            control.isEnabled = why == nil
            control.toolTip = why ?? command.tip
        }
        list.note = (problems + [refusal ?? "double-click a user to grant it a role; nothing is written until you run the command it shows"])
            .joined(separator: "; ")
    }

    private func contextMenu() -> NSMenu? {
        let menu = NSMenu(title: "Users")
        menu.add([Commands.newMongoUser, nil, Commands.changeMongoPassword, Commands.grantMongoRole, Commands.revokeMongoRole, nil,
                  Commands.dropMongoAccount, nil, Commands.copy, Commands.copyList, Commands.exportList, nil, Commands.refresh])
        return menu
    }

    @objc func copyList(_ sender: Any?) { list.copyList(sender) }
    @objc func exportList(_ sender: Any?) { list.exportList(sender) }

    /// The databases to offer: the tree's, with admin first.
    private var databases: [String] { ["admin"] + (open.databases ?? []).map(\.name).filter { !["admin", "local", "config"].contains($0) } }

    /// The password goes in the command as typed: said when neither TLS nor SSH carries it.
    private var passwordWarnings: [String] {
        guard let saved, saved.tls.mode == .off, saved.sshHops.isEmpty else { return [] }
        return ["The password travels to the server as typed, and this connection has neither TLS nor an SSH route: anyone on "
            + "the network between could read it."]
    }

    private func run(_ command: MongoAdminCommand, title: String, heading: String, caption: String, action: String,
                     destructive: Bool = false, warnings: [String] = [], typeToConfirm: String? = nil, password: String? = nil) {
        guard !refused(), let window = view.window else { return }
        MongoAdminActions.run(command, on: open, model: model, window: window, title: title, heading: heading, caption: caption,
                              action: action, destructive: destructive, warnings: warnings, typeToConfirm: typeToConfirm,
                              failure: { MongoUsers.failure($0, hiding: password) }) { [weak self] in self?.refresh(nil) }
    }

    /// The frame of the users' sheets, with Preview… handing `make`'s command on.
    private func sheet(_ id: String, _ title: String, heading: String, note: String, form: Form,
                       make: @escaping () throws -> MongoAdminCommand, next: @escaping (MongoAdminCommand) -> Void) {
        guard let window = view.window else { return }
        let sheet = MongoAdminSheet(id: id, title: title, heading: heading, note: note, content: form.finish(), width: 480, next: next)
        sheet.make = make
        sheet.begin(on: window)
    }

    private func secure(_ id: String, _ placeholder: String, tip: String) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.toolTip = tip
        field.setAccessibilityIdentifier(id)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return field
    }

    private func combo(_ items: [String], _ value: String, id: String, placeholder: String, tip: String) -> NSComboBox {
        let box = NSComboBox()
        box.addItems(withObjectValues: items)
        box.stringValue = value
        box.placeholderString = placeholder
        box.completes = true
        box.toolTip = tip
        box.setAccessibilityIdentifier(id)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return box
    }

    /// The roles a grant offers: the built-in ones, then the custom roles read.
    private var roleNames: [String] {
        MongoUsers.builtinRoles + accounts.filter(\.isRole).map(\.name).filter { !MongoUsers.builtinRoles.contains($0) }
    }

    @objc func newMongoUser(_ sender: Any?) {
        guard !refused() else { return }
        let database = combo(databases, "admin", id: "mongoUsers.database", placeholder: "admin",
                             tip: "Choose or type the database it is defined in: it logs in with it as its auth source")
        let name = textField("", placeholder: "Name", id: "mongoUsers.name", tip: "Type the new user's name", width: 260)
        let password = secure("mongoUsers.newPassword", "Password", tip: "Type the password: it goes to the server only and isn't kept")
        let repeated = secure("mongoUsers.repeat", "Password again", tip: "Type it again, to catch a slip")
        let role = combo(roleNames, "", id: "mongoUsers.role", placeholder: "None", tip: "Choose or type a role to start with; empty: none")
        let on = combo(databases, "", id: "mongoUsers.roleDatabase", placeholder: "Its own database",
                       tip: "Choose or type the database the role applies to; empty: the user's own")
        let form = Form()
        form.row("Database", [database])
        form.row("Name", [name])
        form.row("Password", [password])
        form.row("Repeat", [repeated])
        form.row("Role", [role])
        form.row("On Database", [on], caption: "More roles: Grant Role… once it exists.")
        sheet("mongoUsers.create", "New User", heading: "Make a MongoDB User", note: "The command shows before it runs.", form: form, make: {
            try MongoUsers.createUser(database: database.stringValue, name: name.stringValue, password: password.stringValue,
                                      repeated: repeated.stringValue, role: role.stringValue, roleDatabase: on.stringValue)
        }) { [weak self] command in
            guard let self, case .string(let user)? = command.command["createUser"] else { return }
            let typed = password.stringValue
            run(command, title: "Create user \(user)", heading: "Create the user \(user) in \(command.database)?",
                caption: "It can log in at once, with \(command.database) as its auth source.", action: "Create",
                warnings: passwordWarnings, password: typed)
        }
    }

    @objc func changeMongoPassword(_ sender: Any?) {
        guard !refused(), let user = selectedUser else { return }
        let password = secure("mongoUsers.newPassword", "New password", tip: "Type the new password: it goes to the server only and isn't kept")
        let repeated = secure("mongoUsers.repeat", "Password again", tip: "Type it again, to catch a slip")
        let form = Form()
        form.row("New Password", [password])
        form.row("Repeat", [repeated])
        sheet("mongoUsers.changePassword", "Change Password", heading: "Change \(user.name)'s Password",
              note: "Sessions it has open stay logged in. The command shows before it runs.", form: form, make: {
            try MongoUsers.changePassword(user, password: password.stringValue, repeated: repeated.stringValue)
        }) { [weak self] command in
            guard let self else { return }
            var warnings = passwordWarnings
            if user.name == open.connection.user {
                warnings.append("This may be the login AirSQL is using: the next connection needs the new password in Edit Connection….")
            }
            run(command, title: "Change \(user.name)'s password", heading: "Change the password of \(user.name) in \(user.database)?",
                caption: "The old password stops working at once.", action: "Change", warnings: warnings, password: password.stringValue)
        }
    }

    @objc func grantMongoRole(_ sender: Any?) {
        guard !refused(), let user = selectedUser else { return }
        let role = combo(roleNames, "", id: "mongoUsers.role", placeholder: "read", tip: "Choose or type the role to grant")
        let on = combo(databases, user.database, id: "mongoUsers.roleDatabase", placeholder: user.database,
                       tip: "Choose or type the database the role applies to (the *AnyDatabase and cluster roles: admin)")
        let form = Form()
        form.row("Role", [role])
        form.row("On Database", [on])
        sheet("mongoUsers.grant", "Grant Role", heading: "Grant \(user.name) a Role",
              note: "A role on a database gives what the role allows there. The command shows before it runs.", form: form, make: {
            try MongoUsers.grant(role.stringValue, on: on.stringValue, to: user)
        }) { [weak self] command in
            self?.run(command, title: "Grant a role to \(user.name)", heading: "Grant \(user.name) \(role.stringValue)?",
                      caption: "It takes effect at once, in sessions it has open too.", action: "Grant")
        }
    }

    @objc func revokeMongoRole(_ sender: Any?) {
        guard !refused(), let user = selectedUser, !user.roles.isEmpty else { return }
        let held = popup(user.roles.map(\.text), selected: 0, id: "mongoUsers.held", tip: "Choose the role to take away", target: nil, action: nil)
        let form = Form()
        form.row("Role", [held])
        sheet("mongoUsers.revoke", "Revoke Role", heading: "Revoke a Role from \(user.name)",
              note: "The command shows before it runs.", form: form, make: {
            MongoUsers.revoke(user.roles[held.indexOfSelectedItem], from: user)
        }) { [weak self] command in
            let role = user.roles[held.indexOfSelectedItem]
            self?.run(command, title: "Revoke a role from \(user.name)", heading: "Revoke \(role.text) from \(user.name)?",
                      caption: "It takes effect at once, in sessions it has open too.", action: "Revoke")
        }
    }

    @objc func dropMongoAccount(_ sender: Any?) {
        guard !refused(), selected.count == 1, let account = selected.first else { return }
        let noun = account.isRole ? "role" : "user"
        var warnings: [String] = []
        if !account.isRole, account.name == open.connection.user {
            warnings.append("This may be the login AirSQL is using: the next connection with it will fail.")
        }
        if account.isRole { warnings.append("Users and roles that hold it lose what it gave them.") }
        run(MongoUsers.drop(account), title: "Drop \(noun) \(account.name)", heading: "Drop the \(noun) \(account.name) from \(account.database)?",
            caption: account.isRole ? "It is deleted for good." : "It can't log in again. Sessions it has open stay until they end.",
            action: "Drop", destructive: true, warnings: warnings, typeToConfirm: account.name)
    }

    /// The tab closes, or the preview shows something else: its session goes.
    func release() {
        reading?.cancel()
        session = nil
        let (connection, slot) = (open.connection, slot)
        Task { await connection.closeSession(.data, slot: slot) }
    }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        release()
        answer(true)
    }
}

extension MainWindowController {
    /// The MongoDB connection's Users and Roles: the tab that has it, else in the preview tab.
    @discardableResult
    func showMongoUsers(_ open: OpenMongoConnection) -> MongoUsersContent? {
        if let tab = model.allTabs.first(where: { ($0.shown as? MongoUsersContent)?.open === open }) {
            show(tab)
            return tab.shown as? MongoUsersContent
        }
        preview(MongoUsersContent(open, model: model), title: "Users", connection: open.saved.id)
        return selectedTab?.shown as? MongoUsersContent
    }
}

extension SidebarController {
    @objc func showMongoUsers(_ sender: Any?) {
        if let open = mongoTarget { main?.showMongoUsers(open) }
    }

    /// A MongoDB connection's right-click menu: its Users and Roles in place of SQL's.
    static func addMongoUsersItem(to menu: NSMenu) {
        guard let index = menu.items.firstIndex(where: { $0.action == Commands.users.action }) else { return }
        menu.removeItem(at: index)
        menu.insertItem(Commands.mongoUsers.item(), at: index)
    }
}
