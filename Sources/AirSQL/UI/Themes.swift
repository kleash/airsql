// Ported from AirSCP 1.4.0 Sources/AirSCP/Themes.swift (its AppKit half: the surfaces from system colours, the wash,
// SurfaceView), with AirSQL's palette from docs/dev/mockups.html.
import AirSQLCore
import AppKit

// Porcelain (light) and Deep Water (dark): AppKit's own colours as the appearance resolves them (light or dark,
// Increase Contrast, the accent colour), plus a petrol accent when the person hasn't chosen one, Deep Water's petrol
// wash, and fixed pairs chosen for data (value types, pending edits, SQL) and connections. No theme object, no setting.

extension NSAppearance {
    /// Deep Water; else Porcelain.
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    /// A colour for Porcelain and one for Deep Water (sRGB hex, as the mockups give them).
    static func pair(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { $0.isDark ? hex(dark) : hex(light) }
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    // MARK: Surfaces

    /// The window's ground: the toolbar, the tab strip, around sheets. macOS 26 draws windows in the content colour;
    /// 7.5 % of labelColor gives Porcelain's ground back its grey. Deep Water's lies below the content, as in the mockups.
    static let ground = NSColor(name: nil) { $0.isDark ? shaded(0.24, $0) : surface(.windowBackgroundColor, $0, lifted: true) }
    /// The editor, the grid, lists.
    static let content = NSColor(name: nil) { surface(.controlBackgroundColor, $0, lifted: false) }
    /// The navigator: Porcelain's ground, 3.5 % towards labelColor, or Deep Water's between its ground and the content.
    static let side = NSColor(name: nil) { appearance in
        if appearance.isDark { return shaded(0.11, appearance) }
        var color = NSColor.ground
        appearance.performAsCurrentDrawingAppearance { color = NSColor.ground.blended(withFraction: 0.035, of: .labelColor) ?? color }
        return color
    }
    /// A bar (the grid bar, the status bar, result tabs): the ground at 40 % over the content.
    static let bar = NSColor(name: nil) { appearance in
        var color = NSColor.content
        appearance.performAsCurrentDrawingAppearance { color = NSColor.content.blended(withFraction: 0.4, of: .ground) ?? color }
        return color
    }
    /// A lighter separator, between rows and cells.
    static let softSeparator = NSColor(name: nil) { appearance in
        var color = NSColor.separatorColor
        appearance.performAsCurrentDrawingAppearance {
            // Half of the separator's own alpha: withAlphaComponent sets it, and 0.5 is well above what the separator has.
            let separator = NSColor.separatorColor.usingColorSpace(.sRGB) ?? .separatorColor
            color = separator.withAlphaComponent(separator.alphaComponent * 0.5)
        }
        return color
    }
    /// A row under the pointer.
    static let hover = NSColor(name: nil) { appearance in
        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.withAlphaComponent(appearance.isDark ? 0.06 : 0.045) }
        return color
    }

    // MARK: Accent and pill

    /// The person's accent colour when they chose one in System Settings, else AirSQL's petrol.
    static let accent = NSColor(name: nil) { appearance in
        if UserDefaults.standard.object(forKey: "AppleAccentColor") != nil { return .controlAccentColor }
        return appearance.isDark ? hex(0x3FB6C8) : hex(0x0A7F91)
    }
    /// Text and symbols on the accent: white, or Deep Water's ink (#06181C) where it reads better (on Deep Water's light
    /// petrol, as the mockups give it, and on a light accent the person chose).
    static let onAccent = NSColor(name: nil) { appearance in
        var color = NSColor.white
        appearance.performAsCurrentDrawingAppearance {
            let ink = hex(0x06181C)
            if ink.contrast(with: .accent) > NSColor.white.contrast(with: .accent) { color = ink }
        }
        return color
    }
    /// The accent faintly behind content: a chip's or a banner's fill.
    static let accentFill = NSColor(name: nil) { appearance in
        var color = NSColor.accent
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.content.blended(withFraction: appearance.isDark ? 0.22 : 0.17, of: .accent) ?? color
        }
        return color
    }
    /// A selected row.
    static let selectedRow = NSColor(name: nil) { appearance in
        var color = NSColor.accent
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.content.blended(withFraction: appearance.isDark ? 0.14 : 0.1, of: .accent) ?? color
        }
        return color
    }
    /// The selected, active or primary fill: labelColor in Porcelain (its near-black pill), the accent in Deep Water.
    static let pill = NSColor(name: nil) { $0.isDark ? .accent : .labelColor }
    /// A selected segment: the pill, a deeper petrol in Deep Water (AppKit draws the selected label white, 2.4:1 on the
    /// accent itself).
    static let selectedSegment = NSColor(name: nil) { appearance in
        var color = NSColor.labelColor
        if appearance.isDark {
            appearance.performAsCurrentDrawingAppearance { color = NSColor.accent.blended(withFraction: 0.45, of: .black) ?? color }
        }
        return color
    }
    /// Text and symbols on a pill.
    static let onPill = NSColor(name: nil) { $0.isDark ? hex(0x06181C) : .controlBackgroundColor }

    /// Quieter text that still reads (the agents' popover, a grid's types and row numbers): secondaryLabelColor 40 % of
    /// the way to the text colour, 4.5:1 or more on bars and popovers in both themes (the plain colour is 3.9:1 there).
    static let quietText = NSColor(name: nil) { appearance in
        var color = NSColor.secondaryLabelColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.secondaryLabelColor.blended(withFraction: 0.4, of: .textColor) ?? color
        }
        return color
    }

    // MARK: Data, pending changes, SQL

    static let dataNumber = pair(0x1F5FBF, 0x7FB0F5)
    static let dataDate = pair(0x8A4BAF, 0xC9A2E6)
    static let dataBinary = pair(0x8B6A1A, 0xDCBC66)
    static let dataJSON = pair(0x0F7A6B, 0x63CDB8)
    static let dataNull = pair(0x9AA1AA, 0x6B7480)

    static let pendingEdit = pair(0xFFF1C9, 0x43380F)
    static let pendingEditLine = pair(0xD9A514, 0xE0B52E)
    static let pendingInsert = pair(0xDDF5E3, 0x173A24)
    static let pendingInsertLine = pair(0x2E9E5B, 0x4CC27B)
    static let pendingDelete = pair(0xFBE0E0, 0x482023)
    static let pendingDeleteLine = pair(0xD14343, 0xEF6B6B)

    static let sqlKeyword = pair(0x9B2F8A, 0xE48DD4)
    static let sqlString = pair(0xB5482A, 0xF2A582)
    static let sqlNumber = pair(0x1F5FBF, 0x7FB0F5)
    static let sqlComment = pair(0x6E7781, 0x7D8794)
    static let sqlFunction = pair(0x0A7F91, 0x56C7D6)
    static let sqlIdentifier = pair(0x4A5562, 0xB7C0CB)

    // MARK: Status

    static let statusOK = pair(0x2E8A52, 0x57C785)
    static let statusWarning = pair(0xB26B00, 0xE6A43B)
    static let statusBad = pair(0xC73636, 0xF07171)

    /// WCAG's relative luminance, as the current appearance resolves the colour (0 black, 1 white).
    var luminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    /// WCAG's contrast ratio with `other` (1 to 21; AA asks 4.5 for text), both taken as opaque.
    func contrast(with other: NSColor) -> CGFloat {
        let (first, second) = (luminance, other.luminance)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// This colour as text on its own tint (a chip, a notice): a third of the way to black (Porcelain) or white (Deep
    /// Water), as the colour itself is 3.3 to 4.2:1 there, under WCAG AA's 4.5:1.
    var asTextOnItsTint: NSColor {
        NSColor(name: nil) { appearance in
            var color = self
            appearance.performAsCurrentDrawingAppearance { color = self.blended(withFraction: 0.35, of: .textColor) ?? self }
            return color
        }
    }

    private static func washes(_ appearance: NSAppearance) -> Bool {
        appearance.isDark && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// The content, `fraction` of the way to black.
    private static func shaded(_ fraction: CGFloat, _ appearance: NSAppearance) -> NSColor {
        var color = NSColor.content
        appearance.performAsCurrentDrawingAppearance { color = NSColor.content.blended(withFraction: fraction, of: .black) ?? color }
        return color
    }

    /// Deep Water's wash: 6 % petrol over its surfaces; none in Porcelain, nor with Increase Contrast.
    private static func surface(_ base: NSColor, _ appearance: NSAppearance, lifted: Bool) -> NSColor {
        var color = base
        appearance.performAsCurrentDrawingAppearance {
            if lifted, #available(macOS 26, *) { color = color.blended(withFraction: 0.075, of: .labelColor) ?? color }
            if washes(appearance) { color = color.blended(withFraction: 0.06, of: hex(0x3FB6C8)) ?? color }
        }
        return color
    }
}

extension ConnectionColour {
    /// The same in both themes, as the mockups show them; nil for None.
    var color: NSColor? {
        switch self {
        case .none: return nil
        case .production: return .hex(0xD93A3A)
        case .staging: return .hex(0xD9911E)
        case .development: return .hex(0x2E9E5B)
        case .test: return .hex(0x3A7BD9)
        }
    }
}

/// The one radius scale (plan §2.13): content inside a rounded shape is inset by at least its radius.
enum Radius {
    /// Cells, chips.
    static let cell: CGFloat = 4
    /// Controls, fields.
    static let control: CGFloat = 6
    /// Popovers, cards.
    static let card: CGFloat = 8
    /// Sheets.
    static let sheet: CGFloat = 10
    /// Windows.
    static let window: CGFloat = 12
}

/// The 8-point spacing grid: `Spacing.unit` and its half and multiples.
enum Spacing {
    static let half: CGFloat = 4
    static let unit: CGFloat = 8
    static let double: CGFloat = 16
    static let triple: CGFloat = 24
}

/// A plain surface in one of the colours above, with an optional rounded edge and hairline. The colour follows the
/// appearance as the view redraws.
final class SurfaceView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    var radius: CGFloat { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { needsDisplay = true } }

    init(_ color: NSColor, radius: CGFloat = 0, border: NSColor? = nil) {
        self.color = color
        self.radius = radius
        self.border = border
        super.init(frame: .zero)
        wantsLayer = true
        // Increase Contrast turns the wash off: the colour is worked out again as the layer is updated.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(redraw),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func redraw() { needsDisplay = true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = color.cgColor
            layer.cornerRadius = radius
            layer.borderWidth = border == nil ? 0 : 1 / max(1, window?.backingScaleFactor ?? 2)
            layer.borderColor = border?.cgColor
        }
        layer.masksToBounds = radius > 0
    }
}

/// A one-device-pixel line in `color` (a separator between bars), horizontal or vertical by its shape.
final class Hairline: NSView {
    var color: NSColor = .separatorColor { didSet { needsDisplay = true } }

    convenience init(_ color: NSColor = .separatorColor) {
        self.init(frame: .zero)
        self.color = color
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Placed by constraints (its frame's own would hold it at zero).
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
    }

    /// A hairline's thickness on this screen.
    var thickness: CGFloat { 1 / max(1, window?.backingScaleFactor ?? 2) }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

/// A filled 8 pt dot: a connection's colour, a state.
final class DotView: NSView {
    var color: NSColor? { didSet { needsDisplay = true; isHidden = color == nil } }
    let diameter: CGFloat

    init(diameter: CGFloat = 8) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: max(0, (bounds.width - diameter) / 2), dy: max(0, (bounds.height - diameter) / 2))).fill()
    }
}

/// A status in a capsule (11 pt semibold): tinted (its colour at 16 % behind it), the accent's fill, or neutral grey.
/// The radius is half its height; the text is inset by at least that, in its colour as text on its tint.
final class ChipView: NSView {
    enum Style { case tinted(NSColor), accent, neutral }

    let label = NSTextField(labelWithString: "")
    var style: Style { didSet { needsDisplay = true; updateColors() } }

    init(_ text: String, style: Style) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = text
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    private func updateColors() {
        let hue: NSColor
        switch style {
        case .tinted(let color): hue = color
        case .accent: hue = .accent
        case .neutral: hue = .secondaryLabelColor
        }
        label.textColor = hue.asTextOnItsTint
    }

    /// The capsule's colour in `appearance`.
    func fill(in appearance: NSAppearance) -> NSColor {
        switch style {
        case .tinted(let hue): return hue.withAlphaComponent(appearance.isDark ? 0.2 : 0.16)
        case .accent: return .accentFill
        case .neutral: return .hover
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        fill(in: effectiveAppearance).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}
