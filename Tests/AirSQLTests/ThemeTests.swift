import AppKit
import Testing
@testable import AirSQL

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
        @Test func primaryButtonTitleReadsOnTheAccent() throws {
            for (appearance, theme) in themes {
                appearance.performAsCurrentDrawingAppearance {
                    #expect(NSColor.onAccent.contrast(with: .accent) >= 4.5, "\(theme)")
                }
                // As drawn: the title's darkest and lightest pixels against each other, in an active window.
                let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 240, height: 60), styleMask: [.titled],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                let primary = button("Save and Connect", id: "test.primary", tip: "", target: nil, action: nil, primary: true)
                primary.translatesAutoresizingMaskIntoConstraints = true
                primary.frame = NSRect(x: 20, y: 14, width: 200, height: 32)
                window.contentView?.addSubview(primary)
                window.orderFront(nil)
                window.displayIfNeeded()
                let size = window.frame.size
                let canvas = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                canvas.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
                AgentServer.drawingAsKey([window]) { AgentServer.draw(window, at: .zero) }
                NSGraphicsContext.restoreGraphicsState()
                window.orderOut(nil)
                let title = primary.convert(primary.bounds, to: nil).insetBy(dx: 40, dy: 9)
                var colors: [NSColor] = []
                for y in stride(from: title.minY, to: title.maxY, by: 0.5) {
                    for x in stride(from: title.minX, to: title.maxX, by: 0.5) {
                        if let color = canvas.colorAt(x: Int(x * 2), y: canvas.pixelsHigh - 1 - Int(y * 2))?.usingColorSpace(.sRGB) {
                            colors.append(color)
                        }
                    }
                }
                let darkest = try #require(colors.min { $0.luminance < $1.luminance })
                let lightest = try #require(colors.max { $0.luminance < $1.luminance })
                #expect(darkest.contrast(with: lightest) >= 4.5, "\(theme): the title is \(darkest.contrast(with: lightest)):1 on its fill")
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

        @Test func selectedSegmentCarriesAppKitsWhiteLabel() {
            for (appearance, theme) in themes {
                appearance.performAsCurrentDrawingAppearance {
                    let fill = composite(.selectedSegment, over: .windowBackgroundColor)
                    #expect(NSColor.white.contrast(with: fill) >= 4.5, "\(theme): \(NSColor.white.contrast(with: fill)):1")
                }
            }
        }
    }
}
