import AppKit
import Testing
@testable import AirSQL
import AirSQLCore

// The theme's text meets WCAG AA (plan §2.13: 4.5:1 for text) in Porcelain and Deep Water: primary buttons, chips and
// selected segments, measured on the colours (and the pixels) they are drawn with.

/// `top` over `bottom`, as the current drawing appearance resolves them: an opaque colour.
private func composite(_ top: NSColor, over bottom: NSColor) -> NSColor {
    let upper = top.usingColorSpace(.sRGB)!, lower = bottom.usingColorSpace(.sRGB)!
    let alpha = upper.alphaComponent
    func mix(_ first: CGFloat, _ second: CGFloat) -> CGFloat { first * alpha + second * (1 - alpha) }
    return NSColor(srgbRed: mix(upper.redComponent, lower.redComponent), green: mix(upper.greenComponent, lower.greenComponent),
                   blue: mix(upper.blueComponent, lower.blueComponent), alpha: 1)
}

private let themes: [(NSAppearance, String)] = [(NSAppearance(named: .aqua)!, "Porcelain"), (NSAppearance(named: .darkAqua)!, "Deep Water")]

extension AppTests {
    @MainActor @Suite struct ThemeTests {
        /// The contrast of the darkest and lightest pixels in `rect` (points in `control`) as `control` is drawn in an
        /// active window in `appearance`: a title on its fill.
        func drawnContrast(_ control: NSView, size: NSSize, in rect: (NSView) -> NSRect, appearance: NSAppearance) throws -> CGFloat {
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width + 40, height: size.height + 28),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            control.translatesAutoresizingMaskIntoConstraints = true
            control.frame = NSRect(x: 20, y: 14, width: size.width, height: size.height)
            window.contentView?.addSubview(control)
            window.orderFront(nil)
            window.displayIfNeeded()
            defer { window.orderOut(nil) }
            let frame = window.frame.size
            let canvas = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width * 2), pixelsHigh: Int(frame.height * 2),
                                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            canvas.size = frame
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
            AgentServer.drawingAsKey([window]) { AgentServer.draw(window, at: .zero) }
            NSGraphicsContext.restoreGraphicsState()
            let area = control.convert(rect(control), to: nil)
            return try pixelContrast(canvas, NSRect(x: area.minX, y: frame.height - area.maxY, width: area.width, height: area.height))
        }

        /// The contrast of the darkest and lightest pixels of a picture at scale 2 in `rect` (points from its top left).
        func pixelContrast(_ image: NSBitmapImageRep, _ rect: NSRect) throws -> CGFloat {
            var colors: [NSColor] = []
            for y in stride(from: rect.minY, to: rect.maxY, by: 0.5) {
                for x in stride(from: rect.minX, to: rect.maxX, by: 0.5) {
                    if let color = image.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB) { colors.append(color) }
                }
            }
            let darkest = try #require(colors.min { $0.luminance < $1.luminance })
            let lightest = try #require(colors.max { $0.luminance < $1.luminance })
            return darkest.contrast(with: lightest)
        }

        @Test func theAgentsPopoversQuietTextReads() async throws {
            for (appearance, theme) in themes {
                let model = testModel(Fixtures.shop)
                let (main, harness) = appWindow(model)
                let window = try #require(main.window)
                window.appearance = appearance
                window.setFrameOrigin(NSPoint(x: 40, y: 40))  // a popover goes on a screen: so does its window
                window.orderFront(nil)
                defer { window.orderOut(nil) }
                model.data.settings.agentsAllowed = true
                let agents = AgentService(model: model, main: main, directory: URL(fileURLWithPath: try scratch() + "/agent"))
                defer {
                    agents.close()
                    model.data.settings.agentsAllowed = false
                }
                agents.finish(agents.record("claude-code 2.1", "context"), "2 connections")
                main.refresh()
                main.statusBar.agent.showPopover()
                _ = await call(harness, "wait", ["until": "popover", "timeout": 5])
                defer { main.statusBar.agent.shown?.close() }
                let content = try #require(main.statusBar.agent.shown?.contentViewController?.view)
                let image = try #require(await call(harness, "screenshot", ["target": "main", "scale": 2]).image)
                // The note under the list, where the main window's picture has it.
                func fields(_ view: NSView) -> [NSTextField] { [view as? NSTextField].compactMap { $0 } + view.subviews.flatMap(fields) }
                let note = try #require(fields(content).first { $0.stringValue.hasPrefix("Agents never see") })
                let popover = try #require(note.window)
                let inPopover = note.convert(note.bounds, to: nil)
                let x = popover.frame.minX - window.frame.minX + inPopover.minX
                let top = window.frame.maxY - (popover.frame.minY + inPopover.maxY)
                let contrast = try pixelContrast(image, NSRect(x: x, y: top, width: inPopover.width, height: inPopover.height))
                #expect(contrast >= 4.5, "\(theme): the note is \(contrast):1")
            }
        }

        @Test func primaryButtonTitleReadsOnTheAccent() throws {
            for (appearance, theme) in themes {
                appearance.performAsCurrentDrawingAppearance {
                    #expect(NSColor.onAccent.contrast(with: .accent) >= 4.5, "\(theme)")
                }
                let primary = button("Save and Connect", id: "test.primary", tip: "", target: nil, action: nil, primary: true)
                let contrast = try drawnContrast(primary, size: NSSize(width: 200, height: 32), in: { $0.bounds.insetBy(dx: 40, dy: 9) },
                                                 appearance: appearance)
                #expect(contrast >= 4.5, "\(theme): the title is \(contrast):1 on its fill")
            }
        }

        @Test func deepWaterLiesBelowItsContent() {
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                #expect(NSColor.ground.luminance < NSColor.side.luminance)
                #expect(NSColor.side.luminance < NSColor.content.luminance)
                #expect(NSColor.ground.luminance < NSColor.bar.luminance)
            }
        }

        @Test func chipTextReadsOnItsTint() {
            let styles: [(ChipView.Style, String)] = [(.tinted(.statusWarning), "warning"), (.tinted(.statusBad), "bad"),
                                                      (.tinted(.statusOK), "ok"), (.accent, "accent"), (.neutral, "neutral")]
            for (appearance, theme) in themes {
                for (style, name) in styles {
                    let chip = ChipView("Transaction open", style: style)
                    appearance.performAsCurrentDrawingAppearance {
                        // The status bar, lists and popovers.
                        for (ground, where_) in [(NSColor.bar, "bar"), (.content, "content"), (.windowBackgroundColor, "window")] {
                            let fill = composite(chip.fill(in: appearance), over: ground)
                            let text = composite(chip.label.textColor!, over: fill)
                            #expect(text.contrast(with: fill) >= 4.5, "\(theme) \(name) chip on the \(where_): \(text.contrast(with: fill)):1")
                        }
                    }
                }
            }
        }

        @Test func selectedSegmentCarriesAppKitsWhiteLabel() throws {
            for (appearance, theme) in themes {
                let segments = NSSegmentedControl(labels: ["Columns", "Indexes"], trackingMode: .selectOne, target: nil, action: nil)
                segments.selectedSegment = 0
                segments.selectedSegmentBezelColor = .selectedSegment
                // Inside the selected segment: its fill and its white label.
                let contrast = try drawnContrast(segments, size: NSSize(width: 200, height: 28), in: { view in
                    NSRect(x: 6, y: 6, width: (view.bounds.width / 2) - 12, height: view.bounds.height - 12)
                }, appearance: appearance)
                #expect(contrast >= 4.5, "\(theme): the label is \(contrast):1 on its fill")
            }
        }

        /// A grid's quieter text on its bars: the header's type line and the row numbers; and the table tab's WHERE label
        /// and its problem notice (a server's error on its red fill).
        @Test func theGridsQuietTextReads() throws {
            for (appearance, theme) in themes {
                let viewer = GridViewer(source: nil)
                viewer.show(FakeGridSource(rows: 30, columns: 4))
                let grid = viewer.grid, size = NSSize(width: 640, height: 320)
                // The second column's type line, under its name (left of the sort control); the second row's number.
                let typeLine = try drawnContrast(viewer, size: size, in: { view in
                    let header = grid.header!, (left, right) = header.edges(1)
                    let nameFont = NSFont.systemFont(ofSize: grid.fontSize, weight: .semibold)
                    let nameHeight = ceil(nameFont.ascender - nameFont.descender)
                    let rect = NSRect(x: left + 8, y: 4 + nameHeight, width: right - left - 8 - GridHeaderView.sortWidth - 4,
                                      height: header.bounds.height - 6 - nameHeight)
                    return header.convert(rect, to: view)
                }, appearance: appearance)
                #expect(typeLine >= 4.5, "\(theme): the type line is \(typeLine):1")
                let rowNumber = try drawnContrast(viewer, size: size, in: { view in
                    grid.rowNumbers.convert(NSRect(x: 0, y: grid.rowHeight, width: grid.rowNumbers.bounds.width, height: grid.rowHeight), to: view)
                }, appearance: appearance)
                #expect(rowNumber >= 4.5, "\(theme): a row number is \(rowNumber):1")

                let bar = TableDataBar()
                let whereLabel = try #require(descendants(of: bar).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Filter" })
                let label = try drawnContrast(bar, size: NSSize(width: 760, height: 36), in: { whereLabel.convert(whereLabel.bounds, to: $0) },
                                              appearance: appearance)
                #expect(label >= 4.5, "\(theme): the WHERE label is \(label):1")
                let notice = TableDataNotice()
                notice.show(.problem, "Table 'airsql_fixture.orders' doesn't exist")
                let problem = try drawnContrast(notice, size: NSSize(width: 520, height: 28), in: { notice.text.convert(notice.text.bounds, to: $0) },
                                                appearance: appearance)
                #expect(problem >= 4.5, "\(theme): the problem notice is \(problem):1")
            }
        }

        /// Column List's types and Column Summary's note, drawn in a window: in their popovers, which resize to fit as they
        /// open, a picture could catch the note moving (it measured the bar above it on CI).
        @Test func theColumnListAndSummaryQuietTextReads() throws {
            for (appearance, theme) in themes {
                let viewer = GridViewer(source: nil)
                viewer.show(FakeGridSource(rows: 30, columns: 4))
                // The label whose text starts with `text`, in points of `view` (none: an empty patch, which fails).
                func label(_ text: String, in view: NSView) -> NSRect {
                    let field = descendants(of: view).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix(text) }
                    return field.map { $0.convert($0.bounds, to: view) } ?? .zero
                }
                let list = GridColumnList(viewer: viewer)
                let type = try drawnContrast(list.view, size: NSSize(width: 320, height: 240), in: { label("varchar(60)", in: $0) },
                                             appearance: appearance)
                #expect(type >= 4.5, "\(theme): Column List's type is \(type):1")
                let summary = GridSummaryView(column: "name_1", origin: "From the 30 rows loaded", nullText: "NULL")
                summary.show(.success(ColumnSummary(values: (0..<30).map { "Customer \($0)" })))
                let note = try drawnContrast(summary.view, size: summary.view.fittingSize, in: { label("From the 30 rows loaded", in: $0) },
                                             appearance: appearance)
                #expect(note >= 4.5, "\(theme): Column Summary's note is \(note):1")
            }
        }

        /// The navigator's selected rows, a connection and a database: their name and count on the accent, in the
        /// accent's own text colour (the mockups' `.tr.sel`), not AppKit's white.
        @Test func theNavigatorsSelectionReadsOnTheAccent() throws {
            for (appearance, theme) in themes {
                let database = TreeCell()
                database.show(TreeIcon.database, "airsql_fixture", count: "13", busy: false, tip: "")
                let connection = SidebarCell()
                connection.show(Fixtures.production, state: .connected(server: "MariaDB 11.8"))
                for cell in [database, connection] as [NSTableCellView] {
                    let row = SidebarRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
                    cell.frame = row.bounds
                    row.addSubview(cell)
                    row.isEmphasized = true
                    row.isSelected = true
                    func fields(_ view: NSView) -> [NSTextField] { [view as? NSTextField].compactMap { $0 } + view.subviews.flatMap(fields) }
                    cell.layoutSubtreeIfNeeded()
                    for field in fields(cell) where !field.isHiddenOrHasHiddenAncestor && !field.stringValue.isEmpty {
                        let contrast = try drawnContrast(row, size: row.frame.size, in: { field.convert(field.bounds, to: $0) },
                                                         appearance: appearance)
                        #expect(contrast >= 4.5, "\(theme): “\(field.stringValue)” is \(contrast):1 on the selection")
                    }
                }
            }
        }
    }
}
