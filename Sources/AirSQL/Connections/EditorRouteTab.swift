import AirSQLCore
import AppKit

/// The editor's SSH and Proxy tab (mockup screen 5): the route, the proxy, the jump hosts and the SSH host, and the
/// path the connection takes; and the Safety tab.
extension ConnectionEditor {
    func routeTab() -> NSView {
        if draft.route == .sshJump && draft.jumpHosts.isEmpty { draft.jumpHosts = [SSHHop()] }
        let form = Form()
        let routes: [(String, Route)] = [("Direct", .direct), ("SSH tunnel", .ssh), ("SSH through jump hosts", .sshJump),
                                         ("SSH through a proxy", .sshProxy), ("Proxy, no SSH", .proxy)]
        form.row("Route", [choice(\.route, routes, id: "editor.route", tip: "Choose how AirSQL reaches the server") { [weak self] in
            self?.refreshTab()
        }], caption: "Every route but Direct ends in a private socket on this Mac, which only you can use: AirSQL, the "
            + "client tools and Terminal all connect through it.")
        if draft.route == .proxy || draft.route == .sshProxy {
            form.heading("Proxy")
            form.row("Proxy", [choice(\.proxy.kind, ProxySettings.Kind.allCases.map { ($0.title, $0) }, id: "editor.proxyKind",
                                      tip: "Choose the kind of proxy") { [weak self] in self?.refreshTab() },
                               text(\.proxy.host, placeholder: "proxy.example.com", id: "editor.proxyHost",
                                    tip: "Type the proxy's host name or address", width: 190),
                               label("Port"), number(\.proxy.port, placeholder: String(draft.proxy.kind.defaultPort),
                                                     id: "editor.proxyPort", tip: "Type the proxy's port")])
            let password = NSSecureTextField(string: proxyPassword)
            password.placeholderString = isNew ? "none" : "unchanged"
            password.toolTip = "Type the proxy's password: it is saved in your Keychain"
            password.setAccessibilityIdentifier("editor.proxyPassword")
            password.translatesAutoresizingMaskIntoConstraints = false
            password.widthAnchor.constraint(equalToConstant: 150).isActive = true
            bind(password) { [weak self] in self?.proxyPassword = password.stringValue }
            form.row("User", [text(\.proxy.user, placeholder: "none", id: "editor.proxyUser",
                                   tip: "Type the proxy's user name; empty when it takes no login", width: 150),
                              label("Password"), password])
        }
        if draft.route == .sshJump || draft.route == .sshProxy {
            for index in draft.jumpHosts.indices {
                form.heading("Jump host \(index + 1)")
                hopRows(form, \.jumpHosts[index], id: "editor.jump\(index)", removable: index)
            }
            let add = button("Add Jump Host", id: "editor.addJump", tip: "Add an SSH host to go through before the SSH host",
                             target: nil, action: nil)
            bind(add) { [weak self] in
                self?.draft.jumpHosts.append(SSHHop())
                self?.refreshTab()
            }
            form.row("", [add])
        }
        if draft.route == .ssh || draft.route == .sshJump || draft.route == .sshProxy {
            form.heading("SSH host")
            hopRows(form, \.sshHost, id: "editor.ssh", removable: nil)
        }
        let path = label(routePath, font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, wraps: true)
        path.preferredMaxLayoutWidth = 440
        path.setAccessibilityIdentifier("editor.routePath")
        routePathLabel = path
        form.row("Path", [path], caption: draft.route == .direct || draft.route == .proxy ? nil
            : "Passwords, passphrases and codes (2FA) an SSH host asks for are asked when you connect.")
        return content(form)
    }

    /// An SSH host's two rows: its address, port and user; how it logs in (and its key file).
    private func hopRows(_ form: Form, _ hop: WritableKeyPath<SavedConnection, SSHHop>, id: String, removable index: Int?) {
        var address: [NSView] = [text(hop.appending(path: \.host), placeholder: "host, or a Host of ~/.ssh/config", id: id + ".host",
                                      tip: "Type the SSH host's name or address, or a Host from your ~/.ssh/config", width: 200),
                                 label("Port"), number(hop.appending(path: \.port), placeholder: "22", id: id + ".port",
                                                       tip: "Type the SSH port (22, or what ~/.ssh/config says)", width: 52),
                                 label("User"), text(hop.appending(path: \.user), placeholder: "yours", id: id + ".user",
                                                     tip: "Type the SSH user name; empty: ~/.ssh/config's, or your Mac's",
                                                     width: 110)]
        if let index {
            let remove = button("Remove", id: id + ".remove", tip: "Go to the next host without this one", target: nil, action: nil)
            bind(remove) { [weak self] in
                guard let self, self.draft.jumpHosts.indices.contains(index) else { return }
                self.draft.jumpHosts.remove(at: index)
                if self.draft.jumpHosts.isEmpty && self.draft.route == .sshJump { self.draft.route = .ssh }
                self.refreshTab()
            }
            address.append(remove)
        }
        form.row("Host", address)
        let logins: [(String, SSHHop.Login)] = [("ssh-agent or ~/.ssh keys", .agent), ("Key file", .keyFile), ("Password", .password)]
        var login: [NSView] = [choice(hop.appending(path: \.login), logins, id: id + ".login",
                                      tip: "Choose how ssh logs in to this host") { [weak self] in self?.refreshTab() }]
        if draft[keyPath: hop].login == .keyFile {
            login += file(draft[keyPath: hop].keyFile, placeholder: "~/.ssh/id_ed25519", id: id + ".keyFile", width: 220,
                          tip: "Choose the private key ssh logs in with; a passphrase is asked when you connect") {
                [weak self] in self?.draft[keyPath: hop.appending(path: \.keyFile)] = $0
            }
        }
        form.row("Log in with", login)
    }

    /// The way the connection goes, from this Mac to the database.
    var routePath: String {
        let database = (draft.host.isEmpty ? "the database" : draft.host) + ":\(draft.port ?? 3306)"
        switch draft.route {
        case .direct:
            return draft.socket.isEmpty ? "This Mac → \(database)" : "This Mac → the server's socket \(draft.socket)"
        default:
            var hops = ["This Mac (private socket)"]
            if draft.route == .proxy || draft.route == .sshProxy {
                hops.append("\(draft.proxy.kind.title) proxy \(draft.proxy.host.isEmpty ? "?" : draft.proxy.host)")
            }
            hops += draft.sshHops.map { "SSH " + ($0.host.isEmpty ? "?" : $0.host) }
            return (hops + ["database " + database]).joined(separator: " → ")
        }
    }

    // MARK: Safety

    /// The connection's own safety checks, or a note that it uses the ones that apply to it.
    func safetyTab() -> NSView {
        let form = Form()
        let own = checkbox("Own safety checks for this connection", id: "editor.ownSafety",
                           tip: "Use checks of its own instead of Settings ▸ Safety (or the Production preset)",
                           on: draft.safety != nil, target: nil, action: nil)
        bind(own) { [weak self] in
            guard let self else { return }
            // A limit being typed in keeps its text first: once the checks are gone, there is nowhere to keep it.
            self.window?.makeFirstResponder(nil)
            self.draft.safety = own.state == .on ? self.draft.safety(defaults: self.model.data.settings.safety) : nil
            self.refreshTab()
        }
        guard draft.safety != nil else {
            form.row("", [own], caption: draft.colour == .production ? "Uses the strict Production preset."
                : "Uses Settings ▸ Safety.")
            return content(form)
        }
        form.row("", [own])
        let toggles: [(String, WritableKeyPath<SavedConnection, Bool>, String)] = [
            ("Ask before UPDATE or DELETE without WHERE", \.safety!.askBeforeUnboundedWrite, "unboundedWrite"),
            ("Ask before any write from a query tab", \.safety!.askBeforeConsoleWrite, "consoleWrite"),
            ("Show the SQL before the grid's Apply", \.safety!.previewBeforeApply, "previewApply"),
            ("Ask before DROP or TRUNCATE", \.safety!.askBeforeDrop, "drop"),
            ("Type a table's name to drop or empty it", \.safety!.typeNameForTables, "typeTableName"),
            ("Ask before restoring into a database that has tables", \.safety!.askBeforeRiskyRestore, "restore"),
            ("Ask before sorting a large table by a column without an index", \.safety!.askBeforeUnindexedSort, "unindexedSort"),
            ("Warn when closing with an open transaction or pending edits", \.safety!.warnOnClose, "warnOnClose"),
            ("Ask before agents change anything", \.safety!.askBeforeAgentChanges, "agentChanges"),
        ]
        for (title, path, id) in toggles {
            form.row("", [toggle(title, path, id: "editor.safety." + id, tip: SafetyPane.tips[id] ?? "")])
        }
        form.row("Agents' queries", [label("At most", color: .secondaryLabelColor),
                                     count(\.safety!.agentRowCap, id: "editor.safety.agentRowCap",
                                           tip: "Type the most rows an agent's query returns on this connection",
                                           range: 1...1_000_000, width: 90),
                                     label("rows and", color: .secondaryLabelColor),
                                     count(\.safety!.agentTimeout, id: "editor.safety.agentTimeout",
                                           tip: "Type how many seconds an agent's query may run on this connection", range: 1...3_600),
                                     label("seconds", color: .secondaryLabelColor)])
        form.row("Open transaction", [label("Warn after", color: .secondaryLabelColor),
                                      count(\.safety!.openTransactionMinutes, id: "editor.safety.openTransaction",
                                            tip: "Warn when a transaction stays open this long; keep-alive stops for it then",
                                            range: 1...1_440),
                                      label("minutes", color: .secondaryLabelColor)])
        return content(form)
    }

    /// A whole number between `range`'s ends.
    private func count(_ path: WritableKeyPath<SavedConnection, Int>, id: String, tip: String, range: ClosedRange<Int>,
                       width: CGFloat = 64) -> NSTextField {
        let field = textField(String(draft[keyPath: path]), placeholder: String(range.lowerBound), id: id, tip: tip, width: width)
        field.alignment = .right
        bind(field) { [weak self] in
            guard let self else { return }
            let value = min(max(Int(field.stringValue) ?? self.draft[keyPath: path], range.lowerBound), range.upperBound)
            self.draft[keyPath: path] = value
            field.stringValue = String(value)
        }
        return field
    }
}
