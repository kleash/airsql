import AirSQLCore
import AppKit

/// Split Right: two tabs side by side. The strip, the status bar and every command follow `selectedTab`, as ever; it is
/// whichever side has the focus, and showing another tab puts it on that side.
extension MainWindowController {
    /// The selected tab changed: a tab from outside the split takes the side of the one it follows.
    func paneFollows(from old: Tab?) {
        guard let panes = splitPanes, let tab = selectedTab else { return splitPanes = nil }
        if tab === panes.left || tab === panes.right { return }
        splitPanes = panes.left === old ? (tab, panes.right) : panes.right === old ? (panes.left, tab) : nil
    }

    /// The focus moved to the other side: that tab is now the selected one.
    func followFocus() {
        guard let panes = splitPanes, let focus = window?.firstResponder as? NSView else { return }
        guard let tab = [panes.left, panes.right].first(where: { $0 !== selectedTab && focus.isDescendant(of: $0.content.view) }) else { return }
        select(tab)
    }

    /// The next tab goes beside the one on show, or a new query if it's alone; pressed again, one tab shows.
    @objc func splitRight(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        if splitPanes != nil {
            splitPanes = nil
            return refresh()
        }
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if tabs.count > 1 {
            split(tab, tabs[(index + 1) % tabs.count])
        } else {
            let other = openConsole(text: "", title: nil, connection: tab.connectionID)
            split(tab, other)
        }
    }

    private func split(_ left: Tab, _ right: Tab) {
        splitPanes = (left, right)
        select(left)
    }

    /// A tab's menu: that tab, now the one on show, goes beside the tab shown before (the item carries it).
    @objc func showBeside(_ sender: Any?) {
        guard let before = (sender as? NSMenuItem)?.representedObject as? Tab, let tab = selectedTab, before !== tab else { return }
        split(before, tab)
    }

    @objc func goToOtherPane(_ sender: Any?) {
        guard let panes = splitPanes else { return }
        select(panes.left === selectedTab ? panes.right : panes.left)
        focusEditor(sender)
        if window?.firstResponder === window { focusResults(sender) }
    }
}

/// The two sides of a split, with an accent line over the one in use.
@MainActor
final class PanesView: NSSplitView {
    private let sides: [(tab: Tab, line: SurfaceView)]

    init(_ left: Tab, _ right: Tab, in frame: NSRect, selected: Tab?) {
        sides = [(left, SurfaceView(.clear)), (right, SurfaceView(.clear))]
        super.init(frame: frame)
        isVertical = true
        dividerStyle = .thin
        setAccessibilityIdentifier("panes")
        for (tab, line) in sides {
            let side = NSView(frame: NSRect(x: 0, y: 0, width: frame.width / 2, height: frame.height))
            let content = tab.content.view
            content.removeFromSuperview()
            line.translatesAutoresizingMaskIntoConstraints = false
            side.addSubview(content)
            side.addSubview(line)
            content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: side.topAnchor), line.heightAnchor.constraint(equalToConstant: 2),
                line.leadingAnchor.constraint(equalTo: side.leadingAnchor), line.trailingAnchor.constraint(equalTo: side.trailingAnchor),
                content.topAnchor.constraint(equalTo: line.bottomAnchor), content.bottomAnchor.constraint(equalTo: side.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: side.leadingAnchor), content.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            ])
            addArrangedSubview(side)
        }
        mark(selected)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func mark(_ selected: Tab?) {
        for (tab, line) in sides { line.color = tab === selected ? .accent : .clear }
    }
}
