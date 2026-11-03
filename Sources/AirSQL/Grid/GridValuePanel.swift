import AirSQLCore
import AppKit

/// The value panel (⇧↩, grid-spec §3): the focused cell's whole value beside the grid, never shortened, as wrapped
/// text, a JSON tree, hex or an image, with its size under it. It follows the cursor; it picks the view that fits the
/// value, and the one chosen stays while it fits.
@MainActor
final class GridValuePanel: NSView {
    enum Mode: Int, CaseIterable {
        case text, json, hex, image

        var title: String { ["Text", "JSON", "Hex", "Image"][rawValue] }
    }

    private let title = label("Value", font: .systemFont(ofSize: 12, weight: .semibold), truncates: true)
    let modes = NSSegmentedControl(labels: Mode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let text = NSTextView()
    private let textScroll = NSScrollView()
    private let outlineScroll = JSONTreeView()
    var outline: NSOutlineView { outlineScroll.outline }
    private let image = NSImageView()
    let footer = label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor, truncates: true)
    private let wrap = checkbox("Wrap", id: "valuePanel.wrap", tip: "Wrap long lines to the panel's width", on: true, target: nil,
                                action: nil)
    private(set) var mode = Mode.text
    /// The mode the person picked, kept while the values fit it.
    private var picked: Mode?
    private var tree: JSONNode?
    private var bytes: [UInt8]?
    private var value: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("valuePanel")
        modes.target = self
        modes.action = #selector(pick(_:))
        modes.segmentStyle = .rounded
        modes.controlSize = .small
        modes.toolTip = "Show the value as text, a JSON tree, hex or an image"
        modes.setAccessibilityIdentifier("valuePanel.mode")
        wrap.target = self
        wrap.action = #selector(toggleWrap(_:))
        wrap.controlSize = .small
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.setAccessibilityIdentifier("valuePanel.text")
        textScroll.documentView = text
        textScroll.hasVerticalScroller = true
        outline.setAccessibilityIdentifier("valuePanel.tree")
        image.imageScaling = .scaleProportionallyDown
        image.setAccessibilityIdentifier("valuePanel.image")
        let top = NSStackView()
        top.setViews([title], in: .leading)
        top.setViews([modes], in: .trailing)
        top.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        let bottom = NSStackView()
        bottom.setViews([footer], in: .leading)
        bottom.setViews([wrap], in: .trailing)
        bottom.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)
        for bar in [top, bottom] { bar.setHuggingPriority(.defaultHigh, for: .vertical) }
        for view in [top, textScroll, outlineScroll, image, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for body in [textScroll, outlineScroll, image] as [NSView] {
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: top.bottomAnchor), body.bottomAnchor.constraint(equalTo: bottom.topAnchor),
                body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor), top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor), bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        show(column: nil, value: nil, bytes: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows a cell: `value` nil for NULL (or no cell when `column` is nil); `bytes` as the server sent them.
    func show(column: GridColumn?, value: String?, bytes: [UInt8]?) {
        self.value = value
        self.bytes = bytes ?? value.map { Array($0.utf8) }
        title.stringValue = column.map { "Value · \($0.name)" } ?? "Value"
        title.toolTip = title.stringValue
        let first = value?.first(where: { !$0.isWhitespace })
        tree = first == "{" || first == "[" ? value.flatMap(JSONNode.parse) : nil
        let picture = column?.kind == .binary ? self.bytes.flatMap { NSImage(data: Data($0)) } : nil
        image.image = picture
        let fits: [Mode: Bool] = [.text: value != nil, .json: tree != nil, .hex: value != nil, .image: picture != nil]
        for item in Mode.allCases { modes.setEnabled(fits[item] == true, forSegment: item.rawValue) }
        if let picked, fits[picked] == true { mode = picked } else { mode = picture != nil ? .image : tree != nil ? .json : .text }
        modes.selectedSegment = value == nil ? -1 : mode.rawValue
        footer.stringValue = column == nil ? "Select a cell to see its whole value here" : value == nil ? "NULL" : describe()
        footer.toolTip = footer.stringValue
        refresh()
    }

    private func describe() -> String {
        let count = bytes?.count ?? 0
        let size = "\(count.formatted()) byte\(count == 1 ? "" : "s")"
        switch mode {
        case .json: return "Valid JSON · " + size
        case .image: return image.image.map { "\(Int($0.size.width)) × \(Int($0.size.height)) image · " + size } ?? size
        default:
            let characters = value?.count ?? 0
            return "\(characters.formatted()) character\(characters == 1 ? "" : "s") · " + size
        }
    }

    private func refresh() {
        textScroll.isHidden = !(mode == .text || mode == .hex) || value == nil
        outlineScroll.isHidden = mode != .json || tree == nil
        image.isHidden = mode != .image
        wrap.isHidden = mode != .text
        switch mode {
        case .text: text.string = value ?? ""
        case .hex: text.string = Self.hexDump(bytes ?? [])
        case .json: outlineScroll.tree = tree
        case .image: break
        }
        setWrap(mode == .text && wrap.state == .on)
    }

    /// Offsets, 16 bytes in hex and as ASCII per line; the first 64 KB.
    static func hexDump(_ bytes: [UInt8]) -> String {
        var lines: [String] = []
        for start in stride(from: 0, to: min(bytes.count, 65_536), by: 16) {
            let chunk = bytes[start..<min(start + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(chunk.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08X  ", start) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii)
        }
        if bytes.count > 65_536 { lines.append("… \((bytes.count - 65_536).formatted()) more bytes") }
        return lines.joined(separator: "\n")
    }

    private func setWrap(_ on: Bool) {
        text.isHorizontallyResizable = !on
        textScroll.hasHorizontalScroller = !on
        text.textContainer?.widthTracksTextView = on
        text.textContainer?.containerSize = NSSize(width: on ? textScroll.contentSize.width : .greatestFiniteMagnitude,
                                                   height: .greatestFiniteMagnitude)
        text.autoresizingMask = on ? .width : []
        if on { text.frame.size.width = textScroll.contentSize.width }
    }

    @objc private func pick(_ sender: NSSegmentedControl) {
        guard let chosen = Mode(rawValue: sender.selectedSegment) else { return }
        picked = chosen
        mode = chosen
        footer.stringValue = value == nil ? "NULL" : describe()
        refresh()
    }

    @objc private func toggleWrap(_ sender: Any?) { setWrap(wrap.state == .on) }
}
