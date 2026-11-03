// Ported from AirSCP 1.4.0 scripts/make-icon.swift (its grid, its window and the iconset), with AirSQL's own drawing.
// Draws AirSQL's app icon (a database and a table in a dark window on a blue rounded square) and writes
// Resources/AppIcon.icns, docs/assets/icon.png (the README's) and docs/favicon.ico (AirSQL Help's).
// Usage, from the repository's root: swift scripts/make-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// The front half of an ellipse centred on (x, y): a disk's rim seen from a little above.
func rim(x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: .zero, radius: 1, startAngle: .pi, endAngle: 2 * .pi, clockwise: false,
                transform: CGAffineTransform(translationX: x, y: y).scaledBy(x: rx, y: ry))
    return path
}

/// Draws the icon on a 1024×1024 canvas (y up).
func draw(_ cg: CGContext) {
    // Background: Apple's macOS icon grid, an 824-point rounded square with a soft drop shadow, as AirSCP's. macOS 26
    // shows it in its own rounder shape, which this square covers, so it isn't put on a grey tile.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.35))
    cg.addPath(body)
    cg.setFillColor(color(23, 58, 122))
    cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(body)
    cg.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(61, 143, 224), color(23, 58, 122)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    cg.restoreGState()

    // A dark window with a title bar, as AirSCP's.
    let window = color(18, 28, 36)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0, 14, 40, 0.45))
    cg.addPath(CGPath(roundedRect: CGRect(x: 196, y: 250, width: 632, height: 520), cornerWidth: 56, cornerHeight: 56, transform: nil))
    cg.setFillColor(window)
    cg.fillPath()
    cg.restoreGState()
    for (index, dot) in [color(255, 95, 87), color(254, 188, 46), color(40, 200, 64)].enumerated() {
        cg.setFillColor(dot)
        cg.fillEllipse(in: CGRect(x: 246 + CGFloat(index) * 54, y: 696, width: 34, height: 34))
    }

    // A database: a cylinder of three stacked disks, their rims cut in the window's colour.
    let x: CGFloat = 340, top: CGFloat = 588, bottom: CGFloat = 364, rx: CGFloat = 100, ry: CGFloat = 32
    let cylinder = CGMutablePath()
    cylinder.addEllipse(in: CGRect(x: x - rx, y: top - ry, width: 2 * rx, height: 2 * ry))
    cylinder.addRect(CGRect(x: x - rx, y: bottom, width: 2 * rx, height: top - bottom))
    cylinder.addEllipse(in: CGRect(x: x - rx, y: bottom - ry, width: 2 * rx, height: 2 * ry))
    cg.addPath(cylinder)
    cg.setFillColor(color(226, 240, 251))
    cg.fillPath()
    cg.setStrokeColor(window)
    cg.setLineWidth(18)
    for disk in 0..<3 {
        cg.addPath(rim(x: x, y: top - CGFloat(disk) * (top - bottom) / 3, rx: rx, ry: ry))
        cg.strokePath()
    }

    // A table: two columns, their headers in AirSQL's petrol and one cell being edited (the grid's pending amber).
    let row: CGFloat = 54, gap: CGFloat = 24, left: CGFloat = 488, width: CGFloat = 292, split = (width - gap) * 0.42
    for line in 0..<4 {
        let y = 620 - CGFloat(line) * (row + gap) - row
        for (column, cell) in [CGRect(x: left, y: y, width: split, height: row),
                               CGRect(x: left + split + gap, y: y, width: width - split - gap, height: row)].enumerated() {
            cg.addPath(CGPath(roundedRect: cell, cornerWidth: 14, cornerHeight: 14, transform: nil))
            cg.setFillColor(line == 0 ? color(79, 194, 210) : line == 2 && column == 1 ? color(255, 196, 92) : color(226, 240, 251, 0.34))
            cg.fillPath()
        }
    }
}

func image(_ pixels: Int) -> CGImage {
    let cg = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(cg)
    return cg.makeImage()!
}

func write(_ images: [CGImage], as type: UTType, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil)!
    images.forEach { CGImageDestinationAddImage(destination, $0, nil) }
    guard CGImageDestinationFinalize(destination) else { fatalError("can't write \(url.path)") }
}

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        write([image(points * scale)], as: .png, to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try fileManager.createDirectory(atPath: "docs/assets", withIntermediateDirectories: true)
write([image(512)], as: .png, to: URL(fileURLWithPath: "docs/assets/icon.png"))
write([16, 32, 48].map(image), as: .ico, to: URL(fileURLWithPath: "docs/favicon.ico"))
print("Wrote Resources/AppIcon.icns, docs/assets/icon.png and docs/favicon.ico")
