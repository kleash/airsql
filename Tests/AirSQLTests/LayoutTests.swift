import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// The polish standard (plan §2.13), checked by walking every window, sheet and popover in light and dark, at the
// window's minimum and default size, with long and odd content: no text that needs more room than it has without
// truncating (and a truncated one keeps its full text in a tooltip), nothing crossing a rounded parent's inset, no
// siblings on top of each other. Each lane adds its screens to `screens`.

/// What is wrong with the layout of `root`'s visible views: "where: problem".
@MainActor
func layoutProblems(_ root: NSView, where place: String) -> [String] {
    var problems: [String] = []
    func name(_ view: NSView) -> String {
        let text = (view as? NSTextField)?.stringValue ?? (view as? NSButton)?.title ?? ""
        let id = view.accessibilityIdentifier()
        return "\(type(of: view))" + (id.isEmpty ? "" : " \(id)") + (text.isEmpty ? "" : " “\(text.prefix(40))”")
    }
    func visible(_ view: NSView) -> Bool { !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0 && !view.frame.isEmpty }
    func tooltip(_ view: NSView, contains text: String) -> Bool {
        sequence(first: view, next: \.superview).contains { ($0.toolTip ?? "").contains(text) }
    }
    func walk(_ view: NSView) {
        guard visible(view) else { return }
        // Text that needs more room than it has.
        if let field = view as? NSTextField, !field.isEditable, let cell = field.cell, !field.stringValue.isEmpty {
            let bounds = field.bounds
            if cell.wraps {
                let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude)).height
                if needed > bounds.height + 1 && !cell.truncatesLastVisibleLine {
                    problems.append("\(place): \(name(field)) is cut: needs \(Int(needed)) points high, has \(Int(bounds.height))")
                }
            } else {
                let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: .greatestFiniteMagnitude, height: bounds.height)).width
                if needed > bounds.width + 1 {
                    switch field.lineBreakMode {
                    case .byTruncatingTail, .byTruncatingMiddle, .byTruncatingHead:
                        if !tooltip(field, contains: field.stringValue) {
                            problems.append("\(place): \(name(field)) is shortened without its whole text in a tooltip")
                        }
                        // Shortened, but not squeezed to an ellipsis: a good part of it stays readable.
                        if bounds.width < min(needed, 40) {
                            problems.append("\(place): \(name(field)) is squeezed to \(Int(bounds.width)) points")
                        }
                    default:
                        problems.append("\(place): \(name(field)) is cut: needs \(Int(needed)) points wide, has \(Int(bounds.width))")
                    }
                }
            }
        } else if let button = view as? NSButton, !(button is NSPopUpButton), !button.title.isEmpty, let cell = button.cell {
            let needed = cell.cellSize.width
            if needed > button.bounds.width + 1 {
                problems.append("\(place): \(name(button)) is cut: needs \(Int(needed)) points wide, has \(Int(button.bounds.width))")
            }
        }
        // Content crossing a rounded parent's inset (its corners), or outside it.
        let radius: CGFloat = (view as? SurfaceView)?.radius ?? (view is ChipView ? view.bounds.height / 2
            : (view.layer?.masksToBounds == true ? view.layer?.cornerRadius ?? 0 : 0))
        if radius > 0 {
            for inner in descendants(of: view) where visible(inner) && isLeaf(inner) {
                let rect = inner.convert(inner.bounds, to: view)
                if crosses(rect, view.bounds, radius: radius) {
                    problems.append("\(place): \(name(inner)) crosses the rounded edge of \(name(view)) (radius \(Int(radius)))")
                }
            }
        }
        // Siblings on top of each other.
        let leaves = view.subviews.filter { visible($0) && isLeaf($0) }
        for (index, first) in leaves.enumerated() {
            // A scroll view's two overlay scroll bars meet in its corner by AppKit's design.
            for second in leaves[(index + 1)...] where !(first is NSScroller && second is NSScroller) {
                let overlap = first.frame.intersection(second.frame)
                if !overlap.isNull, overlap.width * overlap.height > 1 {
                    problems.append("\(place): \(name(first)) and \(name(second)) overlap")
                }
            }
        }
        view.subviews.forEach(walk)
    }
    walk(root)
    return problems
}

/// Views whose overlap or clipping a person would see: controls, text, images, chips, dots, lines.
@MainActor
func isLeaf(_ view: NSView) -> Bool {
    view is NSControl || view is ChipView || view is DotView || view is NSProgressIndicator || view is StatusItemView
        || view is TabButton || view is Hairline
}

@MainActor
func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

/// Whether `rect` is outside `bounds` or reaches into a corner that a radius of `radius` cuts off.
func crosses(_ rect: NSRect, _ bounds: NSRect, radius r: CGFloat) -> Bool {
    let slack: CGFloat = 0.5
    if rect.minX < bounds.minX - slack || rect.maxX > bounds.maxX + slack || rect.minY < bounds.minY - slack
        || rect.maxY > bounds.maxY + slack { return true }
    let corners = [(NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: bounds.minX + r, y: bounds.minY + r)),
                   (NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: bounds.maxX - r, y: bounds.minY + r)),
                   (NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: bounds.minX + r, y: bounds.maxY - r)),
                   (NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: bounds.maxX - r, y: bounds.maxY - r))]
    for (point, center) in corners {
        let inCornerX = point.x < center.x ? point.x < bounds.minX + r : point.x > bounds.maxX - r
        let inCornerY = point.y < center.y ? point.y < bounds.minY + r : point.y > bounds.maxY - r
        guard inCornerX, inCornerY else { continue }
        if hypot(point.x - center.x, point.y - center.y) > r + slack { return true }
    }
    return false
}

extension AppTests {
    @MainActor @Suite struct LayoutTests {
        @Test func cornersAndOverlapsAreFound() {
            // The checks themselves: a label in a chip's corner, two buttons on top of each other.
            #expect(crosses(NSRect(x: 0, y: 0, width: 10, height: 10), NSRect(x: 0, y: 0, width: 100, height: 20), radius: 10))
            #expect(!crosses(NSRect(x: 10, y: 2, width: 80, height: 16), NSRect(x: 0, y: 0, width: 100, height: 20), radius: 10))
            #expect(crosses(NSRect(x: -1, y: 5, width: 10, height: 10), NSRect(x: 0, y: 0, width: 100, height: 20), radius: 0))
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
            let first = NSButton(title: "One", target: nil, action: nil), second = NSButton(title: "Two", target: nil, action: nil)
            first.frame = NSRect(x: 0, y: 0, width: 80, height: 30)
            second.frame = NSRect(x: 40, y: 0, width: 80, height: 30)
            root.addSubview(first)
            root.addSubview(second)
            let cut = NSTextField(labelWithString: "A label much wider than its frame")
            cut.frame = NSRect(x: 130, y: 0, width: 40, height: 20)
            root.addSubview(cut)
            let problems = layoutProblems(root, where: "test")
            #expect(problems.contains { $0.contains("overlap") } && problems.contains { $0.contains("is cut") }, "\(problems)")
        }

        @Test func everyScreenIsTidyInLightAndDarkAtEverySize() async throws {
            var problems: [String] = []
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for size in [MainWindowController.minimumSize, MainWindowController.defaultSize] {
                    let place = "\(appearance == .aqua ? "light" : "dark") \(Int(size.width))×\(Int(size.height))"
                    problems += try await screens(appearance: appearance, size: size, place: place)
                }
            }
            #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        }

        /// Every screen of this batch at one appearance and size: the first run, the sidebar with long and odd names (and
        /// a thousand connections), each summary, many tabs with long titles, every status item and its popover, the
        /// Settings panes, and the sheets.
        func screens(appearance: NSAppearance.Name, size: NSSize, place: String) async throws -> [String] {
            var problems: [String] = []
            func check(_ window: NSWindow, _ what: String) {
                window.appearance = NSAppearance(named: appearance)
                window.contentView?.layoutSubtreeIfNeeded()
                if let content = window.contentView { problems += layoutProblems(content, where: "\(place) \(what)") }
            }
            let (first, _) = appWindow(testModel(), size: size)
            check(first.window!, "first run")

            let many = (0..<1_000).map { SavedConnection(name: String(format: "replica-%04d", $0), host: "10.0.\($0 / 250).\($0 % 250)") }
            let model = testModel(Fixtures.shop + Fixtures.odd + many)
            let (main, harness) = appWindow(model, size: size)
            let window = try #require(main.window)
            check(window, "sidebar")
            for connection in Fixtures.odd + [Fixtures.production, Fixtures.local] {
                main.sidebar.select([connection.id])
                check(window, "summary of “\(connection.displayName.prefix(20))”")
            }
            model.states[Fixtures.production.id] = .connected(server: "MariaDB 11.8.3-MariaDB-ubu2404-log")
            model.agentStatus = "Claude Code · reading the schema of every database on this server"
            let content = FixtureContent(String(repeating: "SELECT * FROM orders WHERE status = 'paid'; ", count: 8))
            content.badge = "Transaction open · 2,481 changes"
            content.edited = true
            main.open(content, title: "Top customers by paid orders in the last ninety days.sql", connection: Fixtures.production.id)
            for index in 1...11 {
                main.open(FixtureContent(), title: "Query \(index) " + String(repeating: "long title ", count: index % 4),
                          connection: index % 2 == 0 ? Fixtures.staging.id : nil)
            }
            let work = model.activity.start("Exporting shop to shop-2026-11-02.sql.gz with mariadb-dump", connection: Fixtures.production.id) {}
            defer { work.end() }
            main.select(main.tabs[0])
            check(window, "tabs and status")
            let agents = AgentService(model: model, main: main, directory: URL(fileURLWithPath: try scratch() + "/agent"))
            for (index, summary) in ["context", "get_schema · Production · shop", "describe · orders, customers, order_items, "
                                     + "payments, shipments, returns", "run_queries · SELECT c.id, c.name, COUNT(o.id) AS orders "
                                     + "FROM customers c JOIN orders o … (+3)"].enumerated() {
                let event = agents.record("claude-code 2.1.31", summary)
                if index < 3 { agents.finish(event, index == 2 ? String(repeating: "No connection is open to agents ", count: 3) : "done",
                                             failed: index == 2) }
            }
            for item in [main.statusBar.route, main.statusBar.server, main.statusBar.transaction, main.statusBar.activity,
                         main.statusBar.agent] where !item.isHidden {
                if let popover = item.popover?() {
                    popover.view.appearance = NSAppearance(named: appearance)
                    popover.view.layoutSubtreeIfNeeded()
                    problems += layoutProblems(popover.view, where: "\(place) \(item.accessibilityIdentifier()) popover")
                }
            }

            let settings = SettingsWindowController(model: model)
            keptWindows.append(settings)
            settings.window?.setFrameOrigin(NSPoint(x: -21000, y: -21000))
            for pane in SettingsPane.allCases {
                settings.show(pane)
                check(settings.window!, "Settings ▸ \(pane.title)")
            }

            var request = SQLPreviewRequest(change: ChangeSQL(title: "Apply", statements: (1...40).map {
                "UPDATE `orders` SET `status` = 'refunded', `note` = 'Customer asked for a refund on 2 Nov' WHERE `id` = \($0)"
            }, connection: Fixtures.production.id), heading: "Apply 40 changes to shop.orders? " + String(repeating: "long ", count: 12),
                                            caption: "They run in one transaction. If one fails, none are kept and the grid points to the cell.")
            request.warnings = ["orders uses MyISAM: if one statement fails, the ones before it stay changed.",
                                "Deleting from customers also deletes rows in orders and payments (ON DELETE CASCADE)."]
            request.typeToConfirm = "orders"
            request.agent = "Claude Code"
            request.accessory = checkbox("Read new rows back (shows the new id)", id: "preview.readBack", tip: "Read the new rows",
                                         on: true, target: nil, action: nil)
            SQLPreviewSheet.changesetWriter = { _ in }
            defer { SQLPreviewSheet.changesetWriter = nil }
            SQLPreviewSheet.show(request, connection: Fixtures.production, on: window) { _ in }
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            if let sheet = window.attachedSheet { check(sheet, "SQL preview") }
            _ = await call(harness, "press", ["title": "Decline"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])

            // The client tools' sheets (L6), with long names, an error and work running.
            let export = ExportSheet(model: model, connection: ToolFixtures.local, options: ToolFixtures.options)
            export.show(on: window, loads: false)
            export.show(server: ToolFixtures.server, tools: ToolFixtures.dumps, databases: ToolFixtures.databases())
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            if let sheet = window.attachedSheet { check(sheet, "Export") }
            _ = export.begin("Exporting shop")
            export.progress("Writing this_table_name_is_sixty_four_characters_long_the_most_mysql_has · 1.9 GB of ≈3.1 GB", done: 19,
                            total: 31)
            if let sheet = window.attachedSheet { check(sheet, "Export running") }
            export.finish("mariadb-dump stopped: mariadb-dump: Got error: 1045: \"Access denied for user 'a_very_long_user_name'@'"
                          + "warehouse-primary-0001.analytics.internal.example.com' (using password: YES)\" when trying to connect",
                          failed: true)
            if let sheet = window.attachedSheet { check(sheet, "Export failed") }
            export.close()
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            let restore = RestoreSheet(model: model, connection: ToolFixtures.local, options: ToolFixtures.options, builtIn: true)
            restore.show(on: window, loads: false)
            restore.show(server: ToolFixtures.server, tools: ToolFixtures.clients, databases: ["this_database_name_is_sixty_four_characters_long_the_most_it_has"])
            restore.use(URL(fileURLWithPath: "/Volumes/Backups/" + String(repeating: "very long folder name/", count: 6) + "dump.sql"))
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            if let sheet = window.attachedSheet { check(sheet, "Run SQL File") }
            restore.close()
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            let copy = CopySheet(model: model, connection: ToolFixtures.local, options: ToolFixtures.options)
            copy.show(on: window, loads: false)
            copy.show(databases: ToolFixtures.databases())
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            if let sheet = window.attachedSheet { check(sheet, "Copy to Another Server") }
            copy.close()
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            let csv = CSVImportSheet(model: model, connection: ToolFixtures.local, options: ToolFixtures.options)
            csv.show(on: window, loads: false)
            csv.show(databases: ToolFixtures.databases())
            csv.show(columns: ToolFixtures.customerColumns)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            if let sheet = window.attachedSheet { check(sheet, "Import CSV") }
            csv.close()
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            try await connectionScreens(main, harness, check: check)
            return problems
        }
    }
}
