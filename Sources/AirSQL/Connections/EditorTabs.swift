import AirSQLCore
import AppKit

/// The editor's controls, each bound to a part of the draft, and its General, TLS, Options and Agents tabs.
extension ConnectionEditor {
    typealias Binding = SettingsPaneController.Binding

    /// Runs `run` when the control acts (a text field also when typing in it ends).
    func bind(_ control: NSControl, _ run: @escaping () -> Void) {
        let binding = Binding { _ in run() }
        bindings.append(binding)
        control.target = binding
        control.action = #selector(Binding.act(_:))
        (control as? NSTextField)?.cell?.sendsActionOnEndEditing = true
    }

    func text(_ path: WritableKeyPath<SavedConnection, String>, placeholder: String, id: String, tip: String,
              width: CGFloat? = nil) -> NSTextField {
        let field = textField(draft[keyPath: path], placeholder: placeholder, id: id, tip: tip, width: width)
        if width == nil { field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true }
        bind(field) { [weak self] in self?.draft[keyPath: path] = field.stringValue.trimmingCharacters(in: .whitespaces) }
        return field
    }

    /// A port, or another whole number where nil means the usual (shown as the placeholder).
    func number(_ path: WritableKeyPath<SavedConnection, Int?>, placeholder: String, id: String, tip: String,
                width: CGFloat = 64) -> NSTextField {
        let field = textField(draft[keyPath: path].map(String.init) ?? "", placeholder: placeholder, id: id, tip: tip, width: width)
        field.alignment = .right
        bind(field) { [weak self] in
            let value = Int(field.stringValue.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil }
            self?.draft[keyPath: path] = value
            field.stringValue = value.map(String.init) ?? ""
        }
        return field
    }

    func toggle(_ title: String, _ path: WritableKeyPath<SavedConnection, Bool>, id: String, tip: String,
                then: (() -> Void)? = nil) -> NSButton {
        let box = checkbox(title, id: id, tip: tip, on: draft[keyPath: path], target: nil, action: nil)
        bind(box) { [weak self] in
            self?.draft[keyPath: path] = box.state == .on
            then?()
        }
        return box
    }

    func choice<Value: Equatable>(_ path: WritableKeyPath<SavedConnection, Value>, _ choices: [(String, Value)], id: String,
                                  tip: String, then: (() -> Void)? = nil) -> NSPopUpButton {
        let menu = popup(choices.map(\.0), selected: choices.firstIndex { $0.1 == draft[keyPath: path] } ?? 0, id: id, tip: tip,
                         target: nil, action: nil)
        menu.itemArray.forEach { $0.toolTip = tip }
        bind(menu) { [weak self] in
            guard menu.indexOfSelectedItem >= 0 else { return }
            self?.draft[keyPath: path] = choices[menu.indexOfSelectedItem].1
            then?()
        }
        return menu
    }

    /// A file's path (nil when empty) and a Choose… button.
    func file(_ path: WritableKeyPath<SavedConnection, String?>, placeholder: String, id: String, tip: String) -> [NSView] {
        file(draft[keyPath: path] ?? "", placeholder: placeholder, id: id, tip: tip) { [weak self] in
            self?.draft[keyPath: path] = $0.isEmpty ? nil : $0
        }
    }

    /// A file's path and a Choose… button (an open panel on the editor); `set` gets each new path.
    func file(_ value: String, placeholder: String, id: String, width: CGFloat = 300, tip: String,
              set: @escaping (String) -> Void) -> [NSView] {
        let field = textField(value, placeholder: placeholder, id: id, tip: tip, width: width)
        bind(field) { set(field.stringValue.trimmingCharacters(in: .whitespaces)) }
        let choose = button("Choose…", id: id + ".choose", tip: "Pick the file in a Finder window", target: nil, action: nil)
        bind(choose) { [weak self] in
            guard let self, let window = self.window else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.showsHiddenFiles = true
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                field.stringValue = url.path
                set(url.path)
            }
        }
        return [field, choose]
    }

    /// A form's grid in a view the editor shows.
    func content(_ form: Form) -> NSView {
        let view = NSView()
        let grid = form.finish()
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return view
    }

    // MARK: General

    func generalTab() -> NSView {
        let form = Form()
        form.row("Name", [text(\.name, placeholder: draft.user.isEmpty ? "user@host" : draft.displayName, id: "editor.name",
                               tip: "Type the name the sidebar shows; empty: user@host")])
        let folders = [("None", UUID?.none)] + model.data.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { ($0.name, UUID?.some($0.id)) }
        form.row("Folder", [choice(\.folderID, folders, id: "editor.folder", tip: "Choose the sidebar folder it goes in")])
        form.row("Colour", [choice(\.colour, ConnectionColour.allCases.map { ($0.title, $0) }, id: "editor.colour",
                                   tip: "Mark the connection with a colour; Production also turns on stricter safety")],
                 caption: "Production starts with the strict safety checks and agent access Off.")
        let host = text(\.host, placeholder: draft.route == .direct ? "127.0.0.1" : "as the SSH host or proxy reaches it",
                        id: "editor.host", tip: "Type the server's host name or address; TLS checks the certificate against it")
        form.row(draft.route == .direct ? "Host" : "Database host",
                 [host, label("Port"), number(\.port, placeholder: "3306", id: "editor.port", tip: "Type the server's port (3306 by default)")],
                 caption: draft.route == .direct ? nil : "As the last SSH host or the proxy reaches it, often 127.0.0.1 or a private address.")
        if draft.route == .direct {
            form.row("Socket", [text(\.socket, placeholder: "none: TCP", id: "editor.socket",
                                     tip: "Type the path of a server's own socket on this Mac (Homebrew, MAMP, DBngin)")],
                     caption: "For a server on this Mac: its socket file, used instead of the host and port.")
        }
        form.row("User", [text(\.user, placeholder: draft.askPassword ? "asked at each connect" : "root", id: "editor.user",
                               tip: "Type the database user to log in as")])
        let password = NSSecureTextField(string: self.password)
        password.placeholderString = isNew ? "none" : "unchanged"
        password.toolTip = "Type the password: it is saved in your Keychain, never in AirSQL's files"
        password.setAccessibilityIdentifier("editor.password")
        password.translatesAutoresizingMaskIntoConstraints = false
        password.widthAnchor.constraint(equalToConstant: 200).isActive = true
        password.isEnabled = !draft.askPassword
        bind(password) { [weak self] in self?.password = password.stringValue }
        let ask = toggle("Ask at each connect", \.askPassword, id: "editor.askPassword",
                         tip: "Ask for the user and password at each connect and never save them") { [weak self] in self?.refreshTab() }
        form.row("Password", [password, ask])
        form.row("Database", [text(\.database, placeholder: "none", id: "editor.database",
                                   tip: "Type the database to make current after connecting")])
        form.row("Comment", [text(\.comment, placeholder: "what it is for, who to ask", id: "editor.comment",
                                  tip: "Type a note the connection's summary shows")])
        return content(form)
    }

    // MARK: TLS

    func tlsTab() -> NSView {
        let form = Form()
        let modes: [(String, TLSOptions.Mode)] = [("Off", .off), ("Required, not checked", .required),
                                                  ("Check the authority", .verifyCA),
                                                  ("Check the authority and host name", .verifyIdentity)]
        form.row("TLS", [choice(\.tls.mode, modes, id: "editor.tlsMode",
                                tip: "Choose how the connection is encrypted and how the server proves who it is") { [weak self] in
            self?.refreshTab()
        }], caption: draft.socket.isEmpty || draft.route != .direct
            ? "The host name check is the safe choice. A server with a certificate macOS doesn't know shows a fingerprint "
                + "to trust when you connect: AirSQL then remembers it and refuses any other."
            : "Not used with the server's own socket, which never leaves this Mac.")
        guard draft.tls.mode != .off else { return content(form) }
        form.row("Authority file", file(\.tls.caFile, placeholder: "macOS's own", id: "editor.caFile",
                                        tip: "Choose the PEM file of a private certificate authority to trust besides the Mac's"))
        form.row("Certificate", file(\.tls.certFile, placeholder: "none", id: "editor.certFile",
                                     tip: "Choose your client certificate (PEM), for a server that asks for one"))
        form.row("Key", file(\.tls.keyFile, placeholder: "none", id: "editor.keyFile",
                             tip: "Choose the client certificate's key (PEM)"))
        let pinned = label(draft.tls.pinnedFingerprint ?? "None", font: .monospacedSystemFont(ofSize: 10.5, weight: .regular),
                           color: draft.tls.pinnedFingerprint == nil ? .secondaryLabelColor : .labelColor, wraps: true)
        pinned.preferredMaxLayoutWidth = 380
        pinned.isSelectable = true
        pinned.setAccessibilityIdentifier("editor.pinned")
        var views: [NSView] = [pinned]
        if draft.tls.pinnedFingerprint != nil {
            let forget = button("Forget", id: "editor.forgetPin", tip: "Forget the trusted certificate: the next connect asks again",
                                target: nil, action: nil)
            bind(forget) { [weak self] in
                self?.draft.tls.pinnedFingerprint = nil
                self?.refreshTab()
            }
            views.append(forget)
        }
        form.row("Trusted", views, caption: "The fingerprint of the certificate you trusted for this server, if any.")
        form.row("", [toggle("PAM or LDAP login", \.cleartextLogin, id: "editor.cleartext",
                             tip: "Allow the plain-text login PAM and LDAP accounts need, only over TLS that proves the server")],
                 caption: "Such logins send the password as plain text, so AirSQL allows them only when TLS proves the server.")
        return content(form)
    }

    // MARK: Options

    func optionsTab() -> NSView {
        let form = Form()
        form.row("", [toggle("Read-only", \.readOnly, id: "editor.readOnly",
                             tip: "Refuse writes from the console, the grid and agents on this connection")])
        form.row("", [toggle("Compressed protocol", \.compress, id: "editor.compress",
                             tip: "Compress what goes over the network: faster on slow links, a little more work for both ends")])
        let timeout = textField(draft.queryTimeout == 0 ? "" : String(draft.queryTimeout), placeholder: "none",
                                id: "editor.queryTimeout", tip: "Type how many seconds a statement may run before it is "
                                    + "cancelled; empty: no limit", width: 64)
        timeout.alignment = .right
        bind(timeout) { [weak self] in
            let value = max(0, Int(timeout.stringValue) ?? 0)
            self?.draft.queryTimeout = value
            timeout.stringValue = value == 0 ? "" : String(value)
        }
        form.row("Query timeout", [timeout, label("seconds", color: .secondaryLabelColor)])
        form.row("Databases shown", [text(\.databaseFilter, placeholder: "all", id: "editor.databaseFilter",
                                          tip: "Type the databases to show, separated by commas; * and ? match any text")],
                 caption: "For example: shop, reports_*. The others stay on the server, out of the way.")
        let sql = NSTextView()
        sql.string = draft.startupSQL
        sql.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        sql.isRichText = false
        sql.isAutomaticQuoteSubstitutionEnabled = false
        sql.isAutomaticDashSubstitutionEnabled = false
        sql.toolTip = "Type statements to run after each login, ended by semicolons, such as SET time_zone = '+00:00';"
        sql.setAccessibilityIdentifier("editor.startupSQL")
        sql.delegate = startupSQLWatcher
        let scroll = NSScrollView()
        scroll.documentView = sql
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        sql.autoresizingMask = [.width]
        form.row("Startup SQL", [scroll], caption: "Runs in every session after it logs in (SET sql_mode, time_zone…).")
        safetyRows(form)
        return content(form)
    }

    /// Keeps the startup SQL in the draft as it is typed.
    private var startupSQLWatcher: StartupSQLWatcher {
        let watcher = StartupSQLWatcher { [weak self] text in self?.draft.startupSQL = text }
        bindings.append(watcher)
        return watcher
    }

    // MARK: Agents

    func agentsTab() -> NSView {
        let form = Form()
        form.row("Agent access", [choice(\.agentAccess, AgentAccess.allCases.map { ($0.title, $0) }, id: "editor.agentAccess",
                                         tip: "Choose what AI agents may do with this connection")],
                 caption: "Schema: names and structure. Read: also read-only queries. Analytics: also larger results and "
                    + "exports to the agents' folder.")
        form.row("", [toggle("Agents may see sample rows", \.agentSampleRows, id: "editor.sampleRows",
                             tip: "Let agents see a few rows of a table with its structure (off by default)")])
        if !model.data.settings.agentsAllowed {
            form.row("", [caption("Agents are off for every connection until you turn them on in Settings ▸ Agents.")])
        }
        return content(form)
    }
}

/// The startup SQL's text view delegate: hands each change on.
final class StartupSQLWatcher: NSObject, NSTextViewDelegate {
    let changed: (String) -> Void
    init(_ changed: @escaping (String) -> Void) { self.changed = changed }
    func textDidChange(_ notification: Notification) {
        if let view = notification.object as? NSTextView { changed(view.string) }
    }
}
