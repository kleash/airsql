import AirSQLCore
import AppKit

/// The Settings window's panes, in their order (plan §2.4). Each lane keeps its own pane's file.
enum SettingsPane: String, CaseIterable {
    case general, editor, format, grid, keys, connections, safety, agents, clientTools, liquibase

    var title: String {
        switch self {
        case .general: return "General"
        case .editor: return "Editor"
        case .format: return "Format"
        case .grid: return "Grid"
        case .keys: return "Keys"
        case .connections: return "Connections"
        case .safety: return "Safety"
        case .agents: return "Agents"
        case .clientTools: return "Client Tools"
        case .liquibase: return "Liquibase"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .format: return "text.alignleft"
        case .grid: return "tablecells"
        case .keys: return "keyboard"
        case .connections: return "network"
        case .safety: return "shield.lefthalf.filled"
        case .agents: return "sparkles"
        case .clientTools: return "terminal"
        case .liquibase: return "doc.text"
        }
    }

    var tip: String {
        switch self {
        case .general: return "Show the look of AirSQL and where it keeps its settings"
        case .editor: return "Show the SQL editor's settings"
        case .format: return "Show how Format SQL lays out SQL, with a preview"
        case .grid: return "Show the grid's settings: text size, rows per page, how NULL looks"
        case .keys: return "Show every command's shortcut, and change them"
        case .connections: return "Show how connections load a server's schema"
        case .safety: return "Show what asks first before it changes data, and the limits agents work within"
        case .agents: return "Show whether AI agents may use AirSQL, and where their exports go"
        case .clientTools: return "Show which mysql and mysqldump AirSQL runs"
        case .liquibase: return "Show who changesets are by, their ids and files, and how routines are written"
        }
    }

    @MainActor
    func makeController(model: AppModel) -> SettingsPaneController {
        switch self {
        case .general: return GeneralPane(model: model)
        case .editor: return EditorPane(model: model)
        case .format: return FormatPane(model: model)
        case .grid: return GridPane(model: model)
        case .keys: return KeysPane(model: model)
        case .connections: return ConnectionsPane(model: model)
        case .safety: return SafetyPane(model: model)
        case .agents: return AgentsPane(model: model)
        case .clientTools: return ClientToolsPane(model: model)
        case .liquibase: return LiquibasePane(model: model)
        }
    }
}

/// The Settings window: one pane per toolbar button; changes are saved as they are made.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let tabs = NSTabViewController()

    init(model: AppModel) {
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let controller = pane.makeController(model: model)
            controller.title = pane.title
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.identifier = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            item.toolTip = pane.tip
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = SettingsPane.general.title
        window.backgroundColor = .ground
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self
        window.center()
        if let name = layoutName("Settings") { window.setFrameAutosaveName(name) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ pane: SettingsPane) {
        tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: pane) ?? 0
    }

    /// Ends the edit under way, so a value typed last is saved.
    func windowWillClose(_ notification: Notification) { window?.makeFirstResponder(nil) }
}

/// A Settings pane: a form of controls bound to `model.data.settings`, 560 points wide, with its "?" button.
@MainActor
class SettingsPaneController: NSViewController {
    let model: AppModel
    let form = Form()
    private var bindings: [Binding] = []
    static let width: CGFloat = 580

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Adds the pane's rows to `form`.
    func build() {}

    var helpPage: HelpPage { .settings }

    /// Taller than this, a pane scrolls: its window doesn't resize, and would run off a laptop's screen.
    static let tallest: CGFloat = 640

    private func scrollForm(_ grid: NSView, _ help: NSView) {
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        grid.removeFromSuperview()
        document.addSubview(grid)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: Self.tallest),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: help.topAnchor, constant: -Spacing.unit),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: Spacing.triple),
            grid.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Spacing.unit),
        ])
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: Self.tallest)
    }

    override func loadView() {
        build()
        let grid = form.finish()
        let help = helpButton(helpPage)
        let root = NSView()
        root.addSubview(grid)
        root.addSubview(help)
        // Below controls' compression resistance (750): at a tie pop-ups and buttons are squeezed to 20 pt.
        grid.setContentHuggingPriority(.init(749), for: .vertical)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.triple),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: Spacing.triple),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.triple),
            grid.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            help.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: Spacing.double),
            help.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double - 4),
            help.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.double),
        ])
        view = root
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        if preferredContentSize.height > Self.tallest { scrollForm(grid, help) }
    }

    // MARK: Controls bound to the settings

    /// A target that runs a closure (a control's action).
    final class Binding: NSObject {
        let run: (Any?) -> Void
        init(_ run: @escaping (Any?) -> Void) { self.run = run }
        @objc func act(_ sender: Any?) { run(sender) }
    }

    private func bind(_ control: NSControl, _ run: @escaping (Any?) -> Void) {
        let binding = Binding(run)
        bindings.append(binding)
        control.target = binding
        control.action = #selector(Binding.act(_:))
        control.cell?.sendsActionOnEndEditing = true
    }

    func toggle(_ title: String, id: String, tip: String, _ path: WritableKeyPath<AppSettings, Bool>) -> NSButton {
        let box = checkbox(title, id: id, tip: tip, on: model.data.settings[keyPath: path], target: nil, action: nil)
        bind(box) { [weak self] _ in self?.model.data.settings[keyPath: path] = box.state == .on }
        return box
    }

    /// A whole-number field between `range`'s ends (a wrong value goes back to the saved one).
    func number(_ path: WritableKeyPath<AppSettings, Int>, id: String, tip: String, range: ClosedRange<Int>,
                width: CGFloat = 70) -> NSTextField {
        let field = textField(String(model.data.settings[keyPath: path]), placeholder: String(range.lowerBound), id: id, tip: tip,
                              width: width)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        formatter.allowsFloats = false
        field.formatter = formatter
        field.integerValue = model.data.settings[keyPath: path]
        field.alignment = .right
        bind(field) { [weak self] _ in
            guard let self else { return }
            let value = min(max(field.integerValue, range.lowerBound), range.upperBound)
            self.model.data.settings[keyPath: path] = value
            field.integerValue = value
        }
        return field
    }

    func text(_ path: WritableKeyPath<AppSettings, String>, id: String, tip: String, placeholder: String,
              width: CGFloat = 300) -> NSTextField {
        let field = textField(model.data.settings[keyPath: path], placeholder: placeholder, id: id, tip: tip, width: width)
        bind(field) { [weak self] _ in self?.model.data.settings[keyPath: path] = field.stringValue }
        return field
    }

    /// A pop-up of `choices` (their titles) for a setting.
    func choice<Value: Equatable>(_ path: WritableKeyPath<AppSettings, Value>, id: String, tip: String,
                                  _ choices: [(title: String, value: Value)]) -> NSPopUpButton {
        let selected = choices.firstIndex { $0.value == model.data.settings[keyPath: path] } ?? 0
        let menu = popup(choices.map(\.title), selected: selected, id: id, tip: tip, target: nil, action: nil)
        for item in menu.itemArray { item.toolTip = tip }
        bind(menu) { [weak self] _ in
            guard menu.indexOfSelectedItem >= 0 else { return }
            self?.model.data.settings[keyPath: path] = choices[menu.indexOfSelectedItem].value
        }
        return menu
    }

    /// A button running `run`.
    func action(_ title: String, id: String, tip: String, _ run: @escaping () -> Void) -> NSButton {
        let control = button(title, id: id, tip: tip, target: nil, action: nil)
        bind(control) { _ in run() }
        return control
    }

    /// Shows a folder in Finder, made first if it isn't there yet (off the main thread).
    func reveal(_ folder: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
    }

    /// A path as people read it: ~/… for the home folder.
    static func shown(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
}

/// Font sizes the editor and grid offer.
let fontSizes: [(title: String, value: Double)] = [10, 11, 12, 13, 14, 15, 16, 18, 20].map { ("\(Int($0)) pt", Double($0)) }
