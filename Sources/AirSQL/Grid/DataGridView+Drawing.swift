import AirSQLCore
import AppKit

extension DataGridView {
    /// Whether the grid has the keyboard: its selection is drawn in the accent then, else in grey.
    var isFocused: Bool {
        guard let window, window.isKeyWindow else { return false }
        return window.firstResponder === self || editor != nil
    }

    /// Draws the cells in a rect, for a tile or a picture: backgrounds, text, lines, focus ring.
    func drawCells(_ dirtyRect: NSRect) {
        // Since macOS 14 a view isn't clipped to itself and the rect to draw can reach past it.
        let dirtyRect = dirtyRect.intersection(bounds)
        let content = NSColor.content.solid
        content.setFill()
        dirtyRect.fill()
        guard let source, let context = NSGraphicsContext.current?.cgContext else { return }
        let rows = rows(in: dirtyRect), columns = columns(in: dirtyRect)
        guard !rows.isEmpty, !columns.isEmpty else { return }
        drawnCells += rows.count * columns.count
        // A screen's worth above and below, so a paged source fetches before the rows show.
        source.prefetch(self.rows(in: visibleRect.insetBy(dx: 0, dy: -visibleRect.height)))
        let scale = window?.backingScaleFactor ?? 2, pixel = 1 / scale
        let focused = isFocused
        let left = offsets[columns.lowerBound], right = offsets[columns.upperBound]
        let top = CGFloat(rows.lowerBound) * rowHeight, bottom = CGFloat(rows.upperBound) * rowHeight
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // Backgrounds as opaque colours, resolved once a draw.
        let zebra = NSColor.gridZebra.solid, focus = NSColor.gridFocus.solid
        let selected = focused ? NSColor.gridSelection.solid : NSColor.unemphasizedSelectedContentBackgroundColor.solid
        let selectedRow = focused ? NSColor.selectedRow.solid : selected
        let marks: [GridMark: NSColor] = [.edited: NSColor.pendingEdit.solid, .inserted: NSColor.pendingInsert.solid,
                                          .deleted: NSColor.pendingDelete.solid]
        // Booleans (TINYINT(1), BIT(1)) as checkboxes: ticked in the accent, empty in grey; made when one shows.
        let booleans = Set(columns.map { columnOrder[$0] }.filter { source.columns[$0].isBoolean })
        var boxes: [Bool: NSImage] = [:]
        func checkbox(_ on: Bool) -> NSImage? {
            if let image = boxes[on] { return image }
            let size = NSImage.SymbolConfiguration(pointSize: styles.regular.pointSize + 2, weight: .regular)
            let colours = NSImage.SymbolConfiguration(paletteColors: on ? [.white, .accent] : [.secondaryLabelColor])
            boxes[on] = NSImage(systemSymbolName: on ? "checkmark.square.fill" : "square", accessibilityDescription: nil)?
                .withSymbolConfiguration(size.applying(colours))
            return boxes[on]
        }
        // Transposed, a column holds every type: each cell looks as its source column does.
        let transposed = source as? TransposedSource
        // Attributes and "…" for each look, made once per draw.
        var looks: [Int: (attributes: [NSAttributedString.Key: Any], ellipsis: CTLine)] = [:]
        func look(_ column: Int, _ info: GridColumn, isNull: Bool, deleted: Bool) -> (attributes: [NSAttributedString.Key: Any], ellipsis: CTLine) {
            let key = column * 4 + (isNull ? 1 : 0) + (deleted ? 2 : 0)
            if let look = looks[key] { return look }
            let attributes = styles.attributes(info, isNull: isNull, deleted: deleted)
            let look = (attributes, CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes)))
            looks[key] = look
            return look
        }

        for row in rows {
            let y = CGFloat(row) * rowHeight
            if row % 2 == 1 {
                zebra.setFill()
                NSRect(x: left, y: y, width: right - left, height: rowHeight).fill()
            }
            let wholeRow = selection.containsRow(row)
            for column in columns {
                let rect = NSRect(x: offsets[column], y: y, width: offsets[column + 1] - offsets[column], height: rowHeight)
                let sourceColumn = columnOrder[column], info = transposed?.sourceColumn(row, sourceColumn) ?? source.columns[sourceColumn]
                let mark = source.mark(row, sourceColumn), position = GridPosition(row: row, column: column)
                if let fill = marks[mark] {
                    fill.setFill()
                    rect.fill()
                } else if let tint = cellTint?(row, sourceColumn) {
                    tint.setFill()
                    rect.fill(using: .sourceOver)
                }
                if focused, selection.cursor == position {
                    focus.setFill()
                    rect.fill()
                } else if selection.contains(position) {
                    (wholeRow ? selectedRow : selected).setFill()
                    rect.fill()
                }
                if mark == .edited {
                    NSColor.pendingEditLine.setFill()
                    NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height).fill()
                }

                if editor?.position == position { continue }  // the editor shows the text
                let cell = source.cell(row, sourceColumn)
                let available = rect.width - 2 * GridStyles.padding
                if cell == .loading {
                    NSColor.dataNull.withAlphaComponent(0.25).setFill()
                    NSBezierPath(roundedRect: NSRect(x: rect.minX + GridStyles.padding, y: y + (rowHeight - 8) / 2,
                                                     width: max(0, min(available, 64)), height: 8), xRadius: 4, yRadius: 4).fill()
                    continue
                }
                if booleans.contains(sourceColumn), case .text(let value) = cell, value == "0" || value == "1", let image = checkbox(value == "1") {
                    let size = image.size
                    image.draw(in: NSRect(x: rect.minX + GridStyles.padding, y: y + ((rowHeight - size.height) / 2).rounded(),
                                          width: size.width, height: size.height),
                               from: .zero, operation: .sourceOver, fraction: mark == .deleted ? 0.4 : 1, respectFlipped: true, hints: nil)
                    continue
                }
                var text = GridStyles.text(cell, nullText: nullText)
                guard !text.isEmpty, available > 0 else { continue }
                // No more characters than the narrowest glyphs could fit: laying out long values was most of a screen's
                // drawing time. Shortened, it always ends in "…".
                let limit = Int(available / (styles.regular.pointSize * 0.2)) + 1
                if !info.isKey, text.count > limit { text = String(text.prefix(limit)) + "…" }
                let deleted = mark == .deleted
                // NULL and what the server fills in at Apply (auto, default, ƒ NOW()) look alike: grey and slanted.
                let (attributes, ellipsis) = look(transposed == nil ? sourceColumn : row * columnCount + sourceColumn, info, isNull: cell == .null || cell.isPlaceholder, deleted: deleted)
                var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                if width > available {
                    if info.isKey { widenKeyColumn(sourceColumn, to: width + 2 * GridStyles.padding) }
                    if let cut = CTLineCreateTruncatedLine(line, Double(available), .end, ellipsis) {
                        line = cut
                        width = CGFloat(CTLineGetTypographicBounds(cut, nil, nil, nil))
                    }
                }
                let x = ((info.kind == .number ? rect.maxX - GridStyles.padding - width : rect.minX + GridStyles.padding) * scale)
                    .rounded() / scale
                context.textPosition = CGPoint(x: x, y: y + styles.baseline)
                CTLineDraw(line, context)
                if deleted {
                    NSColor.secondaryLabelColor.setFill()
                    NSRect(x: x, y: y + styles.baseline - (styles.regular.xHeight / 2).rounded(), width: width, height: pixel * 2).fill()
                }
                // A foreign key's label, grey, in the room the value leaves: after text, before a number.
                if cell != .null, let suffix = cellSuffix?(row, sourceColumn) {
                    let start = info.kind == .number ? rect.minX + GridStyles.padding : x + width + GridStyles.padding
                    let room = info.kind == .number ? x - start - GridStyles.padding : rect.maxX - GridStyles.padding - start
                    let words = NSAttributedString(string: suffix, attributes: [.font: styles.regular,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.secondaryLabelColor.cgColor])
                    if room > 16, let label = CTLineCreateTruncatedLine(CTLineCreateWithAttributedString(words), Double(room), .end, ellipsis) {
                        context.textPosition = CGPoint(x: (start * scale).rounded() / scale, y: y + styles.baseline)
                        CTLineDraw(label, context)
                    }
                }
            }
        }

        // One-pixel lines between cells and rows.
        NSColor.softSeparator.setFill()
        for column in columns {
            NSRect(x: offsets[column + 1] - pixel, y: top, width: pixel, height: bottom - top).fill()
        }
        for row in rows {
            NSRect(x: left, y: CGFloat(row + 1) * rowHeight - pixel, width: right - left, height: pixel).fill()
        }
        if focused, let cursor = selection.cursor, rows.contains(cursor.row), columns.contains(cursor.column) {
            NSColor.accent.setStroke()
            let ring = NSBezierPath(rect: cellRect(cursor).insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
