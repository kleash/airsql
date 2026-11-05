import AirSQLCore
import AppKit

/// Where the window has been: Back and Forward walk the tabs shown, and Recent Tabs lists them, latest first.
extension MainWindowController {
    /// A tab was shown: it goes after the place reached, and what was ahead of that goes.
    func noteVisit(_ tab: Tab) {
        guard !walkingHistory, tabHistory[safe: historyPlace] !== tab else { return }
        tabHistory.removeLast(max(0, tabHistory.count - historyPlace - 1))
        tabHistory.append(tab)
        tabHistory.removeFirst(max(0, tabHistory.count - 100))
        historyPlace = tabHistory.count - 1
    }

    /// The next place in that direction whose tab is still open, leaving out the closed ones on the way.
    private func nextVisit(_ step: Int) -> Int? {
        var place = historyPlace + step
        while let tab = tabHistory[safe: place] {
            if tabs.contains(where: { $0 === tab }), tab !== selectedTab { return place }
            place += step
        }
        return nil
    }

    private func walk(_ step: Int) {
        guard let place = nextVisit(step) else { return NSSound.beep() }
        historyPlace = place
        walkingHistory = true
        select(tabHistory[place])
        walkingHistory = false
    }

    @objc func goBack(_ sender: Any?) { walk(-1) }
    @objc func goForward(_ sender: Any?) { walk(1) }

    var canGoBack: Bool { nextVisit(-1) != nil }
    var canGoForward: Bool { nextVisit(1) != nil }

    /// The open tabs, the one seen last first, then those not yet shown.
    var recentTabs: [Tab] {
        var seen: [Tab] = []
        for tab in tabHistory.reversed() where tabs.contains(where: { $0 === tab }) && !seen.contains(where: { $0 === tab }) { seen.append(tab) }
        return seen + tabs.filter { tab in !seen.contains { $0 === tab } }
    }

    /// Recent Tabs…: the tabs, latest first, with Return on the one before this already chosen; then recent files.
    @objc func showRecentTabs(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let items = recentTabs.filter { $0 !== selectedTab }.map { tab in
            QuickOpenSheet.Item(name: tab.title, place: model.connection(tab.connectionID)?.displayName ?? "Tab") { [weak self] in self?.select(tab) }
        }
        QuickOpenSheet.show(items + fileItems(), title: "Recent Tabs", prompt: "Tab or file", on: window)
    }
}
