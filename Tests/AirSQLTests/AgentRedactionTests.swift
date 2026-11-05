import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// What agents see of data (plan §2.8), and the UI tools through `AirSQL --mcp` end to end.
extension AppTests.AgentGateUITests {
    /// How many colours a patch of a scale-1 screenshot has (points from its top left): text has many, a cover few.
    static func colours(_ image: NSBitmapImageRep?, _ rect: NSRect) -> Int {
        guard let image else { return 0 }
        var seen = Set<UInt32>()
        for x in Int(rect.minX)..<Int(rect.maxX) {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert(UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8
                    | UInt32(color.blueComponent * 255))
            }
        }
        return seen.count
    }

    @Test func rowsOfConnectionsAgentsMayNotReadAreHidden() async throws {
        let (main, harness, service) = try await Self.agents()
        defer {
            service.close()
            ConsoleViewController.openConnection = { _ in nil }
        }
        let console = try await Self.console(main, harness, on: Fixtures.production.id)  // Schema access: no data
        ConsoleFixtures.dress(console)
        let window = try #require(main.window)
        window.layoutIfNeeded()
        let content = try #require(window.contentView)
        let scroll = try #require(find(DataGridView.self, in: content)?.enclosingScrollView)
        let frame = scroll.convert(scroll.bounds, to: nil)
        let patch = NSRect(x: frame.minX + 16, y: window.frame.height - frame.maxY + 16, width: min(160, frame.width - 32),
                           height: min(60, frame.height - 32))
        #expect(Self.colours(await call(harness, "screenshot").image, patch) > 4, "the person sees the rows")
        let agent = await agentCall(service, "screenshot")
        #expect(Self.colours(agent.image, patch) <= 3, "covered for the agent")
        let elements = (await agentCall(service, "snapshot", ["include": ["elements"]])["elements"] as? [[String: Any]]) ?? []
        #expect(elements.contains { $0["role"] as? String == "table" && ($0["hidden"] as? String)?.hasPrefix("Hidden from agents") == true })
        let own = (await call(harness, "snapshot", ["include": ["elements"]])["elements"] as? [[String: Any]]) ?? []
        #expect(!own.contains { $0["hidden"] != nil })

        // Schema + read: the agent sees them too.
        var production = Fixtures.production
        production.agentAccess = .schemaRead
        service.model.save(production)
        #expect(Self.colours(await agentCall(service, "screenshot").image, patch) > 4)
    }

    /// What a cell's value goes into shows agents nothing of rows they may not read: the cell's Quick Filter items, the
    /// status bar's figure, the result's conditions, Filter by Values' list and Type a Value…'s field. No menu shows them
    /// the person's clipboard, also where they may read the rows.
    @Test func filtersAndCellMenusShowAgentsNoHiddenValueNorTheClipboard() async throws {
        let (main, harness, service) = try await Self.agents()
        let board = NSPasteboard.general, kept = board.string(forType: .string)
        defer {
            service.close()
            ConsoleViewController.openConnection = { _ in nil }
            board.clearContents()
            if let kept { board.setString(kept, forType: .string) }
        }
        let console = try await Self.console(main, harness, on: Fixtures.production.id)  // Schema access: no data
        ConsoleFixtures.dress(console)
        let window = try #require(main.window)
        window.layoutIfNeeded()
        let content = try #require(window.contentView)
        let grid = try #require(find(DataGridView.self, in: content))
        func cell(_ row: Int, _ column: Int) -> [String: Any] {
            let rect = grid.convert(grid.cellRect(GridPosition(row: row, column: column)), to: nil)
            return ["x": rect.midX, "y": window.frame.height - rect.midY]
        }
        func text(_ reply: Reply) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data(), as: UTF8.self)
        }
        func agentSees() async -> String { text(await agentCall(service, "snapshot", ["include": ["elements", "sheets"]])) }
        board.clearContents()
        board.setString("clipboard-7Q2", forType: .string)
        // Row 1 (the result shows two rows under the editor): Nordlicht GmbH, 317 orders.
        let menu = await agentCall(service, "right_click", cell(1, 1))
        #expect(menu.error == nil && text(menu).contains("Equal to Selection"), "\(menu.error ?? text(menu))")
        let menus = text(menu) + (await agentSees())
        #expect(!menus.contains("Nordlicht") && !menus.contains("clipboard-7Q2"), "\(menus)")
        #expect(await agentCall(service, "click", cell(1, 3)).error == nil)
        let figure = await agentSees()
        #expect(grid.selection.cursor == GridPosition(row: 1, column: 3) && !figure.contains("Sum 317"), "\(figure.components(separatedBy: "Sum 317").first!.suffix(300))")

        #expect(await agentCall(service, "click", cell(1, 1)).error == nil)
        #expect(await agentCall(service, "menu", ["path": "Data > Quick Filter > Equal to Selection"]).error == nil)
        #expect(text(await call(harness, "snapshot", ["include": ["elements"]])).contains("Nordlicht"), "the person sees the filter")
        let filtered = await agentSees()
        #expect(!filtered.contains("Nordlicht"), "\(filtered.components(separatedBy: "Nordlicht").first!.suffix(300))")
        #expect(await agentCall(service, "menu", ["path": "Data > Filter by Values…"]).error == nil)
        #expect(await agentCall(service, "wait", ["until": "sheet", "timeout": 10]).error == nil)
        let values = try #require(window.attachedSheet?.contentView)
        #expect(await eventually(timeout: 10) { (find(NSTableView.self, id: "values.list", in: values)?.numberOfRows ?? 0) > 0 })
        #expect(!(await agentSees()).contains("Nordlicht"))
        #expect(await agentCall(service, "press", ["id": "values.cancel"]).error == nil)
        _ = await agentCall(service, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(await agentCall(service, "menu", ["path": "Data > Quick Filter > Type a Value…"]).error == nil)
        #expect(await agentCall(service, "wait", ["until": "sheet", "timeout": 10]).error == nil)
        #expect(!(await agentSees()).contains("Nordlicht"))
        #expect(await agentCall(service, "press", ["title": "Cancel"]).error == nil)
        _ = await agentCall(service, "wait", ["until": "no_sheet", "timeout": 10])

        // Schema + read: the rows show, the clipboard still doesn't.
        var production = Fixtures.production
        production.agentAccess = .schemaRead
        service.model.save(production)
        board.clearContents()
        board.setString("clipboard-7Q2", forType: .string)
        let readable = text(await agentCall(service, "right_click", cell(0, 1)))
        #expect(readable.contains("Equal to Selection") && !readable.contains("clipboard-7Q2"), "\(readable)")
    }

    /// A console's comparison with another connection's result shows that connection's rows too: hidden from agents
    /// unless they may read the data of both.
    @Test func aComparisonWithAnotherConnectionsResultIsHiddenUnlessBothMayBeRead() async throws {
        let (main, harness, service) = try await Self.agents()
        defer {
            service.close()
            ConsoleViewController.openConnection = { _ in nil }
        }
        var production = Fixtures.production
        production.agentAccess = .schemaRead
        service.model.save(production)
        let staging = try await Self.console(main, harness, on: Fixtures.staging.id)  // agents off
        staging.addResult(ConsoleFixtures.customers(rows: 5), title: "Customers", summary: "")
        let console = try await Self.console(main, harness, on: Fixtures.production.id)
        console.addResult(ConsoleFixtures.customers(rows: 8), title: "Customers", summary: "")
        console.showResults()
        func hidden() async -> Bool {
            let elements = (await agentCall(service, "snapshot", ["include": ["elements"]])["elements"] as? [[String: Any]]) ?? []
            return elements.contains { $0["role"] as? String == "table" && ($0["hidden"] as? String)?.hasPrefix("Hidden from agents") == true }
        }
        #expect(await !hidden(), "Production's own rows: Schema + read")
        console.compareResult(nil)
        let sheet = try #require(main.window?.attachedSheet?.contentView)
        let with = try #require(find(NSPopUpButton.self, id: "compare.with", in: sheet))
        #expect(with.titleOfSelectedItem == "Query 1 › Customers · 5 × 5")
        #expect(await call(harness, "press", ["title": "Compare"]).error == nil)
        #expect(await eventually(timeout: 10) { console.selectedResult?.title == "vs Query 1 › Customers" })
        #expect(console.selectedResult?.otherConnection == Fixtures.staging.id)
        #expect(await hidden(), "the comparison shows Staging's rows too")
    }

    /// What quotes a row's values hides with the rows: the console's Messages (a server's error), an EXPLAIN's tree and
    /// the SQL preview's statements below Schema + read; the SQL log (every connection's statements) from every agent.
    @Test func messagesPlansPreviewsAndTheSQLLogHideWithTheRows() async throws {
        let log = SQLLog(fileURL: URL(fileURLWithPath: try scratch() + "/SQL.log"))
        log.statement("UPDATE customers SET name = 'Nordlicht AG' WHERE id = 7", context: "Staging main:3", noBackslashEscapes: false)
        let viewer = SQLLogWindowController.show(log)
        keptWindows.append(viewer)
        viewer.window?.setFrameOrigin(NSPoint(x: -22000, y: -22000))
        let (main, harness, service) = try await Self.agents(windows: [try #require(viewer.window)])
        defer {
            service.close()
            viewer.close()
            ConsoleViewController.openConnection = { _ in nil }
        }
        func text(_ reply: Reply) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data(), as: UTF8.self)
        }
        func sees(_ person: AgentServer? = nil, in scope: String? = nil) async -> String {
            var arguments: [String: Any] = ["include": ["elements", "sheets"]]
            if let scope { arguments["in"] = scope }
            if let person { return text(await call(person, "snapshot", arguments)) }
            return text(await agentCall(service, "snapshot", arguments))
        }
        #expect(await eventually(timeout: 5) { !viewer.text.string.isEmpty })
        #expect(await sees(harness, in: "window:SQL Log").contains("Nordlicht"), "the person reads the log")
        #expect(await !sees(in: "window:SQL Log").contains("Nordlicht"), "no agent does")

        let console = try await Self.console(main, harness, on: Fixtures.production.id)  // Schema access: no data
        console.note(.error, "A row with the same key already exists. Error 1062 (23000): Duplicate entry 'Nordlicht AG' for key 'name'")
        #expect(await sees(harness).contains("Duplicate entry 'Nordlicht AG'"), "the person sees the message")
        let messages = await sees()
        #expect(messages.contains("console.messages") && !messages.contains("Nordlicht"), "\(messages)")
        let tree = "-> Filter: (customers.name = 'Nordlicht AG')"
        console.addPlan(table: nil, tree: tree, nodes: [], raw: tree, title: "Plan")
        #expect(await sees(harness).contains("Nordlicht"), "the person sees the plan's tree")
        #expect(await !sees().contains("Nordlicht"), "the agent doesn't")
        console.addPlan(table: nil, tree: tree, nodes: ExplainPlan.nodes(from: tree, json: false), raw: tree, title: "Plan")
        #expect(await sees(harness).contains("Nordlicht"), "the person sees the plan's steps")
        #expect(await !sees().contains("Nordlicht"), "the agent doesn't")
        for segment in [2, 3] {
            ((console.currentResult?.view as? PlanView)?.choice)?.selectedSegment = segment
            (console.currentResult?.view as? PlanView)?.show(page: segment)
            #expect(await sees(harness).contains("Nordlicht"), "the person sees the plan as text")
            #expect(await !sees().contains("Nordlicht"), "the agent doesn't")
        }
        let apply = SQLPreviewRequest(change: ChangeSQL(title: "Apply", statements: ["UPDATE customers SET name = 'Nordlicht AG' WHERE id = 7"],
                                                        connection: Fixtures.production.id),
                                      heading: "Apply 1 change to shop.customers?", caption: "It runs in one transaction.")
        SQLPreviewSheet.show(apply, connection: Fixtures.production, on: try #require(main.window)) { _ in }
        #expect(await call(harness, "wait", ["until": "sheet", "timeout": 10]).error == nil)
        let preview = await sees()
        #expect(preview.contains("Apply 1 change") && !preview.contains("Nordlicht"), "\(preview)")

        // Schema + read: the agent reads them, but still not the SQL log.
        var production = Fixtures.production
        production.agentAccess = .schemaRead
        service.model.save(production)
        #expect(await sees().contains("Nordlicht"))
        #expect(await call(harness, "press", ["id": "preview.cancel"]).error == nil)
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        console.selectResult(console.messagesTab)
        #expect(await sees().contains("Duplicate entry 'Nordlicht AG'"))
        #expect(await !sees(in: "window:SQL Log").contains("Nordlicht"))
    }

    /// A menu while it is open is an untitled window of AppKit's (Recent Filters lists conditions, the status bar's
    /// figure sums): not one of the windows agents look at.
    @Test func aMenuWhileItIsOpenIsNotTheAgents() async throws {
        let menu = NSWindow(contentRect: NSRect(x: -21000, y: -21000, width: 240, height: 30), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        menu.isReleasedWhenClosed = false
        menu.contentView = label("region = 'Nordlicht AG'")
        menu.orderFront(nil)
        let (_, _, service) = try await Self.agents(windows: [menu])
        defer {
            service.close()
            menu.orderOut(nil)
        }
        let shot = await agentCall(service, "screenshot", ["target": "window:"])
        #expect(shot.image == nil && shot.error?.hasPrefix("No window") == true, "\(shot.error ?? "an image")")
        #expect((await agentCall(service, "snapshot")["windows"] as? [[String: Any]])?.count == 1, "the main window only")
    }

    @Test func theUIToolsAndTheGateWorkThroughAirSQLMCP() async throws {
        let model = testModel(Fixtures.shop)
        let (main, harness) = appWindow(model)
        let support = try scratch()
        let service = AgentService(model: model, main: main, directory: URL(fileURLWithPath: support + "/agent"))
        service.harness = AgentServer(main: main, model: model, windows: { [] })
        model.data.settings.agentsAllowed = true
        #expect(await eventually(timeout: 5) { service.isListening })
        defer { service.close() }
        var approved: Bool?
        let preview = SQLPreviewRequest(change: ChangeSQL(title: "Edits", statements: ["DELETE FROM orders WHERE id = 7"],
                                                          connection: Fixtures.local.id),
                                        heading: "Delete 1 row from orders?", caption: "It runs in one transaction.")
        SQLPreviewSheet.show(preview, connection: Fixtures.local, on: try #require(main.window)) { approved = $0.approved }
        let messages = try await mcp([
            request(1, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code", "version": "2"]]),
            request(2, "tools/list"),
            request(3, "tools/call", ["name": "snapshot", "arguments": ["include": ["sheets"]]]),
            request(4, "tools/call", ["name": "press", "arguments": ["id": "preview.run"]]),
            request(5, "tools/call", ["name": "key", "arguments": ["combo": "return"]]),
            request(6, "tools/call", ["name": "screenshot", "arguments": ["target": "sheet"]]),
        ], support: support)
        let names = (result(messages, 2)?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        #expect(names.contains("double_click") && names.contains("snapshot"))
        let snapshot = try #require(result(messages, 3))
        #expect(snapshot["isError"] as? Bool == false && text(snapshot).contains("Delete 1 row from orders?"))
        for id in [4, 5] {
            let refused = try #require(result(messages, id))
            #expect(refused["isError"] as? Bool == true && text(refused).contains("Only the person at the Mac can approve"))
        }
        let image = (result(messages, 6)?["content"] as? [[String: Any]])?.first
        #expect(image?["type"] as? String == "image" && image?["mimeType"] as? String == "image/png")
        #expect(approved == nil && main.window?.attachedSheet != nil, "still waiting for the person")
        #expect(service.events.contains { $0.summary == "press · preview.run" && $0.failed })
        #expect(await call(harness, "press", ["id": "preview.cancel"]).error == nil)
        #expect(approved == false)
    }
}

/// The gate's look, light and dark, for review (AIRSQL_SCREENSHOTS=1: build/screenshots).
extension AppTests {
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1")) struct AgentGateScreenshots {
        @Test func theGateAndHiddenRows() async throws {
            let folder = ScreenshotTests.folder
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let (main, harness, service) = try await AgentGateUITests.agents()
                defer {
                    service.close()
                    ConsoleViewController.openConnection = { _ in nil }
                }
                main.window?.appearance = NSAppearance(named: appearance)
                main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
                let console = try await AgentGateUITests.console(main, harness, on: Fixtures.production.id)
                ConsoleFixtures.dress(console)
                main.window?.displayIfNeeded()
                func save(_ reply: Reply, _ name: String) throws {
                    let png = try #require(reply.image?.representation(using: .png, properties: [:]), "\(name): \(reply.error ?? "")")
                    try png.write(to: folder.appendingPathComponent(name + "-" + suffix + ".png"))
                }
                try save(await agentCall(service, "screenshot", ["scale": 2]), "agent-hidden-rows")
                let typing = Task { await agentCall(service, "type", ["text": "UPDATE orders SET status = 'refunded'\nWHERE id = 7;"]) }
                _ = await eventually(timeout: 5) { main.window?.attachedSheet != nil }
                try await Task.sleep(nanoseconds: 600_000_000)  // the sheet's slide down
                try save(await call(harness, "screenshot", ["target": "sheet", "scale": 2]), "agent-gate-text")
                _ = await call(harness, "press", ["id": "preview.run"])
                _ = await typing.value
                _ = await agentCall(service, "key", ["combo": "cmd+return"])
                _ = await eventually(timeout: 5) { main.window?.attachedSheet != nil }
                try await Task.sleep(nanoseconds: 600_000_000)
                try save(await call(harness, "screenshot", ["scale": 2]), "agent-gate-run")
                _ = await call(harness, "press", ["id": "preview.cancel"])
            }
        }
    }
}
