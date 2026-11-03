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
