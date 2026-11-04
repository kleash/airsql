import AirSQLCore
import AppKit

/// A card in the content area: the content colour with a hairline edge and a 8 pt radius, its content inset by 24 pt.
@MainActor
func card(_ content: NSView, id: String) -> NSView {
    let card = SurfaceView(.content, radius: Radius.card, border: .separatorColor)
    card.setAccessibilityIdentifier(id)
    card.addSubview(content)
    content.pin(to: card, insets: .all(Spacing.triple))
    return card
}

/// Holds `card` at the top middle of the content area (at most `width` wide), in a scroll view for short windows.
@MainActor
func centered(_ card: NSView, width: CGFloat) -> NSView {
    let document = FlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(card)
    card.translatesAutoresizingMaskIntoConstraints = false
    let narrow = card.widthAnchor.constraint(equalToConstant: width)
    narrow.priority = .defaultHigh
    NSLayoutConstraint.activate([
        narrow,
        card.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor, constant: -2 * Spacing.triple),
        card.centerXAnchor.constraint(equalTo: document.centerXAnchor),
        card.topAnchor.constraint(equalTo: document.topAnchor, constant: Spacing.triple + Spacing.unit),
        card.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -Spacing.triple),
    ])
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = document
    NSLayoutConstraint.activate([
        document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
    ])
    let root = SurfaceView(.ground)
    root.addSubview(scroll)
    scroll.pin(to: root)
    return root
}

/// The first run (no connections yet): add the first connection, set up agents, and three tips.
@MainActor
func firstRunView() -> NSView {
    let symbol = NSImageView(image: NSImage(systemSymbolName: "cylinder.split.1x2", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 34, weight: .light))!)
    symbol.contentTintColor = .accent
    symbol.setContentHuggingPriority(.required, for: .horizontal)
    let title = label("Add your first connection", font: .systemFont(ofSize: 20, weight: .semibold))
    let intro = label("AirSQL works with MySQL and MariaDB servers on this Mac, on your network, or through SSH, jump hosts "
                      + "and proxies. Passwords stay in your Keychain.", font: .systemFont(ofSize: 13), color: .secondaryLabelColor,
                      wraps: true)
    let add = button("Add Connection…", id: "firstRun.addConnection", tip: Commands.newConnection.tip + " (⌘N)",
                     target: nil, action: Commands.newConnection.action, primary: true)
    add.keyEquivalent = "\r"
    let importing = button("Import Connections…", id: "firstRun.import", tip: Commands.importConnections.tip, target: nil,
                           action: Commands.importConnections.action)
    let sshConfig = button("Import from SSH Config…", id: "firstRun.importSSH", tip: Commands.importSSHConfig.tip, target: nil,
                           action: Commands.importSSHConfig.action)
    let guide = button("Getting Started", id: "firstRun.guide", tip: Commands.gettingStarted.tip, target: nil,
                       action: Commands.gettingStarted.action)
    let actions = NSStackView(views: [add, importing, sshConfig])
    actions.spacing = Spacing.unit
    let agentsTitle = label("Set up agents", font: .systemFont(ofSize: 15, weight: .semibold))
    let agentsText = label("Let Claude Code, Gemini CLI or another MCP client read your schemas and run read-only queries, at "
                           + "the access you choose for each connection. Agents are off until you turn them on.",
                           font: .systemFont(ofSize: 13), color: .secondaryLabelColor, wraps: true)
    let agents = button("Set Up Agents…", id: "firstRun.setUpAgents", tip: Commands.setUpAgents.tip, target: nil,
                        action: Commands.setUpAgents.action)
    let tips = NSStackView(views: [
        tip("cursorarrow.click.2", "Double-click a connection to connect; right-click it for everything else."),
        tip("return", "⌘↩ runs the statement at the cursor. Nothing is written until you press Run or Apply."),
        tip("shield.lefthalf.filled", "Settings ▸ Safety decides what asks first; a connection coloured Production starts "
            + "strict: every write shows its SQL and asks."),
        tip("questionmark.circle", "No server yet? Getting Started shows how to run one on this Mac and try AirSQL on sample data."),
    ])
    tips.orientation = .vertical
    tips.alignment = .leading
    tips.spacing = Spacing.unit
    let top = NSStackView(views: [symbol, title])
    top.spacing = 12
    let stack = NSStackView(views: [top, intro, actions, Hairline(.softSeparator), agentsTitle, agentsText, agents,
                                    Hairline(.softSeparator), tips, guide])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.setCustomSpacing(Spacing.double, after: actions)
    stack.setCustomSpacing(Spacing.double, after: agents)
    for line in stack.arrangedSubviews where line is Hairline {
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    for text in [intro, agentsText] { text.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return centered(card(stack, id: "firstRun"), width: 560)
}

private func tip(_ symbol: String, _ text: String) -> NSView {
    let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    image.contentTintColor = .accent
    image.setContentHuggingPriority(.required, for: .horizontal)
    image.widthAnchor.constraint(equalToConstant: 20).isActive = true
    let words = label(text, font: .systemFont(ofSize: 12.5), wraps: true)
    let row = NSStackView(views: [image, words])
    row.alignment = .firstBaseline
    row.spacing = 10
    return row
}

/// Connections exist but none is selected, and no tab is open.
@MainActor
func selectConnectionView() -> NSView {
    let title = label("Select a connection", font: .systemFont(ofSize: 15, weight: .semibold))
    let text = label("Select a connection in the sidebar to see its details, or double-click it to connect.",
                     font: .systemFont(ofSize: 13), color: .secondaryLabelColor, wraps: true)
    let stack = NSStackView(views: [title, text])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Spacing.unit
    text.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    return centered(card(stack, id: "selectConnection"), width: 460)
}

/// A selected connection's summary (a click in the sidebar shows it): where it goes, how it logs in, its colour,
/// safety and agent access, and Connect (Disconnect once it connects, and Return then opens a new query), Edit… and
/// New Query.
@MainActor
func summaryView(_ connection: SavedConnection, data: AirSQLData, state: ConnectionState?) -> NSView {
    let dot = DotView(diameter: 12)
    dot.color = connection.colour.color ?? .tertiaryLabelColor
    let name = label(connection.displayName.isEmpty ? "Untitled" : connection.displayName,
                     font: .systemFont(ofSize: 20, weight: .semibold), truncates: true)
    name.toolTip = connection.displayName
    name.setAccessibilityIdentifier("summary.name")
    let route = ChipView(connection.routeBadge, style: .neutral)
    route.toolTip = "How AirSQL reaches this server"
    let titleRow = NSStackView(views: [dot, name, route])
    titleRow.spacing = Spacing.unit
    // Connecting or connected: Disconnect in Connect's place, and Return opens a new query.
    var live = false, connected = false
    if case .connected? = state { (live, connected) = (true, true) }
    if case .connecting? = state { live = true }
    let connect = live
        ? button("Disconnect", id: "summary.disconnect", tip: (connected ? Commands.disconnect.tip : "Stop connecting")
                 + " (\(Commands.disconnect.shortcut))", target: nil, action: Commands.disconnect.action)
        : button("Connect", id: "summary.connect", tip: Commands.connect.tip + " (⌘K)", target: nil, action: Commands.connect.action,
                 primary: true)
    let edit = button("Edit…", id: "summary.edit", tip: Commands.editConnection.tip, target: nil, action: Commands.editConnection.action)
    let query = button("New Query", id: "summary.newQuery", tip: Commands.newQuery.tip + " (⌘T)", target: nil,
                       action: Commands.newQuery.action, primary: live)
    (live ? query : connect).keyEquivalent = "\r"
    let buttons = NSStackView(views: [connect, edit, query])
    buttons.spacing = Spacing.unit

    let form = Form()
    let server = connection.route == .direct && !connection.socket.isEmpty ? connection.socket
        : connection.host.isEmpty ? "Not set" : connection.host + ":" + String(connection.port ?? 3306)
    form.row(connection.route == .direct && !connection.socket.isEmpty ? "Socket" : "Server", [value(server)])
    form.row("User", [value(connection.user.isEmpty ? "Not set" : connection.user
                           + (connection.askPassword ? " (password asked at each connect)" : ""))])
    form.row("Database", [value(connection.database.isEmpty ? "None chosen" : connection.database)])
    form.row("Route", [value(routeText(connection))])
    form.row("Colour", [value(connection.colour.title)])
    form.row("Safety", [value(connection.hasCustomSafety ? "Its own settings (custom safety)"
                              : connection.colour == .production ? "The strict Production preset" : "Settings ▸ Safety")])
    form.row("Agent access", [value(connection.agentAccess.title + (connection.agentSampleRows ? ", with sample rows" : ""))])
    form.row("Read-only", [value(connection.readOnly ? "Yes: writes are refused" : "No")])
    form.row("Now", [value(stateText(state))])
    if !connection.comment.isEmpty { form.row("Comment", [value(connection.comment, wraps: true)]) }
    let grid = form.finish()

    let stack = NSStackView(views: [titleRow, buttons, Hairline(.softSeparator), grid])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Spacing.double
    for view in [titleRow, buttons] { view.setContentHuggingPriority(.defaultLow, for: .horizontal) }
    titleRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
    if let line = stack.arrangedSubviews.first(where: { $0 is Hairline }) {
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    return centered(card(stack, id: "summary"), width: 600)
}

private func value(_ text: String, wraps: Bool = false) -> NSTextField {
    let field = label(text, font: .systemFont(ofSize: 13), wraps: wraps, truncates: !wraps)
    field.isSelectable = true
    field.toolTip = wraps ? nil : text
    if wraps { field.preferredMaxLayoutWidth = 400 }
    return field
}

/// The route in words, as the status bar shows it ("SSH tunnel to db.example.com").
func routeText(_ connection: SavedConnection) -> String {
    let server = connection.host.isEmpty ? "the server" : connection.host + (connection.port.map { ":\($0)" } ?? "")
    switch connection.route {
    case .direct: return connection.socket.isEmpty ? "Direct to \(server)" : "This Mac's socket \(connection.socket)"
    case .ssh: return "SSH tunnel to \(server)"
    case .sshJump: return "SSH through jump hosts to \(server)"
    case .sshProxy: return "SSH through a proxy to \(server)"
    case .proxy: return "Proxy to \(server)"
    }
}

/// Where a connection is, in words.
func stateText(_ state: ConnectionState?) -> String {
    switch state {
    case nil: return "Not connected"
    case .connecting(let step)?: return "Connecting: \(step)"
    case .connected(let server)?: return "Connected to \(server)"
    case .failed(let reason)?: return "Not connected: \(reason)"
    }
}
