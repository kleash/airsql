// Ported from AirSCP 1.4.0 Sources/AirSCP/AgentServer.swift: the tools' core (snapshot, screenshot, menu, press, set,
// select, key, type, click, wait) and KeyCombo, without the socket, the token and the questions to the person, which
// come with agent access (L7). For now the tests drive AirSQL through it, in-process.
import AirSQLCore
import AppKit
import CoreImage

/// Drives AirSQL as a person does: menu items through their own validation (a disabled item says why), buttons and
/// fields of windows and sheets through the accessibility tree VoiceOver reads, keys and clicks as events (double and
/// right clicks too: a right-click answers with the menu it opens), and what no click should carry (select, wait,
/// snapshot) by calling what the views call. Screenshots are drawn by AirSQL itself. Replies have MCP's tool-result
/// shape: text (JSON) or an image, `isError` on failure.
@MainActor
final class AgentServer {
    weak var main: MainWindowController?
    let model: AppModel
    /// The app's windows besides the main one (Settings, app-modal alerts): all of NSApp's; tests, which share NSApp
    /// with other tests' windows, give their own.
    let otherWindows: () -> [NSWindow]
    /// The menu the last right-click opened, and its window: `menu path="context > …"` chooses from it.
    var contextMenu: (menu: NSMenu, window: NSWindow?)?

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    init(main: MainWindowController?, model: AppModel, windows: (() -> [NSWindow])? = nil) {
        self.main = main
        self.model = model
        otherWindows = windows ?? { NSApp.windows }
    }

    static let tools = ["snapshot", "screenshot", "menu", "press", "set", "select", "key", "type", "click", "wait"]

    /// Runs a tool: text (JSON) or an image, `isError` on failure. For an agent (`AgentGate.agent`), what the tool sets off
    /// is the agent's: the gate's checks refuse what only the person at the Mac may do (`AgentGuard`).
    func handle(_ tool: String, _ arguments: [String: Any]) async -> [String: Any] {
        let notes = AgentGuard.Notes()
        do {
            let reply = try await AgentGuard.$notes.withValue(notes) { try await run(tool, arguments) }
            if let refusal = notes.refusal { throw Failure(refusal) }
            return reply
        } catch let failure as Failure {
            return Self.text(["error": failure.message], isError: true, raw: failure.message)
        } catch {
            return Self.text(["error": error.localizedDescription], isError: true, raw: error.localizedDescription)
        }
    }

    private func run(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        switch tool {
        case "snapshot":
            if let spec = arguments["in"] as? String { _ = try scopes(spec) }  // a window that isn't there says so
            return Self.text(snapshot(arguments))
        case "screenshot": return try screenshot(arguments)
        case "menu": return Self.text(try await menu(arguments))
        case "press": return Self.text(try await press(arguments))
        case "set": return Self.text(try await set(arguments))
        case "select": return Self.text(try await select(arguments))
        case "key": return Self.text(try await key(arguments))
        case "type": return Self.text(try await type(arguments))
        case "click": return Self.text(try await click(arguments))
        case "wait": return Self.text(try await wait(arguments))
        default: throw Failure("AirSQL has no tool “\(tool)”. Tools: " + Self.tools.joined(separator: ", "))
        }
    }

    static func text(_ json: [String: Any], isError: Bool = false, raw: String? = nil) -> [String: Any] {
        // NSJSONSerialization raises (an Objective-C exception no Swift code catches) for NaN and infinite numbers.
        let safe = finite(json)
        let data = JSONSerialization.isValidJSONObject(safe)
            ? (try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            : Data("{}".utf8)
        return ["content": [["type": "text", "text": raw ?? String(decoding: data, as: UTF8.self)]], "isError": isError]
    }

    /// `value` with NaN and infinite numbers as null.
    static func finite(_ value: Any) -> Any {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.doubleValue.isFinite ? number : NSNull()
        case let array as [Any]: return array.map(finite)
        case let object as [String: Any]: return object.mapValues(finite)
        default: return value
        }
    }

    /// After an action: a moment for what it opens, then the frontmost sheet.
    private func acted(_ extra: [String: Any] = [:]) async -> [String: Any] {
        try? await Task.sleep(nanoseconds: 150_000_000)
        var json = extra
        json["ok"] = true
        if let sheet = openSheets().last { json["sheet"] = sheetJSON(sheet) }
        return json
    }

    /// Runs `action` from the run loop, as a menu choice or a click runs, rather than inside this request: one that opens
    /// a modal loop then doesn't hold up the reply.
    private func perform(_ action: @escaping () -> Void) async -> [String: Any] {
        await Self.later(action)
        return await acted()
    }

    /// Runs `action` from a run-loop timer and returns once it has run, or once it has opened a modal loop. It runs as
    /// the agent's whose request this is, if any (so do the tasks it starts).
    static func later(_ action: @escaping () -> Void) async {
        let agent = AgentGate.agent, notes = AgentGuard.notes
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.add(Timer(timeInterval: 0, repeats: false) { _ in
                continuation.resume()
                MainActor.assumeIsolated {
                    AgentGate.$agent.withValue(agent) { AgentGuard.$notes.withValue(notes) { action() } }
                }
            }, forMode: .common)
        }
    }

    private var mainWindow: NSWindow {
        get throws {
            guard let window = main?.window else { throw Failure("AirSQL's window isn't there.") }
            return window
        }
    }

    private func describe(_ json: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: Self.finite(json), options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    // MARK: Menus

    private func normalized(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces).lowercased()
        for suffix in ["…", "...", ":"] where text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private func menu(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let path = arguments["path"] as? String else { throw Failure("menu needs a path, e.g. \"Connection > Connect\".") }
        let parts = path.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var window = try (arguments["in"] as? String).map { try scopes($0).last! }
        var menu: NSMenu
        var names = parts
        if parts.first.map(normalized) == "context" {
            guard let context = contextMenu else { throw Failure("No context menu is open: right-click first (click button=right).") }
            menu = context.menu
            window = context.window
            names = Array(parts.dropFirst())
        } else {
            guard let bar = NSApp.mainMenu else { throw Failure("AirSQL has no menu bar yet.") }
            menu = bar
        }
        var found: NSMenuItem?
        for (index, part) in names.enumerated() {
            let current = menu
            update(current)
            if index > 0 || contextMenu?.menu === current { current.items.filter { $0.action != nil }.forEach { _ = validate($0, in: window) } }
            let items = current.items.filter { !$0.isSeparatorItem && !$0.title.isEmpty && !$0.isHidden }
            guard let item = items.first(where: { $0.title == part }) ?? items.first(where: { normalized($0.title) == normalized(part) })
            else {
                throw Failure("No menu item “\(part)”" + (index > 0 ? " in \(names[..<index].joined(separator: " > "))" : "")
                              + ". There: " + items.map(\.title).joined(separator: ", "))
            }
            found = item
            if index < names.count - 1 {
                guard let submenu = item.submenu else { throw Failure("“\(item.title)” has no submenu.") }
                menu = submenu
            }
        }
        guard let item = found, let action = item.action else { throw Failure("“\(path)” is a menu, not a command.") }
        let check = validate(item, in: window)
        guard check.enabled, let target = check.target else {
            throw Failure("“\(path)” is disabled now" + (check.reason.map { ": " + $0 } ?? "."))
        }
        try checkAgentMayChoose(action, target: target)
        if parts.first.map(normalized) == "context" { contextMenu = nil }
        return await perform { NSApp.sendAction(action, to: target, from: item) }
    }

    /// Fills a menu as it would be as it opens; the Window menu's tabs from this harness's main window (a test process
    /// has several open).
    func update(_ menu: NSMenu) {
        if menu.delegate === WindowMenu.shared, let main {
            main.updateWindowMenu(menu)
        } else if let connections = menu.delegate as? ConnectToMenu {
            connections.fill(menu, from: main)
        } else {
            menu.delegate?.menuNeedsUpdate?(menu)
        }
    }

    /// Whether the item is enabled now (its target's own validation, as AppKit checks before showing a menu), the
    /// reason it gives when not, and the object that would get its action (from `window`'s responder chain, if given).
    func validate(_ item: NSMenuItem, in window: NSWindow? = nil) -> (enabled: Bool, reason: String?, target: AnyObject?) {
        guard let action = item.action else { return (false, nil, nil) }
        guard let target = target(for: action, explicit: item.target, in: window) else {
            return (false, "Nothing in AirSQL can do that here yet.", nil)
        }
        var enabled = true
        if let validator = target as? NSMenuItemValidation {
            enabled = validator.validateMenuItem(item)
        } else if let validator = target as? NSUserInterfaceValidations {
            enabled = validator.validateUserInterfaceItem(item)
        }
        guard !enabled else { return (true, nil, target) }
        return (false, Self.reason(item) ?? Self.standardReasons[NSStringFromSelector(action)], target)
    }

    /// The reason a disabled item's validation put in its tooltip (not what it does: that is its tooltip otherwise).
    static func reason(_ item: NSMenuItem) -> String? {
        item.toolTip.flatMap { $0.isEmpty || $0 == Commands.tip(for: item) ? nil : $0 }
    }

    /// AppKit's own commands are off for these reasons (the text ones in a field or an editor).
    static let standardReasons = [
        "undo:": "Nothing to undo.", "redo:": "Nothing to redo.", "unhideAllApplications:": "No other app is hidden.",
        "cut:": "Select some text first.", "copy:": "Select something first.", "paste:": "Nothing to paste here.",
        "delete:": "Select something first.", "selectAll:": "Nothing to select here.",
    ]

    /// The responder chain a command takes: `window`'s (a sheet's, then the window it is on), else the key window's (or,
    /// while AirSQL isn't the active app, the main window's) first responder up to its window and controller; then the
    /// app and its delegate.
    func target(for action: Selector, explicit: AnyObject?, in window: NSWindow? = nil) -> AnyObject? {
        if let explicit { return explicit.responds(to: action) ? explicit : nil }
        var chain: [AnyObject] = []
        let windows = window.map { [$0] + ($0.sheetParent.map { [$0] } ?? []) } ?? [NSApp.keyWindow, main?.window].compactMap { $0 }
        for window in windows where isOurs(window) {
            var responder: NSResponder? = window.firstResponder
            while let current = responder {
                chain.append(current)
                responder = current.nextResponder
            }
            if !chain.contains(where: { $0 === window }) { chain.append(window) }
            if let delegate = window.delegate { chain.append(delegate) }
            if let controller = window.windowController { chain.append(controller) }
        }
        chain.append(NSApp)
        if let delegate = NSApp.delegate { chain.append(delegate) }
        // As AppKit walks it: a responder that can't do it may name another that can.
        for responder in chain {
            if responder.responds(to: action) { return responder }
            if let extra = (responder as? NSResponder)?.supplementalTarget(forAction: action, sender: nil) { return extra as AnyObject }
        }
        return nil
    }

    // MARK: Buttons and fields

    /// What a click on `button` does (next state, then its action), without AppKit's tracking loop; a button with no
    /// target sends its action up its window's responder chain, as it would in the key window.
    @discardableResult
    func pressButton(_ button: NSButton) -> Bool {
        guard button.isEnabled, !Self.refusesDestructive(button) else { return false }
        if let cell = button.cell as? NSButtonCell, !cell.showsStateBy.isEmpty { button.setNextState() }
        guard let action = button.action else { return true }
        let target = button.target ?? target(for: action, explicit: nil, in: button.window)
        return NSApp.sendAction(action, to: target, from: button)
    }

    /// Where to look for a control: `in` (sheet, window:<title>), else the frontmost sheet or alert, then the windows.
    func scopes(_ spec: String?) throws -> [NSWindow] {
        if let spec, spec.hasPrefix("window:") {
            let title = spec.dropFirst("window:".count).trimmingCharacters(in: .whitespaces)
            guard let window = appWindows.first(where: { $0.title == title })
                    ?? appWindows.first(where: { $0.title.localizedCaseInsensitiveContains(title) })
            else { throw Failure("No window “\(title)”. There: " + appWindows.map(\.title).joined(separator: ", ")) }
            return sheets(of: window).reversed() + [window]
        }
        let open = openSheets()
        if let spec {
            switch spec {
            case "sheet":
                guard let sheet = open.last else { throw Failure("No sheet is open.") }
                return [sheet]
            case "popover":
                guard let popover = appWindows.flatMap(popovers(of:)).last else { throw Failure("No popover is shown.") }
                return [popover]
            default: throw Failure("in is \"sheet\", \"popover\" or \"window:<title>\".")
            }
        }
        // Not the windows a sheet covers: their controls can't be reached until it is answered.
        var result = open.reversed() + appWindows.flatMap(popovers(of:))
        result += [NSApp.keyWindow].compactMap { $0 }.filter { isOurs($0) && $0.attachedSheet == nil && !result.contains($0) }
        result += appWindows.filter { !result.contains($0) && $0.attachedSheet == nil }
        return result
    }

    private func press(_ arguments: [String: Any]) async throws -> [String: Any] {
        let id = arguments["id"] as? String, title = arguments["title"] as? String
        guard id != nil || title != nil else { throw Failure("press needs an id or a title.") }
        let windows = try scopes(arguments["in"] as? String)
        for window in windows {
            let nodes = self.nodes(window)
            let match = id.flatMap { id in nodes.first { $0.id == id && ($0.isPressable || $0.view != nil) } }
                ?? title.flatMap { title in
                    nodes.first { $0.isPressable && $0.title == title }
                        ?? nodes.first { $0.isPressable && normalized($0.title) == normalized(title) }
                }
            // A control the accessibility tree doesn't list (a popover's, off the screen): found by its id among the views.
            if match == nil, let id, let button = Self.views(NSButton.self, in: window.contentView?.superview ?? window.contentView)
                .first(where: { $0.accessibilityIdentifier() == id && !$0.isHiddenOrHasHiddenAncestor }) {
                guard button.isEnabled else { throw Failure("“\(id)” is disabled now" + (button.toolTip.map { ": " + $0 } ?? ".")) }
                try checkAgentMayAct(in: window, pressing: button.title)
                return await perform { self.pressButton(button) }
            }
            guard let node = match else { continue }
            try checkAgentMayAct(in: window, pressing: node.title)
            guard node.enabled else {
                throw Failure("“\(id ?? title ?? "")” is disabled now" + (node.help.map { ": " + $0 } ?? "."))
            }
            guard node.role != "popupbutton" && node.role != "menubutton" else {
                throw Failure("“\(id ?? title ?? "")” opens a menu: choose its option with set (value: the option's title).")
            }
            if let button = node.view as? NSButton, node.object === button || node.object === button.cell {
                return await perform { self.pressButton(button) }
            }
            return await perform { _ = node.press() }
        }
        if arguments["in"] == nil, let sheet = openSheets().last {
            throw Failure("Nothing to press called “\(id ?? title ?? "")” in the sheet that is open: answer or close it first. "
                          + describe(sheetJSON(sheet)))
        }
        throw Failure("Nothing to press called “\(id ?? title ?? "")”. Use snapshot (include: [\"sheets\", \"elements\"]).")
    }

    private func set(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let value = arguments["value"] else { throw Failure("set needs a value.") }
        guard let query = (arguments["id"] as? String) ?? (arguments["title"] as? String) else {
            throw Failure("set needs an id or a title (a label, title or placeholder).")
        }
        for window in try scopes(arguments["in"] as? String) where !(window is NSSavePanel) {
            guard let node = field(query, in: nodes(window)) ?? viewField(query, in: window) else { continue }
            guard node.enabled else { throw Failure("“\(query)” is disabled now" + (node.help.map { ": " + $0 } ?? ".")) }
            try checkAgentMayAct(in: window)
            if let text = value as? String { try await checkPersonAllows(text, into: node.view) }
            try set(node, to: value)
            return await acted()
        }
        throw Failure("No field “\(query)”. Use snapshot (include: [\"sheets\", \"elements\"]) to see the fields.")
    }

    /// A field by id, title or placeholder, or "password" for the password field.
    private func field(_ query: String, in nodes: [AXNode]) -> AXNode? {
        if let node = nodes.first(where: { $0.id == query && $0.isField || $0.id == query && $0.view is NSTextView }) { return node }
        let wanted = normalized(query)
        let fields = nodes.filter(\.isField)
        if let node = fields.first(where: { normalized($0.title) == wanted }) ?? fields.first(where: { normalized($0.placeholder) == wanted }) {
            return node
        }
        if ["password", "passphrase"].contains(wanted) { return fields.first(where: \.isSecure) }
        return nil
    }

    /// A text view or field the accessibility tree doesn't list (the console's editor), by its id among the views.
    private func viewField(_ id: String, in window: NSWindow) -> AXNode? {
        Self.views(NSView.self, in: window.contentView).first { view in
            (view is NSTextView || view is NSTextField) && view.accessibilityIdentifier() == id && !view.isHiddenOrHasHiddenAncestor
                && !hidesData(view)
        }.map { AXNode(object: $0) }
    }

    private func set(_ node: AXNode, to value: Any) throws {
        let text: String
        switch value {
        case let string as String: text = string
        case let flag as NSNumber where CFGetTypeID(flag) == CFBooleanGetTypeID(): text = flag.boolValue ? "true" : "false"
        case let number as NSNumber: text = number.stringValue
        default: text = "\(value)"
        }
        let on = ["true", "on", "yes", "1"].contains(text.lowercased())
        switch node.view {
        case let popup as NSPopUpButton:
            let item = try choice(text, in: popup.menu)
            if let menu = popup.menu, let index = menu.items.firstIndex(of: item), item.action != nil {
                menu.performActionForItem(at: index)
            } else {
                popup.select(item)
                popup.sendAction(popup.action, to: popup.target)
            }
        case let segments as NSSegmentedControl:
            guard let index = (0..<segments.segmentCount).first(where: { normalized(segments.label(forSegment: $0) ?? "") == normalized(text) })
            else { throw Failure("“\(text)” isn't one of the choices.") }
            segments.selectedSegment = index
            segments.sendAction(segments.action, to: segments.target)
        case let field as NSTextField:
            guard let window = field.window else { throw Failure("The field isn't in a window.") }
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView {
                editor.selectAll(nil)
                editor.insertText(text, replacementRange: editor.selectedRange())
            } else {
                field.stringValue = text
            }
            // As leaving the field does: its action (a setting saved, a number checked).
            window.makeFirstResponder(nil)
            if let action = field.action { field.sendAction(action, to: field.target) }
        case let textView as NSTextView:
            textView.window?.makeFirstResponder(textView)
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            guard textView.shouldChangeText(in: all, replacementString: text), let storage = textView.textStorage else {
                throw Failure("The text can't be changed now.")
            }
            storage.replaceCharacters(in: all, with: NSAttributedString(string: text, attributes: textView.typingAttributes))
            textView.didChangeText()
        case let button as NSButton where node.role == "checkbox":
            if (button.state == .on) != on { AXNode.click(button) }
        default:
            throw Failure("“\(node.title.isEmpty ? node.id : node.title)” (\(node.role)) can't be set; press it instead.")
        }
    }

    /// The pop-up menu's item that `text` chooses: the one with that title, else one with it as a part.
    private func choice(_ text: String, in menu: NSMenu?) throws -> NSMenuItem {
        if let menu { menu.delegate?.menuNeedsUpdate?(menu) }
        let titles = (menu?.items ?? []).filter { !$0.isSeparatorItem }
        let matches = titles.filter { $0.title == text }.nilIfEmpty
            ?? titles.filter { normalized($0.title) == normalized(text) }.nilIfEmpty
            ?? titles.filter { $0.title.localizedCaseInsensitiveContains(text) }
        guard matches.count == 1, let item = matches.first else {
            throw Failure("“\(text)” \(matches.isEmpty ? "isn't one" : "matches more than one") of the choices: "
                          + titles.map(\.title).filter { !$0.isEmpty }.joined(separator: ", "))
        }
        guard item.isEnabled else { throw Failure("“\(item.title)” can't be chosen now" + (item.toolTip.map { ": " + $0 } ?? ".")) }
        return item
    }

    // MARK: Select

    /// Selects by name, as a person clicks: connections in the sidebar (pane sidebar), a tab (pane tabs), or rows of a
    /// list in a sheet or window (`in`).
    private func select(_ arguments: [String: Any]) async throws -> [String: Any] {
        let names = (arguments["names"] as? [String]) ?? (arguments["names"] as? String).map { [$0] } ?? []
        let none = arguments["none"] as? Bool == true
        guard !names.isEmpty || none else {
            throw Failure("select needs pane and names, e.g. {\"pane\": \"sidebar\", \"names\": [\"Production\"]} (or none: true).")
        }
        switch (arguments["pane"] as? String)?.lowercased() {
        case "sidebar"?:
            guard let main else { throw Failure("AirSQL's window isn't there.") }
            if let sheet = main.window?.attachedSheet {
                throw Failure("A sheet is open in AirSQL's window: answer or close it first. " + describe(sheetJSON(sheet)))
            }
            var ids: [UUID] = []
            for name in names {
                guard let connection = model.data.connections.first(where: { $0.displayName == name })
                        ?? model.data.connections.first(where: { $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame })
                else { throw Failure("No connection “\(name)”. There: " + model.data.connections.map(\.displayName).joined(separator: ", ")) }
                ids.append(connection.id)
            }
            main.sidebar.select(ids)
            return await acted(["selected": main.sidebar.selectedConnectionIDs.count])
        case "tabs"?:
            guard let main, let name = names.first else { throw Failure("select tabs needs names: [the tab's title].") }
            guard let tab = main.tabs.first(where: { $0.title == name }) else {
                throw Failure("No tab “\(name)”. There: " + main.tabs.map(\.title).joined(separator: ", "))
            }
            main.select(tab)
            return await acted()
        default:
            for window in try scopes(arguments["in"] as? String) {
                for table in Self.views(NSTableView.self, in: window.contentView) where !hidesData(table) {
                    let rows = none ? IndexSet() : IndexSet((0..<table.numberOfRows).filter { row in
                        (0..<table.numberOfColumns).contains { column in
                            let cell = table.view(atColumn: column, row: row, makeIfNecessary: true)
                            return Self.views(NSTextField.self, in: cell).contains { names.contains($0.stringValue) }
                        }
                    })
                    if none || !rows.isEmpty {
                        try checkAgentMayAct(in: window)
                        table.selectRowIndexes(rows, byExtendingSelection: false)
                        return await acted(["selected": rows.count])
                    }
                }
            }
            throw Failure("No list shows \(names.joined(separator: ", ")).")
        }
    }

    static func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    // MARK: Keys, text and clicks

    /// The window keys and text go to: `spec`'s, else the frontmost sheet or alert, else the key or main window.
    private func keyWindow(_ spec: String?) throws -> NSWindow {
        if let spec {
            guard let window = try scopes(spec).first else { throw Failure("No window “\(spec)”.") }
            return window
        }
        if let sheet = openSheets().last { return sheet }
        if let key = NSApp.keyWindow, isOurs(key) { return key }
        return try mainWindow
    }

    private func key(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let combo = arguments["combo"] as? String else { throw Failure("key needs a combo, e.g. \"cmd+shift+n\".") }
        let keys = try KeyCombo(combo)
        let window = try keyWindow(arguments["in"] as? String)
        try checkAgentMayAct(in: window)
        try checkAgentMayPress(keys, in: window)
        (window.sheetParent ?? window).orderFront(nil)
        return await perform { self.sendKey(keys, to: window) }
    }

    private func sendKey(_ keys: KeyCombo, to window: NSWindow) {
        let (down, up) = keys.events(window: window)
        if window.isKeyWindow {
            NSApp.sendEvent(down)
            NSApp.sendEvent(up)
            return
        }
        // AirSQL isn't the active app (the tests' process never is): key equivalents as AppKit tries them (the
        // window's first, for every key: Return presses the default button), then the menu bar's, else the window.
        var handled = window.performKeyEquivalent(with: down)
        if !handled, !keys.modifiers.intersection([.command, .control]).isEmpty || keys.base.unicodeScalars.first.map({ $0.value >= 0xF700 }) == true {
            if let item = menuItems(for: keys).first {
                let check = validate(item, in: window)
                if check.enabled, let target = check.target, let action = item.action {
                    handled = NSApp.sendAction(action, to: target, from: item)
                }
            }
        }
        if !handled, keys.modifiers.isEmpty, ["\r", "\u{3}"].contains(keys.base),
           let button = window.defaultButtonCell, button.isEnabled, let control = button.controlView as? NSButton {
            AXNode.click(control)
            handled = true
        }
        if !handled {
            window.sendEvent(down)
            window.sendEvent(up)
        }
    }

    /// The menu-bar items with this shortcut, in menu order (the first one decides, enabled or not, as in AppKit).
    func menuItems(for keys: KeyCombo) -> [NSMenuItem] {
        func walk(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item -> [NSMenuItem] in
                (item.submenu.map(walk) ?? []) + (Self.matches(item.keyEquivalent, item.keyEquivalentModifierMask, keys) ? [item] : [])
            }
        }
        return NSApp.mainMenu.map(walk) ?? []
    }

    /// Whether a menu item's or a button's key equivalent is `keys`.
    static func matches(_ equivalent: String, _ mask: NSEvent.ModifierFlags, _ keys: KeyCombo) -> Bool {
        guard !equivalent.isEmpty else { return false }
        var modifiers = mask.intersection([.command, .control, .option, .shift])
        if equivalent.lowercased() != equivalent { modifiers.insert(.shift) }
        // Menus write ⌫ as backspace (8), the Delete key types DEL (127).
        let key = equivalent == "\u{8}" ? "\u{7f}" : equivalent.lowercased()
        return key == keys.base && modifiers == keys.modifiers
    }

    private func type(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let text = arguments["text"] as? String else { throw Failure("type needs text.") }
        let window = try keyWindow(arguments["in"] as? String)
        try checkAgentMayAct(in: window)
        if let editor = window.firstResponder as? NSTextView {
            try await checkPersonAllows(text, into: editor)
            editor.insertText(text, replacementRange: editor.selectedRange())
            return await acted()
        }
        guard text.count <= 1000 else {
            throw Failure("That's long to type key by key (\(text.count) characters): focus a text field first, or use set.")
        }
        await Self.later { for character in text { self.sendKey(KeyCombo(character: character), to: window) } }
        return await acted()
    }

    /// A click at x, y (points from the top left of the main window, or of `in`): `count` 2 double-clicks, `button`
    /// right right-clicks (the reply lists the menu it opens; `menu path="context > …"` chooses from it), `modifiers`
    /// ("cmd", "shift") extend a selection. Lists are clicked as AppKit's own click would select (their mouse tracking
    /// pulls events, which a test process can't survive); other views get the mouse events.
    private func click(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let x = (arguments["x"] as? NSNumber)?.doubleValue, let y = (arguments["y"] as? NSNumber)?.doubleValue else {
            throw Failure("click needs x and y: points from the top left of the main window (a screenshot at scale 1).")
        }
        let right = (arguments["button"] as? String)?.lowercased() == "right"
        let count = max(1, min(arguments["count"] as? Int ?? 1, 3))
        let modifiers = try KeyCombo.modifiers(arguments["modifiers"] as? String ?? "")
        let base = try (arguments["in"] as? String).map { try scopes($0).last! } ?? mainWindow
        let point = NSPoint(x: base.frame.minX + x, y: base.frame.maxY - y)
        let window = (openSheets() + popovers(of: base)).reversed().first { $0.frame.contains(point) } ?? base
        try checkAgentMayAct(in: window)
        window.layoutIfNeeded()  // as AppKit lays a window out before it handles an event
        let location = NSPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
        guard let frameView = window.contentView?.superview ?? window.contentView, let hit = frameView.hitTest(location) else {
            throw Failure("Nothing at \(Int(x)), \(Int(y)).")
        }
        func event(_ type: NSEvent.EventType, clicks: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
        }
        if right {
            guard let down = event(.rightMouseDown, clicks: 1) else { throw Failure("Can't make the click.") }
            for view in sequence(first: hit, next: \.superview) {
                if let menu = view.menu(for: down) {
                    contextMenu = (menu, window)
                    return await acted(["menu": menuJSON(menu, in: window)])
                }
            }
            throw Failure("Nothing at \(Int(x)), \(Int(y)) has a context menu.")
        }
        if let table = sequence(first: hit, next: \.superview).first(where: { $0 is NSTableView }) as? NSTableView {
            let row = table.row(at: table.convert(location, from: nil))
            window.makeFirstResponder(table)
            if row < 0 {
                table.deselectAll(nil)
            } else if modifiers.contains(.command) {
                if table.selectedRowIndexes.contains(row) { table.deselectRow(row) } else {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
                }
            } else if modifiers.contains(.shift), let anchor = table.selectedRowIndexes.first {
                table.selectRowIndexes(IndexSet(integersIn: min(anchor, row)...max(anchor, row)), byExtendingSelection: false)
            } else {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            if count >= 2, row >= 0, let action = table.doubleAction {
                return await perform { NSApp.sendAction(action, to: table.target, from: table) }
            }
            return await acted(["row": row])
        }
        if let button = sequence(first: hit, next: \.superview).first(where: { $0 is NSButton }) as? NSButton {
            guard button.isEnabled else { throw Failure("“\(button.title)” is disabled now" + (button.toolTip.map { ": " + $0 } ?? ".")) }
            return await perform { self.pressButton(button) }
        }
        if let field = hit as? NSTextField, field.isEditable {
            window.makeFirstResponder(field)
            return await acted()
        }
        // The view that takes the click: not an AppKit control inside it (a label, an image), whose mouse tracking pulls
        // events.
        let taker = sequence(first: hit, next: \.superview).first { !($0 is NSControl) } ?? hit
        return await perform {
            for clicks in 1...count {
                guard let down = event(.leftMouseDown, clicks: clicks), let up = event(.leftMouseUp, clicks: clicks) else { continue }
                taker.mouseDown(with: down)
                taker.mouseUp(with: up)
            }
        }
    }

    // MARK: Wait

    /// Polls until the condition holds: a sheet (with `text` in it), no sheet, a popover, idle (no work running), or
    /// `text` anywhere in the windows; at most `timeout` seconds.
    private func wait(_ arguments: [String: Any]) async throws -> [String: Any] {
        let until = (arguments["until"] as? String ?? "").lowercased()
        let timeout = min(max((arguments["timeout"] as? NSNumber)?.doubleValue ?? 30, 0), 600)
        let text = arguments["text"] as? String
        let check: () -> [String: Any]?
        switch until {
        case "sheet":
            check = { [self] in
                openSheets().reversed().map(sheetJSON).first { text == nil || describe($0).localizedCaseInsensitiveContains(text!) }
            }
        case "no_sheet":
            check = { [self] in openSheets().isEmpty ? [:] : nil }
        case "popover":
            check = { [self] in
                let shown = appWindows.flatMap(popovers(of:))
                return shown.isEmpty ? nil : ["popovers": shown.compactMap { $0.contentViewController?.view.accessibilityIdentifier() }]
            }
        case "idle":
            check = { [self] in model.activity.isIdle ? activityJSON() : nil }
        case "text":
            guard let text, !text.isEmpty else { throw Failure("wait text needs text.") }
            check = { [self] in
                let windows = appWindows.flatMap { [$0] + sheets(of: $0) + popovers(of: $0) }
                let strings = windows.flatMap { nodes($0) }.compactMap { $0.value as? String ?? ($0.title.isEmpty ? nil : $0.title) }
                return strings.contains { $0.contains(text) } ? ["found": text] : nil
            }
        default:
            throw Failure("until is one of: sheet, no_sheet, popover, idle, text.")
        }
        let started = Date()
        while true {
            if let found = check() { return found }
            if Date().timeIntervalSince(started) > timeout {
                throw Failure("Timed out after \(Int(timeout)) s waiting for \(until). Now: "
                              + describe(snapshot(["include": ["sheets", "activity"]])))
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: Screenshots

    private func screenshot(_ arguments: [String: Any]) throws -> [String: Any] {
        let target = arguments["target"] as? String ?? "main"
        let scale = CGFloat(min(max((arguments["scale"] as? NSNumber)?.doubleValue ?? 1, 1), 2))
        var window = try mainWindow, crop: NSRect?
        if target == "sheet" {
            guard let sheet = openSheets().last else { throw Failure("No sheet is open.") }
            window = sheet
        } else if target.hasPrefix("window:") {
            window = try scopes(target).last!
        } else if target.hasPrefix("element:") {
            let id = String(target.dropFirst("element:".count))
            guard let node = ([window] + sheets(of: window)).flatMap({ nodes($0) }).first(where: { $0.id == id }) else {
                throw Failure("No element “\(id)”.")
            }
            crop = NSRect(x: node.frame.minX - window.frame.minX, y: node.frame.minY - window.frame.minY,
                          width: node.frame.width, height: node.frame.height)
        } else if target != "main" {
            throw Failure("target is main, sheet, window:<title> or element:<id>.")
        }
        guard window.frame.width > 0 else { throw Failure("The window is closed.") }
        guard var image = composite(window, scale: scale) else { throw Failure("AirSQL couldn't draw the window.") }
        if let crop {
            let pixels = CGRect(x: crop.minX * scale, y: (window.frame.height - crop.maxY) * scale,
                                width: crop.width * scale, height: crop.height * scale).integral
            guard let cropped = image.cropping(to: pixels) else { throw Failure("The element is outside the window.") }
            image = cropped
        }
        guard let png = Self.png(image) else { throw Failure("AirSQL couldn't make the PNG.") }
        return Self.imageReply(png, ["width": image.width, "height": image.height, "scale": scale, "target": target])
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// A PNG and its JSON as one tool result.
    static func imageReply(_ png: Data, _ json: [String: Any]) -> [String: Any] {
        ["content": [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]
            + (text(json)["content"] as? [[String: Any]] ?? []), "isError": false]
    }

    /// The window as the person sees it: its frame (title bar and toolbar) and content, its sheets and the popovers and
    /// panels over it at their places.
    func composite(_ window: NSWindow, scale: CGFloat) -> CGImage? {
        let size = window.frame.size
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        canvas.size = size  // points: before the context is made, which takes its scale from it
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        var overlays = sheets(of: window)
        // Windows over it, back to front: its popovers, an app-modal alert, and AirSQL's panels over it. Not AppKit's other
        // helper windows (a toolbar's), which aren't what the person sees.
        overlays += NSApp.windows.filter(\.isVisible).sorted { $0.orderedIndex > $1.orderedIndex }.filter { other in
            other !== window && other.sheetParent == nil && !overlays.contains(other)
                && ((other.parent === window && other.className.contains("Popover")) || other === NSApp.modalWindow
                    || (otherWindows().contains(other) && other is NSPanel && other.level.rawValue >= window.level.rawValue))
                && other.frame.intersects(window.frame)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        Self.drawingAsKey([window] + overlays) {
            draw(window, overlays, size: size, in: context)
            for shown in [window] + overlays {
                coverHidden(in: shown, at: NSPoint(x: shown.frame.minX - window.frame.minX, y: shown.frame.minY - window.frame.minY))
            }
        }
        return canvas.cgImage
    }

    /// Runs `draw` with `windows` drawing as the key, active windows they are in use: behind other apps, or while the
    /// screen is locked, a window draws as inactive. AppKit's key and main appearance is lent to them for the drawing
    /// only: Core Animation commits after it, so the screen never shows the change.
    static func drawingAsKey(_ windows: [NSWindow], _ draw: () -> Void) {
        let lent = windows.filter { !$0.isKeyWindow }
        func send(_ name: String) {
            let selector = NSSelectorFromString(name)
            for window in lent where window.responds(to: selector) { _ = window.perform(selector) }
        }
        send("acquireKeyAppearance")
        send("acquireMainAppearance")
        defer {
            send("resignMainAppearance")
            send("resignKeyAppearance")
        }
        draw()
    }

    private func draw(_ window: NSWindow, _ overlays: [NSWindow], size: NSSize, in context: NSGraphicsContext) {
        // The window's background in its appearance (light or dark): the title bar and glass are see-through.
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            Self.ground(of: window).setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        Self.draw(window, at: .zero)
        for other in overlays {
            let origin = NSPoint(x: other.frame.minX - window.frame.minX, y: other.frame.minY - window.frame.minY)
            if other is NSSavePanel {
                let rect = NSRect(origin: origin, size: other.frame.size)
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
                continue
            }
            Self.draw(other, at: origin)
            // A sheet's glass background comes out in the window's colour: its edge shows where it is.
            if other.sheetParent === window {
                other.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.separatorColor.setStroke()
                    NSBezierPath(rect: NSRect(origin: origin, size: other.frame.size).insetBy(dx: 0.5, dy: 0.5)).stroke()
                }
            }
        }
    }

    static func draw(_ window: NSWindow, at origin: NSPoint) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        drawFrame(view, of: window, at: origin)
    }

    /// The layers under `root` that the window server colours with a vibrant colour matrix, and that matrix's 20
    /// numbers. A layer's image of itself (cacheDisplay) knows no filters: they came out black.
    private static func vibrantLayers(_ root: CALayer) -> [(layer: CALayer, matrix: [Float])] {
        var found: [(layer: CALayer, matrix: [Float])] = []
        func walk(_ layer: CALayer) {
            guard !layer.isHidden, layer.opacity > 0 else { return }
            for filter in layer.filters ?? [] where "\(filter)".hasPrefix("vibrantColorMatrix") {
                // Text and symbols (leaf layers), not the glass platters behind toolbar items (containers): rendered
                // again, a platter came out upside down in a corner.
                guard layer.sublayers?.isEmpty ?? true else { return }
                guard let value = (filter as AnyObject).value(forKey: "inputColorMatrix") as? NSValue else { continue }
                var matrix = [Float](repeating: 0, count: 20)
                value.getValue(&matrix, size: MemoryLayout<Float>.size * 20)
                found.append((layer, matrix))
                return
            }
            layer.sublayers?.forEach(walk)
        }
        walk(root)
        return found
    }

    /// Draws a vibrant layer as the window server would: its own image through its colour matrix, at its place.
    private static func drawVibrant(_ layer: CALayer, matrix m: [Float], root: CALayer, origin: NSPoint) {
        var rect = layer.convert(layer.bounds, to: root)
        var ancestor = layer.superlayer
        while let current = ancestor, current !== root {
            if current.masksToBounds { rect = rect.intersection(current.convert(current.bounds, to: root)) }
            ancestor = current.superlayer
        }
        let scale = NSGraphicsContext.current?.cgContext.ctm.a ?? 1
        let width = Int((layer.bounds.width * scale).rounded(.up)), height = Int((layer.bounds.height * scale).rounded(.up))
        // A layer the window took out while it drew itself (SwiftUI replaces the toolbar's) has no place any more: drawn
        // at its own origin, it put an upside-down copy over the window's bottom left corner.
        guard ancestor === root, !rect.isEmpty, width > 0, height > 0, width * height < 4_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -layer.bounds.minX, y: -layer.bounds.minY)
        if layer.contentsAreFlipped() {
            context.translateBy(x: 0, y: layer.bounds.maxY + layer.bounds.minY)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let rendered = context.makeImage() else { return }
        let filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(CIImage(cgImage: rendered).unpremultiplyingAlpha(), forKey: kCIInputImageKey)
        for (index, key) in ["inputRVector", "inputGVector", "inputBVector", "inputAVector"].enumerated() {
            let row = Array(m[(index * 5)..<(index * 5 + 4)]).map(CGFloat.init)
            filter.setValue(CIVector(x: row[0], y: row[1], z: row[2], w: row[3]), forKey: key)
        }
        filter.setValue(CIVector(x: CGFloat(m[4]), y: CGFloat(m[9]), z: CGFloat(m[14]), w: CGFloat(m[19])), forKey: "inputBiasVector")
        guard let output = filter.outputImage?.premultiplyingAlpha(),
              let image = CIContext().createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height)),
              let cg = NSGraphicsContext.current?.cgContext else { return }
        let place = layer.convert(layer.bounds, to: root).offsetBy(dx: origin.x, dy: origin.y)
        cg.saveGState()
        cg.clip(to: rect.offsetBy(dx: origin.x, dy: origin.y))
        cg.draw(image, in: place)
        cg.restoreGState()
    }

    private static func drawFrame(_ view: NSView, of window: NSWindow, at origin: NSPoint) {
        func place(_ view: NSView, opaque: Bool) {
            draw(view, in: view.convert(view.bounds, to: nil).offsetBy(dx: origin.x, dy: origin.y), opaque: opaque)
        }
        func named(_ view: NSView) -> String { NSStringFromClass(Swift.type(of: view)) }
        view.layoutSubtreeIfNeeded()
        // Backdrops (blur, the scroll edge "pockets") and Liquid Glass platters are the window server's: drawn here they
        // come out white. The window's background (drawn first) shows instead.
        let backdrops = views(NSView.self, in: view).filter { view in
            !view.isHidden && (named(view) == "NSScrollPocket" || named(view).contains("GlassEffect") && named(view).hasSuffix("RootView_")
                || ["CABackdropLayer", "CAPortalLayer"].contains(view.layer.map { NSStringFromClass(Swift.type(of: $0)) } ?? ""))
        }
        backdrops.forEach { $0.isHidden = true }
        defer { backdrops.forEach { $0.isHidden = false } }
        let vibrant = view.layer.map(vibrantLayers) ?? []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let opacities = vibrant.map(\.layer.opacity)
        vibrant.forEach { $0.layer.opacity = 0 }
        // A popover's window is see-through around its bubble, which it draws itself, edge and arrow included.
        let opaque = !window.className.contains("Popover")
        draw(view, in: NSRect(origin: origin, size: window.frame.size), opaque: opaque)
        // Once the window has lost the focus (to a popover or a sheet), the frame's picture of itself on macOS 26 can carry
        // a stale, upside-down copy of a toolbar item into the content: the (opaque) content is drawn again over it.
        if let content = window.contentView, content !== view, !content.bounds.isEmpty { place(content, opaque: opaque) }
        // Liquid Glass (macOS 26): the window server draws what is inside a glass container in the content, so the
        // cached image has only the platter. What it holds is drawn again on top, and the title bar over that. Not the
        // toolbar's platters: the cached image has their items, and drawing them again put a mirrored copy in a corner.
        let titlebar = views(NSView.self, in: view).first { named($0) == "NSTitlebarContainerView" }
        let holders = views(NSView.self, in: view).filter { holder in
            named(holder).hasSuffix("ContentHolderView") && (window.contentView.map { holder.isDescendant(of: $0) } ?? false)
        }
        let contents = holders.flatMap(\.subviews).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty }
        contents.forEach { place($0, opaque: true) }
        zip(vibrant, opacities).forEach { $0.0.layer.opacity = $0.1 }
        CATransaction.commit()
        if let root = view.layer {
            for (layer, matrix) in vibrant { drawVibrant(layer, matrix: matrix, root: root, origin: origin) }
        }
        if !contents.isEmpty, let titlebar { place(titlebar, opaque: false) }
    }

    /// `opaque`: on the window's background colour, as on screen.
    /// What a window shows behind its views; an alert's is clear, over glass a picture doesn't have.
    private static func ground(of window: NSWindow?) -> NSColor {
        guard let color = window?.backgroundColor, color.alphaComponent > 0 else { return .windowBackgroundColor }
        return color
    }

    private static func draw(_ view: NSView, in rect: NSRect, opaque: Bool) {
        guard let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        if opaque, let context = NSGraphicsContext(bitmapImageRep: cached) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                Self.ground(of: view.window).setFill()
                NSRect(origin: .zero, size: cached.size).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        view.cacheDisplay(in: view.bounds, to: cached)
        cached.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    }
}

/// A key combination: "cmd+shift+n", "return", "escape", "down", "f5", "a".
struct KeyCombo {
    var base: String
    var modifiers: NSEvent.ModifierFlags
    var keyCode: UInt16
    var characters: String

    private static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]
    /// Named keys: key code and the character AppKit gives them.
    private static let named: [String: (UInt16, Int)] = [
        "return": (36, 13), "enter": (76, 3), "tab": (48, 9), "space": (49, 32), "delete": (51, 127), "backspace": (51, 127),
        "escape": (53, 27), "esc": (53, 27), "forwarddelete": (117, NSDeleteFunctionKey), "home": (115, NSHomeFunctionKey),
        "end": (119, NSEndFunctionKey), "pageup": (116, NSPageUpFunctionKey), "pagedown": (121, NSPageDownFunctionKey),
        "left": (123, NSLeftArrowFunctionKey), "right": (124, NSRightArrowFunctionKey), "down": (125, NSDownArrowFunctionKey),
        "up": (126, NSUpArrowFunctionKey), "period": (47, 46), "comma": (43, 44), "plus": (24, 43), "minus": (27, 45),
        "f1": (122, NSF1FunctionKey), "f2": (120, NSF2FunctionKey), "f3": (99, NSF3FunctionKey), "f4": (118, NSF4FunctionKey),
        "f5": (96, NSF5FunctionKey), "f6": (97, NSF6FunctionKey), "f7": (98, NSF7FunctionKey), "f8": (100, NSF8FunctionKey),
        "f9": (101, NSF9FunctionKey), "f10": (109, NSF10FunctionKey), "f11": (103, NSF11FunctionKey), "f12": (111, NSF12FunctionKey),
    ]

    static func modifiers(_ text: String) throws -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for part in text.lowercased().split(separator: "+").map(String.init) where !part.isEmpty {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.command)
            case "shift", "⇧": flags.insert(.shift)
            case "opt", "option", "alt", "⌥": flags.insert(.option)
            case "ctrl", "control", "⌃": flags.insert(.control)
            default: throw AgentServer.Failure("Unknown modifier “\(part)”: cmd, shift, option, control.")
            }
        }
        return flags
    }

    init(_ combo: String) throws {
        var parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if combo.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }  // "cmd++"
        let key = parts.popLast() ?? ""
        modifiers = try Self.modifiers(parts.joined(separator: "+"))
        let lower = key.lowercased()
        if let (code, character) = Self.named[lower] {
            // ⇧Tab types backtab (U+0019), as a keyboard does, so key bindings see insertBacktab:.
            let character = lower == "tab" && modifiers.contains(.shift) ? 0x19 : character
            base = String(UnicodeScalar(UInt32(character)).map(Character.init) ?? " ")
            keyCode = code
            characters = base
        } else if key.count == 1, let code = Self.codes[lower] {
            base = lower
            keyCode = code
            characters = modifiers.contains(.shift) ? key.uppercased() : lower
        } else {
            throw AgentServer.Failure("Unknown key “\(key)”: a letter, digit or punctuation, or return, escape, tab, space, "
                                      + "delete, forwarddelete, up, down, left, right, home, end, pageup, pagedown, f1…f12.")
        }
    }

    /// A character typed (no key code when it isn't on the keyboard map: the text still arrives).
    init(character: Character) {
        let text = String(character)
        base = text.lowercased()
        keyCode = Self.codes[base] ?? 0
        modifiers = text != base ? .shift : []
        characters = text
    }

    func events(window: NSWindow) -> (down: NSEvent, up: NSEvent) {
        // A keyboard flags its function keys, and the arrows as the numeric pad's too: macOS 26 takes ⌘ and an arrow
        // without them for a plain arrow.
        var flags = modifiers
        if let key = base.unicodeScalars.first?.value, key >= 0xF700 {
            flags.insert(.function)
            if key <= 0xF703 { flags.insert(.numericPad) }
        }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            // AppKit's "characters ignoring modifiers" keep Shift.
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: modifiers.contains(.shift) ? base.uppercased() : base,
                             isARepeat: false, keyCode: keyCode)!
        }
        return (event(.keyDown), event(.keyUp))
    }
}

extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
