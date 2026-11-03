import AppKit

/// The grid's cells on screen, as tiles that Core Animation moves while the grid scrolls. A view AppKit draws in a scroll
/// view has its visible part rendered again on every scroll step (about 11 ms a frame across 300 columns, a third of the
/// refreshes missed at 120 Hz); a tile is drawn once, when it comes into view or its cells change. Frozen columns have
/// their own strip of tiles, moved to the left of what is shown as the grid scrolls across. The view fills the grid and
/// lets clicks through to it.
final class GridTiles: NSView {
    unowned let grid: DataGridView
    /// A tile's size in points (1 MB of pixels at 2×), measured against 128 to 512 on a side: a short tile draws few
    /// rows when a row of tiles comes into view, a wide one draws few cells twice, across its edges.
    static let size = NSSize(width: 512, height: 128)
    private var tiles: [Index: CALayer] = [:]
    /// The frozen columns' tiles, by row of tiles (x is always 0).
    private var frozen: [Int: CALayer] = [:]
    private lazy var drawer = TileDrawer(self)

    private struct Index: Hashable {
        var x: Int, y: Int
    }

    init(grid: DataGridView) {
        self.grid = grid
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    /// Pictures of the grid (cacheDisplay, into a bitmap) show the tiles over what is drawn here, which is what they
    /// show where there are none (outside what is shown). AppKit's own drawing of the view on screen (into a display
    /// list since macOS 14) stays empty.
    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current?.cgContext.data != nil else { return }
        grid.drawCells(dirtyRect)
    }

    /// Makes the tiles the shown part of the grid needs and drops the others.
    func update() {
        let shown = grid.visibleRect.intersection(bounds), size = Self.size
        var wanted = Set<Index>()
        if !shown.isEmpty {
            for x in Int(shown.minX / size.width)...Int((shown.maxX - 0.5) / size.width) {
                for y in Int(shown.minY / size.height)...Int((shown.maxY - 0.5) / size.height) { wanted.insert(Index(x: x, y: y)) }
            }
        }
        for (index, tile) in tiles where !wanted.contains(index) {
            tile.removeFromSuperlayer()
            tiles[index] = nil
        }
        for index in wanted where tiles[index] == nil {
            tiles[index] = tile(NSRect(origin: NSPoint(x: CGFloat(index.x) * size.width, y: CGFloat(index.y) * size.height), size: size),
                                frozen: false)
        }
        // Frozen columns: drawn once, then only moved across.
        let width = grid.frozenWidth, shift = grid.frozenShift
        let rows = shift > 0 && width > 0 && !shown.isEmpty ? Set(Int(shown.minY / size.height)...Int((shown.maxY - 0.5) / size.height)) : []
        for (row, tile) in frozen where !rows.contains(row) {
            tile.removeFromSuperlayer()
            frozen[row] = nil
        }
        for row in rows {
            let place = NSRect(x: shift, y: CGFloat(row) * size.height, width: width, height: size.height)
            if let tile = frozen[row] {
                if tile.frame.width != width { tile.setNeedsDisplay() }
                tile.frame = place
            } else {
                frozen[row] = tile(place, frozen: true)
            }
        }
    }

    /// A tile; frozen ones go above the others (pictures draw the layers in order).
    private func tile(_ frame: NSRect, frozen: Bool) -> CALayer {
        let tile = CALayer()
        tile.delegate = drawer
        tile.frame = frame
        tile.name = frozen ? "frozen" : nil
        tile.contentsScale = window?.backingScaleFactor ?? 2
        tile.isOpaque = true
        tile.drawsAsynchronously = true  // Core Animation renders the drawing on the GPU: a new row of tiles fits in a frame
        tile.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull()]
        tile.setNeedsDisplay()
        if frozen { layer?.addSublayer(tile) } else { layer?.insertSublayer(tile, at: 0) }
        return tile
    }

    /// Draws a part of the grid again (grid coordinates).
    func invalidate(_ rect: NSRect) {
        for tile in tiles.values where tile.frame.intersects(rect) {
            tile.setNeedsDisplay(rect.offsetBy(dx: -tile.frame.minX, dy: -tile.frame.minY))
        }
        guard rect.minX < grid.frozenWidth else { return }
        for tile in frozen.values where rect.minY < tile.frame.maxY && rect.maxY > tile.frame.minY {
            tile.setNeedsDisplay(rect.offsetBy(dx: 0, dy: -tile.frame.minY))
        }
    }

    func invalidateAll() {
        tiles.values.forEach { $0.setNeedsDisplay() }
        frozen.values.forEach { $0.setNeedsDisplay() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for tile in Array(tiles.values) + Array(frozen.values) where tile.contentsScale != scale {
            tile.contentsScale = scale
            tile.setNeedsDisplay()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateAll()
    }

    fileprivate func draw(_ layer: CALayer, in context: CGContext) {
        let isFrozen = layer.name == "frozen", origin = layer.frame.origin
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // A frozen tile shows its columns where they are in the grid (from x = 0), wherever it has been moved.
        context.translateBy(x: isFrozen ? 0 : -origin.x, y: -origin.y)
        let dirty = context.boundingBoxOfClipPath
        grid.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.content.solid.setFill()
            dirty.fill()  // a tile can reach past the last row or column
            if isFrozen { drawFrozen(dirty) } else { grid.drawCells(dirty) }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The frozen columns' cells in a rect (grid coordinates), with a line along their right edge.
    private func drawFrozen(_ rect: NSRect) {
        let width = grid.frozenWidth
        grid.drawCells(NSRect(x: rect.minX, y: rect.minY, width: max(0, min(rect.maxX, width) - rect.minX), height: rect.height))
        NSColor.separatorColor.setFill()
        NSRect(x: width - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }
}

/// Draws the tiles for the view: a view is already its own layer's delegate, and AppKit draws the view on screen
/// through that. Core Animation draws them on the main thread, as it commits.
private final class TileDrawer: NSObject, CALayerDelegate {
    unowned let tiles: GridTiles

    init(_ tiles: GridTiles) {
        self.tiles = tiles
    }

    func draw(_ layer: CALayer, in context: CGContext) {
        MainActor.assumeIsolated { tiles.draw(layer, in: context) }
    }
}
