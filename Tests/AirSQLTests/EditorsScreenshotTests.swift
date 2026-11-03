import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// Light and dark pictures of the editors (the recorded fixture), for comparing with docs/dev/mockups.html screen 10.
// Only with AIRSQL_SCREENSHOTS=1: they go to build/screenshots.
extension AppTests {
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1")) struct EditorsScreenshotTests {
        private func save(_ harness: AgentServer, _ name: String) async throws {
            let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
            let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: AppTests.ScreenshotTests.folder.appendingPathComponent(name + ".png"))
        }

        @Test func editors() async throws {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let model = testModel(Fixtures.shop)
                model.states[Fixtures.local.id] = .connected(server: "MariaDB 11.8.9")
                let (main, harness) = appWindow(model)
                main.window?.appearance = NSAppearance(named: appearance)
                main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
                main.window?.orderFront(nil)
                main.sidebar.select([Fixtures.local.id])
                let context = try await recordedEditorContext()

                main.openTableEditor("orders", database: "airsql_fixture", context: context)
                let editor = try #require(main.selectedTab?.content as? TableEditorController)
                await ready { editor.isBusy || !editor.overlay.isHidden }
                editor.update { table in
                    var currency = ColumnDesign(name: "currency", type: TypeSpec(name: "char", length: "3"))
                    currency.nullable = false
                    currency.defaultValue = .value("EUR")
                    currency.collation = "utf8mb4_unicode_ci"
                    currency.comment = "ISO 4217"
                    table.columns.insert(currency, at: 5)
                    table.renameColumn(at: 6, to: "parent_order_id")
                }
                editor.reloadList()
                try await save(harness, "table-editor-\(suffix)")
                editor.sections.selectedSegment = TableEditorController.Section.indexes.rawValue
                editor.sectionChosen(editor.sections)
                try await save(harness, "table-editor-indexes-\(suffix)")
                editor.sections.selectedSegment = TableEditorController.Section.options.rawValue
                editor.sectionChosen(editor.sections)
                try await save(harness, "table-editor-options-\(suffix)")

                main.openObjectEditor(.procedure, name: "add_customer", database: "airsql_fixture", context: context)
                let object = try #require(main.selectedTab?.content as? ObjectEditorController)
                await ready { object.isBusy || !object.overlay.isHidden }
                try await save(harness, "procedure-editor-\(suffix)")

                main.openERDiagram(database: "airsql_fixture", context: context)
                let diagram = try #require(main.selectedTab?.content as? ERDiagramController)
                await ready { diagram.diagram == nil }
                diagram.canvas.selected = "orders"
                try await save(harness, "er-diagram-\(suffix)")
                main.window?.orderOut(nil)
            }
        }
    }
}
