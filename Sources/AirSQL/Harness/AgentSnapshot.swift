// Ported from AirSCP 1.4.0 Sources/AirSCP/AgentSnapshot.swift: AXNode (the in-process accessibility tree), the
// snapshot's windows, sheets and menus; the sections are AirSQL's.
import AirSQLCore
import AppKit

/// One node of a window's accessibility tree, as VoiceOver reads it: an AppKit view or cell. Read through key-value
/// coding, because some nodes answer the NSAccessibility getters without declaring the protocol.
@MainActor
struct AXNode {
    let object: NSObject
    /// Data an agent may not read (`AgentServer.hidesData`): no value, title, help or children (a status figure's title
    /// is a sum, a filter's tooltip its condition).
    var hidden = false

    private func get(_ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    private func text(_ key: String) -> String? {
        (get(key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "AXButton" → "button".
    var role: String { short(text("accessibilityRole") ?? "") }
    var subrole: String { short(text("accessibilitySubrole") ?? "") }
    /// Its accessibility id (AppKit's cells have their control's), or the view's identifier. AppKit's own "_NS:…"
    /// numbers aren't ids anyone could know.
    var id: String {
        let ids = [text("accessibilityIdentifier"), (object as? NSCell)?.controlView?.accessibilityIdentifier(),
                   view?.identifier?.rawValue]
        return ids.compactMap { $0 }.first { !$0.isEmpty && !$0.hasPrefix("_NS:") } ?? ""
    }
    var title: String { hidden ? "" : text("accessibilityTitle") ?? text("accessibilityLabel") ?? "" }
    var placeholder: String { text("accessibilityPlaceholderValue") ?? "" }
    /// Its help text (a tooltip): a disabled button's often says why. A segment says what its control says.
    var help: String? {
        guard !hidden else { return nil }
        if let help = text("accessibilityHelp") ?? view?.toolTip.flatMap({ $0.isEmpty ? nil : $0 }) { return help }
        guard role == "radiobutton", let parent = get("accessibilityParent") as? NSObject else { return nil }
        return AXNode(object: parent).text("accessibilityHelp")
    }
    var enabled: Bool {
        if let textView = view as? NSTextView { return textView.isEditable }  // its AX "enabled" is always off
        return (get("isAccessibilityEnabled") as? Bool) ?? true
    }
    /// Screen coordinates (origin bottom left).
    var frame: NSRect { (get("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    var children: [AXNode] { (get("accessibilityChildren") as? [Any] ?? []).compactMap { ($0 as? NSObject).map { AXNode(object: $0) } } }
    var parent: AXNode? { (get("accessibilityParent") as? NSObject).map { AXNode(object: $0) } }
    /// The AppKit control behind the node, if any.
    var view: NSView? { object as? NSView ?? (object as? NSCell)?.controlView }
    var isSecure: Bool { subrole == "securetextfield" || view is NSSecureTextField }

    /// The value as shown; a password field's as "•••(n)".
    var value: Any? {
        guard !hidden, let value = get("accessibilityValue") else { return nil }
        if isSecure { return "•••(\((value as? String)?.count ?? 0))" }
        switch value {
        case let text as String: return text.isEmpty ? nil : text
        case let number as NSNumber: return number
        default: return nil
        }
    }

    var isField: Bool {
        ["textfield", "textarea", "checkbox", "popupbutton", "combobox", "slider", "radiobutton", "menubutton"].contains(role)
    }

    var isPressable: Bool {
        ["button", "checkbox", "radiobutton", "menubutton", "popupbutton", "link", "disclosuretriangle"].contains(role)
    }

    /// A click on `button` as AppKit's would do it (next state, then its action), for agents.
    @discardableResult
    static func click(_ button: NSButton) -> Bool {
        guard button.isEnabled, !AgentServer.refusesDestructive(button) else { return false }
        if let cell = button.cell as? NSButtonCell, !cell.showsStateBy.isEmpty { button.setNextState() }
        if let action = button.action { button.sendAction(action, to: button.target) }
        return true
    }

    func press() -> Bool {
        if let button = view as? NSButton, object === button || object === button.cell {
            // What a click does, without performClick's tracking loop: that pulls events, which starts AppKit's event
            // thread, whose wake-ups (CFRunLoopStop on the main run loop) end any run loop but NSApp's own: in the test
            // process (no NSApp.run) the next one ended the process.
            return Self.click(button)
        }
        // A segment: chosen as a click chooses it, without the click's tracking loop.
        let parent = get("accessibilityParent") as? NSObject
        if let segments = view as? NSSegmentedControl ?? parent as? NSSegmentedControl
            ?? (parent as? NSCell)?.controlView as? NSSegmentedControl,
           !title.isEmpty, let index = (0..<segments.segmentCount).first(where: {
            segments.label(forSegment: $0) == title || segments.toolTip(forSegment: $0) == title
        }) {
            guard segments.isEnabled(forSegment: index) else { return false }
            segments.selectedSegment = index
            segments.sendAction(segments.action, to: segments.target)
            return true
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        _ = object.perform(selector)
        return true
    }

    private func short(_ role: String) -> String {
        (role.hasPrefix("AX") ? String(role.dropFirst(2)) : role).lowercased()
    }

    /// The nodes under `root`, depth first. A sheet on it is a window of its own (flattened by itself). A short list's
    /// rows (up to 200 cells) are walked from its table. Views `hiding` names come without their value and children.
    static func flatten(_ root: NSObject, hiding: ((NSView) -> Bool)? = nil) -> [AXNode] {
        var result: [AXNode] = []
        func walk(_ node: AXNode, _ depth: Int) {
            guard depth == 0 || !(node.object is NSWindow) else { return }
            // AppKit lists some controls by their cell (a button, a label): hidden with the control.
            if let view = node.view, hiding?(view) == true { return result.append(AXNode(object: view, hidden: true)) }
            result.append(node)
            guard depth < 40 else { return }
            guard ["table", "outline", "list", "browser", "grid"].contains(node.role) else { return node.children.forEach { walk($0, depth + 1) } }
            guard let table = node.view as? NSTableView, table.numberOfRows * max(table.numberOfColumns, 1) <= 200 else { return }
            for row in 0..<table.numberOfRows {
                for column in 0..<table.numberOfColumns {
                    if let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) { walk(AXNode(object: cell), depth + 1) }
                }
            }
        }
        walk(AXNode(object: root), 0)
        return result
    }

    /// As JSON, with the frame in points from the top left of `reference` (a screenshot's pixels at scale 1).
    func json(relativeTo reference: NSWindow?) -> [String: Any] {
        var json: [String: Any] = ["role": role, "enabled": enabled]
        if !id.isEmpty { json["id"] = id }
        if !title.isEmpty { json["title"] = title }
        if let value { json["value"] = value }
        if hidden { json["hidden"] = AgentServer.hiddenNote }
        if !placeholder.isEmpty { json["placeholder"] = placeholder }
        if let help { json["help"] = help }
        if let reference {
            let rect = frame, base = reference.frame
            let values = [rect.minX - base.minX, base.maxY - rect.maxY, rect.width, rect.height]
            // Rows scrolled out of a list can have no place (an infinite frame): no frame then.
            if values.allSatisfy(\.isFinite) { json["frame"] = values.map { ($0 * 2).rounded() / 2 } }
        }
        return json
    }
}

/// The snapshot's sections, read from the controllers' own state (nothing secret: no Keychain reads, password fields
/// as "•••(n)").
extension AgentServer {
    static let defaultSections: Set<String> = ["sidebar", "tabs", "status", "activity", "sheets"]

    func snapshot(_ arguments: [String: Any]) -> [String: Any] {
        let include = (arguments["include"] as? [String]).map(Set.init) ?? Self.defaultSections
        var result: [String: Any] = ["windows": windowsJSON(), "content": main?.contentKind ?? "",
                                     "appearance": model.data.settings.appearance.rawValue]
        if include.contains("sidebar") { result["sidebar"] = sidebarJSON() }
        if include.contains("tabs") { result["tabs"] = tabsJSON() }
        if include.contains("status") { result["status"] = statusJSON() }
        if include.contains("activity") { result["activity"] = activityJSON() }
        if include.contains("sheets") { result["sheets"] = sheetsJSON() }
        if include.contains("menus") { result["menus"] = menusJSON() }
        if let menu = contextMenu { result["contextMenu"] = menuJSON(menu.menu, in: menu.window) }
        if include.contains("elements"), let window = (arguments["in"] as? String).flatMap({ try? scopes($0).last }) ?? main?.window {
            let windows = [window] + sheets(of: window) + popovers(of: window)
            windows.forEach { $0.layoutIfNeeded() }  // the places a click will find, not those before a pending layout
            result["elements"] = windows.flatMap { nodes($0) }
                .filter { !["group", "splitgroup", "scrollarea", "unknown"].contains($0.role) || !$0.id.isEmpty }
                .map { $0.json(relativeTo: window) }
        }
        if include.contains("settings"),
           let data = try? JSONEncoder().encode(model.data.settings), let settings = try? JSONSerialization.jsonObject(with: data) {
            result["settings"] = settings
        }
        return result
    }

    // MARK: Windows and sheets

    private func windowsJSON() -> [[String: Any]] {
        appWindows.map { window in
            let frame = window.frame
            return ["title": window.title, "key": window.isKeyWindow, "visible": window.isVisible,
                    "frame": [frame.minX, frame.minY, frame.width, frame.height], "sheets": sheets(of: window).map(sheetTitle)]
        }
    }

    /// The windows an agent works with: the main window (also while closed) and AirSQL's other windows on screen
    /// (Settings), which have titles: not AppKit's untitled ones, such as a menu while it is open (Recent Filters lists
    /// conditions, the status bar's figure sums). Tests, which share NSApp with other tests' windows, give their own list.
    var appWindows: [NSWindow] {
        let main = self.main?.window
        return (main.map { [$0] } ?? []) + otherWindows().filter { window in
            window !== main && window.isVisible && window.sheetParent == nil && !(window.windowController is MainWindowController)
                && !window.title.isEmpty && !window.className.contains("Popover")
        }
    }

    /// Whether `window` (or the window it is a sheet of) is one of `appWindows`.
    func isOurs(_ window: NSWindow?) -> Bool {
        var root = window
        while let parent = root?.sheetParent { root = parent }
        if let child = root, child.className.contains("Popover"), let parent = child.parent { root = parent }
        return root.map { root in appWindows.contains { $0 === root } } ?? false
    }

    /// The sheets on `window`, outermost first.
    func sheets(of window: NSWindow) -> [NSWindow] {
        var result: [NSWindow] = []
        var current = window.attachedSheet
        while let sheet = current {
            result.append(sheet)
            current = sheet.attachedSheet
        }
        return result
    }

    /// The popovers shown over `window`.
    func popovers(of window: NSWindow) -> [NSWindow] {
        (window.childWindows ?? []).filter { $0.className.contains("Popover") && $0.isVisible }
    }

    /// Every open sheet and app-modal alert, frontmost last.
    func openSheets() -> [NSWindow] {
        var result = appWindows.flatMap(sheets(of:))
        if let modal = NSApp.modalWindow, !result.contains(modal), otherWindows().contains(modal) { result.append(modal) }
        return result
    }

    private func sheetTitle(_ sheet: NSWindow) -> String {
        nodes(sheet).first { $0.role == "statictext" }.flatMap { $0.value as? String } ?? sheet.title
    }

    func sheetsJSON() -> [[String: Any]] {
        openSheets().map(sheetJSON)
    }

    func sheetJSON(_ sheet: NSWindow) -> [String: Any] {
        if sheet is NSSavePanel {
            return ["kind": "panel", "title": sheet.title, "note": "Open and Save panels can't be driven: press Cancel."]
        }
        let nodes = self.nodes(sheet)
        var texts: [String] = [], fields: [[String: Any]] = [], buttons: [[String: Any]] = []
        for node in nodes {
            if node.role == "statictext", let text = node.value as? String {
                texts.append(text)
            } else if node.role == "button" || node.role == "radiobutton" {
                var button: [String: Any] = ["title": node.title, "enabled": node.enabled]
                if let help = node.help { button["help"] = help }  // what it does, or (off) why not
                if let control = node.view as? NSButton, control.keyEquivalent == "\r" || control.window?.defaultButtonCell === control.cell {
                    button["default"] = true
                }
                if let control = node.view as? NSButton, control.hasDestructiveAction { button["destructive"] = true }
                if !node.title.isEmpty { buttons.append(button) }
            } else if node.isField || node.role == "textarea" {
                var field = node.json(relativeTo: nil)
                if node.isSecure { field["secure"] = true }
                if let popup = node.view as? NSPopUpButton { field["options"] = popup.itemTitles.filter { !$0.isEmpty } }
                fields.append(field)
            }
        }
        var json: [String: Any] = ["kind": sheet.sheetParent == nil ? "alert" : "sheet", "buttons": buttons, "fields": fields]
        json["title"] = texts.first ?? sheet.title
        if texts.count > 1 { json["text"] = texts.dropFirst().joined(separator: "\n") }
        return json
    }

    // MARK: AirSQL's window

    private func sidebarJSON() -> [String: Any] {
        guard let main else { return [:] }
        let selected = Set(main.sidebar.selectedConnectionIDs)
        let sections = model.sections(filter: main.sidebar.filter.stringValue).map { section -> [String: Any] in
            ["folder": section.folder?.name ?? NSNull(), "connections": section.connections.map { connection -> [String: Any] in
                var json: [String: Any] = ["name": connection.displayName, "route": connection.routeBadge,
                                           "colour": connection.colour.rawValue, "state": stateText(model.states[connection.id])]
                if connection.hasCustomSafety { json["customSafety"] = true }
                if selected.contains(connection.id) { json["selected"] = true }
                return json
            }]
        }
        return ["filter": main.sidebar.filter.stringValue, "sections": sections,
                "selected": main.sidebar.selectedConnectionIDs.compactMap { model.connection($0)?.displayName }]
    }

    private func tabsJSON() -> [[String: Any]] {
        guard let main else { return [] }
        return main.tabs.map { tab -> [String: Any] in
            var json: [String: Any] = ["title": tab.title, "selected": tab === main.selectedTab]
            if let name = model.connection(tab.connectionID)?.displayName { json["connection"] = name }
            if tab.tabContent?.isEdited == true { json["edited"] = true }
            return json
        }
    }

    private func statusJSON() -> [String: Any] {
        guard let bar = main?.statusBar else { return [:] }
        var json: [String: Any] = [:]
        for (key, item) in [("route", bar.route), ("server", bar.server), ("transaction", bar.transaction), ("activity", bar.activity),
                            ("agent", bar.agent)] where !item.isHidden {
            json[key] = item.value
        }
        json["sqlLog"] = ["enabled": bar.sqlLog.isEnabled]
        return json
    }

    func activityJSON() -> [String: Any] {
        let now = model.activity.now()
        return ["idle": model.activity.isIdle, "running": model.activity.running.map { activity -> [String: Any] in
            var json: [String: Any] = ["title": activity.title, "seconds": Int(activity.elapsed(at: now)), "canCancel": activity.canCancel]
            if let name = model.connection(activity.connection)?.displayName { json["connection"] = name }
            if let progress = activity.progress { json["percent"] = Int(progress * 100) }
            if let detail = activity.detail { json["detail"] = detail }
            if activity.cancelling { json["cancelling"] = true }
            return json
        }]
    }

    // MARK: Menus

    /// Every menu-bar item with an action: its path, shortcut, whether it is enabled now and, when known, why not.
    func menusJSON() -> [[String: Any]] {
        var result: [[String: Any]] = []
        func walk(_ menu: NSMenu, _ path: [String]) {
            update(menu)
            for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.isAlternate {
                if let submenu = item.submenu {
                    if submenu !== NSApp.servicesMenu { walk(submenu, path + [item.title]) }
                    continue
                }
                guard item.action != nil else { continue }
                let check = validate(item)
                var json: [String: Any] = ["path": (path + [item.title]).joined(separator: " > "), "enabled": check.enabled]
                if !item.keyEquivalent.isEmpty { json["shortcut"] = Command.shortcut(item.keyEquivalent, item.keyEquivalentModifierMask) }
                if item.state == .on { json["state"] = "on" }
                if let reason = check.reason, !check.enabled { json["reason"] = reason }
                result.append(json)
            }
        }
        if let bar = NSApp.mainMenu {
            for top in bar.items where !top.isHidden { if let submenu = top.submenu { walk(submenu, [top.title]) } }
        }
        return result
    }

    /// A context menu's items as a right-click shows them: title, shortcut, enabled (validated against `window`'s
    /// responder chain) and why not, and their submenus.
    func menuJSON(_ menu: NSMenu, in window: NSWindow?) -> [[String: Any]] {
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map { item -> [String: Any] in
            var json: [String: Any] = ["title": item.title]
            if let submenu = item.submenu {
                json["items"] = menuJSON(submenu, in: window)
                json["enabled"] = item.isEnabled
                if let tip = item.toolTip { json["help"] = tip }
                return json
            }
            let check = validate(item, in: window)
            json["enabled"] = check.enabled
            if let tip = item.toolTip { json["help"] = tip }
            if let reason = check.reason, !check.enabled { json["reason"] = reason }
            if !item.keyEquivalent.isEmpty { json["shortcut"] = Command.shortcut(item.keyEquivalent, item.keyEquivalentModifierMask) }
            if item.state == .on { json["state"] = "on" }
            return json
        }
    }
}
