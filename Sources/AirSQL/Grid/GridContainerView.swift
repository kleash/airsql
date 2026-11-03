import AirSQLCore
import AppKit

/// The view a screen adds for a grid: the cells' scroll view, with the column header along its top and the row numbers
/// down its left. They follow the cells' scrolling, and each is drawn again only when the cells scroll along it: as the
/// scroll view's rulers, both were drawn again on every frame.
final class GridContainerView: NSView {
    unowned let grid: DataGridView
    let corner = GridCornerView()
    private var shownOrigin = NSPoint(x: -1, y: -1)

    init(grid: DataGridView) {
        self.grid = grid
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        addSubview(grid.scrollView)
        addSubview(grid.header)
        addSubview(grid.rowNumbers)
        addSubview(corner)
        let content = grid.scrollView.contentView
        content.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(cellsDidScroll), name: NSView.boundsDidChangeNotification, object: content)
        tile()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        tile()
    }

    /// The cells scrolled: the header follows across, the row numbers down.
    @objc private func cellsDidScroll(_ note: Notification) {
        let origin = grid.scrollView.contentView.bounds.origin
        if origin.x != shownOrigin.x { grid.header.needsDisplay = true }
        if origin.y != shownOrigin.y { grid.rowNumbers.needsDisplay = true }
        shownOrigin = origin
    }

    /// The corner, the header along the top, the row numbers down the left beside the cells, the cells in the rest.
    func tile() {
        let top = grid.header.thickness, left = grid.rowNumbers.thickness
        let width = max(0, bounds.width - left), height = max(0, bounds.height - top)
        corner.frame = NSRect(x: 0, y: 0, width: left, height: top)
        grid.header.frame = NSRect(x: left, y: 0, width: width, height: top)
        grid.scrollView.frame = NSRect(x: left, y: top, width: width, height: height)
        grid.scrollView.tile()
        grid.rowNumbers.frame = NSRect(x: 0, y: top, width: left, height: min(height, grid.scrollView.contentView.frame.height))
    }
}

/// Where the header and the row numbers meet.
final class GridCornerView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.bar.solid.setFill()
        dirtyRect.intersection(bounds).fill()  // since macOS 14 it can reach past the view
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - pixel, width: bounds.width, height: pixel).fill()
        NSRect(x: bounds.width - pixel, y: 0, width: pixel, height: bounds.height).fill()
    }
}
