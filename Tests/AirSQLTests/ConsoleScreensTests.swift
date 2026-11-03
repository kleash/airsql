import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The console's screens (plan §2.12, §2.13): every control says what it does, nothing is cut or overlaps in light and
/// dark at the window's smallest and usual size, the editor answers clicks, and (AIRSQL_SCREENSHOTS=1) pictures of each
/// screen in build/screenshots.
extension AppTests {
    @MainActor @Suite struct ConsoleScreensTests {
        /// A dressed console on Production, in a window of `size`.
        static func window(size: NSSize = MainWindowController.defaultSize) async throws
            -> (MainWindowController, AgentServer, ConsoleViewController) {
            let model = testModel(Fixtures.shop)
            model.states[Fixtures.production.id] = .connected(server: "MariaDB 11.8.3")
            let (main, harness) = appWindow(model, size: size)
            main.sidebar.select([Fixtures.production.id])
            _ = await call(harness, "menu", ["path": "File > New Query"])
            let console = try #require(main.selectedTab?.content as? ConsoleViewController)
            main.rename(try #require(main.selectedTab), to: "Top customers.sql")
            ConsoleFixtures.dress(console)
            main.window?.layoutIfNeeded()
            return (main, harness, console)
        }

        /// The states each check walks: results, Messages, a plan, find and replace with the helpers, the history sheet.
        static func states(_ main: MainWindowController, _ harness: AgentServer, _ console: ConsoleViewController,
                           _ visit: (String, [NSWindow]) async -> Void) async throws {
            let window = try #require(main.window)
            await visit("console results", [window])
            console.selectResult(console.messagesTab)
            await visit("console messages", [window])
            console.addPlan(table: ConsoleFixtures.customers(rows: 3), tree: "-> Limit: 200 row(s)\n    -> Sort: spent DESC", title: "Plan")
            console.showResults()
            await visit("console plan", [window])
            console.findBar.show(replace: true)
            console.toggleHelpers(nil)
            window.layoutIfNeeded()
            await visit("console find and helpers", [window])
            console.findBar.close(nil)
            console.toggleHelpers(nil)
            for (sql, rows) in [("SELECT * FROM customers WHERE id = 10482", 1), ("SELECT status, COUNT(*) FROM orders GROUP BY status", 4),
                                (ConsoleFixtures.query.components(separatedBy: ";")[0], 200)] {
                QueryHistory.shared.add(HistoryEntry(sql: sql, connection: Fixtures.production.id, duration: 0.038, rows: rows))
            }
            QueryHistory.shared.flush()
            console.showHistory(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "wait", ["until": "text", "text": "statements", "timeout": 5])
            await visit("history", harness.openSheets())
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        }

        @Test func theHistoryRowsShareABaselineAndShowTheirResult() async throws {
            let (main, harness, console) = try await Self.window()
            let error = "The table 'orders_archive_2025' doesn't exist in the database 'shop', so nothing was read from it"
            QueryHistory.shared.add(HistoryEntry(sql: "SELECT * FROM orders_archive_2025", connection: Fixtures.production.id, error: error))
            QueryHistory.shared.flush()
            console.showHistory(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "wait", ["until": "text", "text": "statements", "timeout": 5])
            let sheet = try #require(main.window?.attachedSheet)
            let content = try #require(sheet.contentView)
            content.layoutSubtreeIfNeeded()
            let table = try #require(find(NSTableView.self, id: "history.list", in: content))
            let row = try #require((0..<table.numberOfRows).first { row in
                (table.view(atColumn: 2, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.toolTip == "Failed: " + error
            })
            let fields = try (0..<3).map { column in
                try #require((table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField)
            }
            fields.forEach { $0.superview?.layoutSubtreeIfNeeded() }
            let baselines = fields.map { $0.convert(NSPoint(x: 0, y: $0.firstBaselineOffsetFromTop), to: nil).y }
            #expect(baselines.allSatisfy { abs($0 - baselines[0]) < 0.5 }, "\(baselines)")
            // The Result column ends inside the list, so its text isn't cut off by the edge.
            let scroll = try #require(table.enclosingScrollView)
            #expect(table.rect(ofColumn: 2).maxX <= scroll.contentView.bounds.maxX + 1)
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        }

        @Test func findAndTheHelpersKeepTheWindowAtItsMinimumSize() async throws {
            let (main, _, console) = try await Self.window(size: MainWindowController.minimumSize)
            console.findBar.show(replace: true)
            console.toggleHelpers(nil)
            main.window?.layoutIfNeeded()
            #expect(main.window?.frame.width == MainWindowController.minimumSize.width)
            console.findBar.close(nil)
            console.toggleHelpers(nil)
        }

        @Test func theLineNumbersDrawNothingOverTheFindBar() async throws {
            let (main, harness, console) = try await Self.window()
            console.findBar.show(replace: true)
            main.window?.layoutIfNeeded()
            let ruler = try #require(console.resultsRuler)
            let window = try #require(main.window)
            let image = try #require(await call(harness, "screenshot", ["target": "main", "scale": 2]).image)
            // In the find bar's top margin, at the ruler's right edge (its line) and a little to the right of it.
            let bar = console.findBar.convert(console.findBar.bounds, to: nil)
            let edge = ruler.convert(NSPoint(x: ruler.bounds.maxX - 0.5, y: 0), to: nil).x
            let y = Int((window.frame.height - bar.maxY + 3) * 2)
            func pixel(_ x: CGFloat) -> NSColor? { image.colorAt(x: Int(x * 2), y: y)?.usingColorSpace(.sRGB) }
            let line = try #require(pixel(edge)), beside = try #require(pixel(edge + 12))
            #expect(line.luminance == beside.luminance, "the ruler's line shows over the find bar: \(line) beside \(beside)")
            console.findBar.close(nil)
        }

        @Test func everyConsoleControlSaysWhatItDoes() async throws {
            let (main, harness, console) = try await Self.window()
            var missing: [String] = []
            try await Self.states(main, harness, console) { place, windows in missing += unexplained(windows, where: place) }
            let log = SQLLogWindowController.show(SQLLog(fileURL: URL(fileURLWithPath: try! scratch() + "/SQL.log")))
            keptWindows.append(log)
            log.window?.setFrameOrigin(NSPoint(x: -22000, y: -22000))
            missing += unexplained([log.window!], where: "SQL log")
            log.close()
            #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
        }

        @Test func consoleScreensAreTidyInLightAndDarkAtEverySize() async throws {
            var problems: [String] = []
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for size in [MainWindowController.minimumSize, MainWindowController.defaultSize] {
                    let (main, harness, console) = try await Self.window(size: size)
                    main.window?.appearance = NSAppearance(named: appearance)
                    let place = "\(appearance == .aqua ? "light" : "dark") \(Int(size.width))×\(Int(size.height))"
                    try await Self.states(main, harness, console) { what, windows in
                        for window in windows {
                            window.appearance = NSAppearance(named: appearance)
                            window.contentView?.layoutSubtreeIfNeeded()
                            if let content = window.contentView { problems += layoutProblems(content, where: "\(place) \(what)") }
                        }
                    }
                }
            }
            // A scroll view's two overlay scrollers share its corner, as AppKit draws them (they show only while scrolling).
            problems.removeAll { $0.hasSuffix("NSScroller and NSScroller overlap") }
            #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        }

        /// The editor (plan §2.12): a right-click opens its menu (Run Statement, Run Selection, Explain, Format SQL,
        /// Comment Lines, Cut, Copy, Paste), each item in the menu bar too, off with a reason when it can't act. A click
        /// placing the cursor and a double-click selecting the word are AppKit's own: a made-up click into its tracking
        /// ends the test process on macOS 26.
        @Test func editorAnswersEveryClick() async throws {
            let (main, harness, console) = try await Self.window()
            let editor = console.editor!
            let window = try #require(main.window)
            let glyph = try #require(editor.layoutManager).boundingRect(forGlyphRange: NSRange(location: 52, length: 1),
                                                                        in: try #require(editor.textContainer))
            let point = editor.convert(NSPoint(x: glyph.midX + editor.textContainerOrigin.x, y: glyph.midY + editor.textContainerOrigin.y),
                                       to: nil)
            let y = window.frame.height - point.y
            let right = await call(harness, "click", ["x": point.x, "y": y, "button": "right"])
            let items = right["menu"] as? [[String: Any]] ?? []
            #expect(titles(items) == ["Run Statement", "Run Selection", "Explain", "Format SQL", "Comment Lines", "Cut", "Copy", "Paste"])
            func walk(_ menu: NSMenu) -> [String] { menu.items.flatMap { item in [item.title] + (item.submenu.map(walk) ?? []) } }
            let bar = Set(NSApp.mainMenu.map(walk) ?? [])
            for item in items {
                let title = item["title"] as? String ?? ""
                if !(item["enabled"] as? Bool ?? false) {
                    #expect(!(item["reason"] as? String ?? "").isEmpty, "“\(title)” is off without a reason")
                }
                #expect(bar.contains(title), "“\(title)” isn't in the menu bar")
            }
            #expect(items.first { $0["title"] as? String == "Format SQL" }?["enabled"] as? Bool == true)
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1"))
        func screenshots() async throws {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let (main, harness, console) = try await Self.window()
                main.window?.appearance = NSAppearance(named: appearance)
                main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
                main.window?.orderFront(nil)
                var index = 0
                try await Self.states(main, harness, console) { what, windows in
                    index += 1
                    let target = windows.first === main.window ? "main" : "sheet"
                    let reply = await call(harness, "screenshot", ["target": target, "scale": 2])
                    guard let image = reply.image, let png = image.representation(using: .png, properties: [:]) else { return }
                    let name = "console-\(index)-" + what.replacingOccurrences(of: " ", with: "-") + "-\(suffix).png"
                    try? png.write(to: AppTests.ScreenshotTests.folder.appendingPathComponent(name))
                }
                main.window?.orderOut(nil)
            }
        }
    }
}
