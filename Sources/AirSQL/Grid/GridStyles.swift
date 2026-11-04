import AirSQLCore
import AppKit

/// The grid's fonts, metrics and colours (docs/dev/mockups.html): 12 pt text in 23 pt rows with 9 pt either side,
/// tabular digits, numbers right-aligned, bytes and JSON in monospace, NULL in pale italics, key values semibold, every
/// other row faintly shaded.
struct GridStyles {
    static let padding: CGFloat = 9
    /// The longest text a cell lays out: more never fits on screen.
    static let displayLimit = 500

    let regular: NSFont
    let key: NSFont
    let mono: NSFont
    let null: NSFont
    let rowHeight: CGFloat
    /// From a row's top to the text's baseline.
    let baseline: CGFloat

    init(fontSize: CGFloat) {
        regular = .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        key = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        mono = .monospacedSystemFont(ofSize: max(8, fontSize - 1), weight: .regular)
        null = NSFont(descriptor: regular.fontDescriptor.withSymbolicTraits(.italic), size: fontSize) ?? regular
        rowHeight = ceil(fontSize + 11)
        let textHeight = regular.ascender - regular.descender
        baseline = ((rowHeight - textHeight) / 2 + regular.ascender).rounded()
    }

    func font(_ column: GridColumn, isNull: Bool) -> NSFont {
        if isNull { return null }
        if column.isKey { return key }
        return column.kind == .binary || column.kind == .json ? mono : regular
    }

    static func color(_ column: GridColumn, isNull: Bool) -> NSColor {
        if isNull { return .dataNull }
        switch column.kind {
        case .text: return .labelColor
        case .number: return .dataNumber
        case .date: return .dataDate
        case .binary: return .dataBinary
        case .json: return .dataJSON
        }
    }

    /// Text attributes for Core Text, with the colour as the current appearance resolves it.
    func attributes(_ column: GridColumn, isNull: Bool, deleted: Bool = false) -> [NSAttributedString.Key: Any] {
        let color = deleted ? NSColor.secondaryLabelColor : Self.color(column, isNull: isNull)
        return [.font: font(column, isNull: isNull), NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]
    }

    /// What a cell shows: NULL's text, nothing for an empty string or a cell still loading, else its value on one line.
    static func text(_ cell: GridCell, nullText: String) -> String {
        switch cell {
        case .text(let text): return display(text)
        case .null: return nullText
        case .loading: return ""
        case .placeholder(let text): return text
        }
    }

    /// A value on one line: line breaks and tabs as visible marks, at most `displayLimit` characters.
    static func display(_ text: String) -> String {
        var text = text
        if text.utf16.count > displayLimit { text = String(text.prefix(displayLimit)) }
        guard text.utf8.last == 32 || text.utf8.contains(where: { $0 == 10 || $0 == 13 || $0 == 9 || $0 >= 0xC2 }) else { return text }
        var shown = text.replacingOccurrences(of: "\r\n", with: "↵").replacingOccurrences(of: "\n", with: "↵")
            .replacingOccurrences(of: "\r", with: "↵").replacingOccurrences(of: "\t", with: "⇥")
        // Spaces at the end and characters that draw nothing: 'abc ' and 'abc' mustn't look the same. (Not U+200D, which
        // joins emoji.)
        let invisible: [Unicode.Scalar: Character] = ["\u{00A0}": "⍽", "\u{200B}": "␣", "\u{2060}": "␣", "\u{FEFF}": "␣"]
        if shown.unicodeScalars.contains(where: { invisible[$0] != nil }) {
            shown = String(shown.unicodeScalars.reduce(into: String.UnicodeScalarView()) { out, scalar in
                out.append(invisible[scalar]?.unicodeScalars.first ?? scalar)
            })
        }
        let spaces = shown.reversed().prefix { $0 == " " }.count
        return shown.dropLast(spaces) + String(repeating: "␣", count: spaces)
    }

    /// The width a cell's text takes (without the padding).
    func width(of cell: GridCell, in column: GridColumn, nullText: String) -> CGFloat {
        let text = Self.text(cell, nullText: nullText)
        guard !text.isEmpty else { return 0 }
        let font = font(column, isNull: cell == .null || cell.isPlaceholder)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

extension NSColor {
    /// This colour as the current appearance draws it, made opaque over the content colour: a translucent fill blends
    /// every pixel (a third of a screen's drawing time went on blending the shaded rows), an opaque one doesn't.
    var solid: NSColor {
        guard let color = usingColorSpace(.sRGB) else { return self }
        guard color.alphaComponent < 1, let content = NSColor.content.usingColorSpace(.sRGB) else { return color }
        return content.blended(withFraction: color.alphaComponent, of: color.withAlphaComponent(1)) ?? color
    }

    /// Every other row of the grid: the hover tint at 55 % (the mockups' zebra).
    static let gridZebra = NSColor(name: nil) { appearance in
        var color = NSColor.content
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.content.blended(withFraction: appearance.isDark ? 0.033 : 0.025, of: .labelColor) ?? color
        }
        return color
    }
    /// A find match: dark enough in Deep Water for the light text on it (AA asks 4.5:1).
    static let gridFound = pair(0xFFF27F, 0x5E5A1E)
    /// Selected cells: the accent at 20 % over the content.
    static let gridSelection = NSColor(name: nil) { appearance in
        var color = NSColor.content
        appearance.performAsCurrentDrawingAppearance { color = NSColor.content.blended(withFraction: 0.2, of: .accent) ?? color }
        return color
    }
    /// The focused cell: the accent at 12 %, inside its ring.
    static let gridFocus = NSColor(name: nil) { appearance in
        var color = NSColor.content
        appearance.performAsCurrentDrawingAppearance { color = NSColor.content.blended(withFraction: 0.12, of: .accent) ?? color }
        return color
    }
}
