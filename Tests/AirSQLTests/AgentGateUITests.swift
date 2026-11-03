import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// An agent's tool call through the agent service (as the bridge makes it), its reply read as the harness's tests read
/// theirs.
@MainActor
func agentCall(_ service: AgentService, _ tool: String, _ arguments: [String: Any] = [:]) async -> Reply {
    let reply = await service.handle(tool, arguments, client: "Claude Code")
    let content = reply["content"] as? [[String: Any]] ?? []
    var result = Reply()
    let text = content.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
    if reply["isError"] as? Bool == true {
        result.error = text
    } else {
        result.json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    if let data = (content.first { $0["type"] as? String == "image" }?["data"] as? String).flatMap({ Data(base64Encoded: $0) }) {
        result.image = NSBitmapImageRep(data: data)
    }
    return result
}

/// The gate against everything an agent could try through AirSQL's windows (plan §2.8): each write path stops at the
/// SQL preview sheet, which only the person can approve; settings, saved connections, files and the clipboard stay the
/// person's. "The person" is the harness without an agent: the tests' own clicks.
extension AppTests {
    @MainActor @Suite struct AgentGateUITests {
        /// A window with the shop's connections, agents on, the agent service driving it, and the person's harness.
        static func agents(_ connections: [SavedConnection] = Fixtures.shop, windows: [NSWindow] = [])
            async throws -> (MainWindowController, AgentServer, AgentService) {
            let model = testModel(connections)
            let (main, harness) = appWindow(model, windows: { windows })
            let service = AgentService(model: model, main: main, directory: URL(fileURLWithPath: try scratch() + "/agent"))
            service.harness = AgentServer(main: main, model: model, windows: { windows })
            model.data.settings.agentsAllowed = true
            #expect(await eventually(timeout: 5) { service.isListening && AgentGate.approve != nil })
            return (main, harness, service)
        }

        /// A new console on `connection`, opened by the person. The connection counts as connected, to a port where no
        /// server answers: what runs fails to connect (the test resets `ConsoleViewController.openConnection`).
        static func console(_ main: MainWindowController, _ harness: AgentServer, on connection: UUID) async throws
            -> ConsoleViewController {
            let stand = Connection(options: ConnectOptions(name: "Stand-in", host: "127.0.0.1", port: 1, user: "root", connectTimeout: 2))
            ConsoleViewController.openConnection = { $0 == connection ? stand : nil }
            main.model.states[connection] = .connected(server: "MariaDB 11.8")
            main.sidebar.select([connection])
            #expect(await call(harness, "menu", ["path": "File > New Query"]).error == nil)
            return try #require(main.selectedTab?.content as? ConsoleViewController)
        }

        static func preview(_ main: MainWindowController) -> SQLPreviewSheet? {
            main.window?.attachedSheet?.windowController as? SQLPreviewSheet
        }

        @Test func aConsoleWriteWaitsForThePersonWhateverTheAgentPresses() async throws {
            let (main, harness, service) = try await Self.agents()
            defer {
                service.close()
                ConsoleViewController.openConnection = { _ in nil }
            }
            let console = try await Self.console(main, harness, on: Fixtures.local.id)
            #expect(await agentCall(service, "type", ["text": "UPDATE orders SET status = 'paid' WHERE id = 7"]).error == nil)
            // The person's own run of this asks nothing on Local (its safety settings are the defaults); the agent's does.
            #expect(await agentCall(service, "key", ["combo": "cmd+return"]).error == nil)
            #expect(await agentCall(service, "wait", ["until": "sheet", "timeout": 10]).error == nil)
            let sheet = try #require(Self.preview(main))
            #expect(sheet.window?.title == "Run this statement on Local MariaDB 11.8?")
            let content = try #require(sheet.window?.contentView)
            let banner = try #require(find(SurfaceView.self, id: "preview.agent", in: content))
            #expect(banner.accessibilityLabel()?.hasPrefix("Asked by Claude Code.") == true)

            for (tool, arguments) in [("press", ["id": "preview.run"]), ("press", ["title": "Run"]), ("key", ["combo": "return"]),
                                      ("key", ["combo": "enter"]), ("menu", ["path": "Edit > Paste"])] as [(String, [String: Any])] {
                let refused = await agentCall(service, tool, arguments)
                #expect(refused.error != nil, "\(tool) \(arguments) was let through")
                #expect(Self.preview(main) === sheet, "\(tool) closed the sheet")
            }
            let button = try #require(await element(harness, "preview.run", in: "sheet"))
            let click = await agentCall(service, "click", ["x": button.center.0, "y": button.center.1, "in": "sheet"])
            #expect(click.error?.contains("Only the person at the Mac can approve") == true, "\(click.error ?? "")")
            #expect(Self.preview(main) === sheet && service.events.last?.failed == true)

            // The person approves: then it runs (here: says to connect first, as there is no server).
            #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
            #expect(await eventually(timeout: 5) { main.window?.attachedSheet == nil })
            #expect(await eventually(timeout: 10) { console.messagesView.messages.last?.level == .error }, "it ran: no server there")
        }

        @Test func readOnlyStatementsAndDeclinesNeedNoOne() async throws {
            let (main, harness, service) = try await Self.agents()
            defer {
                service.close()
                ConsoleViewController.openConnection = { _ in nil }
            }
            let console = try await Self.console(main, harness, on: Fixtures.local.id)
            let set = await agentCall(service, "set", ["id": "console.editor", "value": "SELECT id, total FROM orders"])
            #expect(set.error == nil, "\(set.error ?? "")")
            #expect(await agentCall(service, "key", ["combo": "cmd+return"]).error == nil)
            #expect(main.window?.attachedSheet == nil, "proven read-only: no question")
            #expect(await eventually(timeout: 10) { console.messagesView.messages.last?.level == .error }, "it ran: no server there")

            #expect(await agentCall(service, "set", ["id": "console.editor", "value": "DELETE FROM orders"]).error == nil)
            _ = await agentCall(service, "key", ["combo": "cmd+return"])
            _ = await agentCall(service, "wait", ["until": "sheet", "timeout": 10])
            let sheet = try #require(Self.preview(main))
            #expect(sheet.window?.title == "Delete every row of orders?", "the safety warning, and the agent's banner")
            #expect(await agentCall(service, "press", ["id": "preview.cancel"]).error == nil, "an agent may decline")
            #expect(await eventually(timeout: 5) { main.window?.attachedSheet == nil })
        }

        /// A sheet's answer (an alert's completion) belongs to whoever pressed it: the agent's carries the agent along.
        @Test func whatAnAgentAnswersStaysTheAgents() async throws {
            let (main, _, service) = try await Self.agents()
            defer { service.close() }
            var answeredBy: [String?] = []
            let alert = NSAlert()
            alert.messageText = "Commit the transaction?"
            alert.addButton(withTitle: "Commit")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: try #require(main.window)) { _ in
                answeredBy.append(AgentGate.agent)
                Task { answeredBy.append(AgentGate.agent) }
            }
            #expect(await agentCall(service, "press", ["title": "Commit"]).error == nil)
            #expect(await eventually(timeout: 5) { answeredBy.count == 2 })
            #expect(answeredBy == ["Claude Code", "Claude Code"])
        }

        @Test func theDriversQuestionIsThePreviewSheet() async throws {
            let (main, harness, service) = try await Self.agents()
            defer { service.close() }
            let request = AgentGate.Request(agent: "Claude Code", sql: "COMMIT", connection: Fixtures.local.displayName,
                                            noBackslashEscapes: false)
            let approved = Task { try await service.approve(request) }
            #expect(await eventually(timeout: 5) { Self.preview(main) != nil })
            #expect(Self.preview(main)?.window?.title == "Run this statement for Claude Code?")
            #expect(await agentCall(service, "press", ["id": "preview.run"]).error != nil)
            #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
            try await approved.value

            let declined = Task { try await service.approve(request) }
            #expect(await eventually(timeout: 5) { Self.preview(main) != nil })
            #expect(await call(harness, "press", ["id": "preview.cancel"]).error == nil)
            await #expect(throws: AirSQLError.self) { try await declined.value }

            // A connection whose safety settings let agents' changes through isn't asked about.
            var local = Fixtures.local
            local.safety = SafetySettings()
            local.safety?.askBeforeAgentChanges = false
            service.model.save(local)
            try await service.approve(request)
            #expect(main.window?.attachedSheet == nil)
        }
    }
}
