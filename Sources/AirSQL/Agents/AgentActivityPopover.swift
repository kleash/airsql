import AirSQLCore
import AppKit

/// The agents' popover (the status bar's agent chip, Agent Activity): every call agents made since AirSQL opened, newest
/// last, with how it ended, and the switch to turn agents off.
@MainActor
final class AgentActivityPopover: NSViewController {
    private let service: AgentService
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var observer: NSObjectProtocol?

    init(service: AgentService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let allowed = service.model.data.settings.agentsAllowed
        let title = label("Agents", font: .systemFont(ofSize: 12, weight: .semibold))
        let failed = allowed && service.problem != nil
        let state = ChipView(failed ? "Can't start" : allowed ? "On" : "Off", style: allowed && !failed ? .accent : .tinted(.statusWarning))
        state.toolTip = service.problem.map { "Agents can't start: " + $0 }
        let action = allowed
            ? button("Turn Agents Off", id: "agents.turnOff", tip: Commands.turnAgentsOff.tip, target: nil,
                     action: Commands.turnAgentsOff.action)
            : button("Set Up Agents…", id: "agents.setUp", tip: Commands.setUpAgents.tip, target: nil,
                     action: Commands.setUpAgents.action)
        action.controlSize = .small
        let header = NSStackView(views: [title, state, NSView(), action])
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        let document = FlippedStack(list)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let caption = label("Agents never see passwords and can't change data: they read within each connection's access "
                            + "(Settings ▸ Agents) and propose SQL in console tabs for you to run.",
                            font: .systemFont(ofSize: 11), color: .tertiaryLabelColor, wraps: true)
        caption.preferredMaxLayoutWidth = 380
        let stack = NSStackView(views: [header, scroll, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.unit
        for view in [header, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let root = NSView()
        root.setAccessibilityIdentifier("popover.agent")
        root.addSubview(stack)
        stack.pin(to: root, insets: .all(Spacing.double))
        root.widthAnchor.constraint(equalToConstant: 420).isActive = true
        view = root
        rebuild()
        observer = NotificationCenter.default.addObserver(forName: AgentService.didChange, object: service, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    /// One row per call: what was asked and when, then how it ended.
    private func rebuild() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let events = service.events
        if events.isEmpty {
            let empty = service.model.data.settings.agentsAllowed
                ? "No agent has used AirSQL yet. Add AirSQL to Claude Code or Gemini CLI in Settings ▸ Agents."
                : "Agents are off. Turn them on in Settings ▸ Agents to let Claude Code or Gemini CLI read your schemas."
            let text = label(empty, font: .systemFont(ofSize: 12), color: .secondaryLabelColor, wraps: true)
            text.preferredMaxLayoutWidth = 380
            list.addArrangedSubview(text)
        }
        for event in events {
            let what = label(event.summary, font: .systemFont(ofSize: 12), truncates: true)
            what.toolTip = event.client + ": " + event.summary
            let when = label(Self.time.string(from: event.time), font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                             color: .tertiaryLabelColor)
            when.setContentCompressionResistancePriority(.required, for: .horizontal)
            let top = NSStackView(views: [what, NSView(), when])
            let outcome = event.outcome ?? "running…"
            let result = label(event.client + " · " + outcome, font: .systemFont(ofSize: 11),
                               color: event.failed ? .statusBad : .secondaryLabelColor, truncates: true)
            result.toolTip = outcome
            let row = NSStackView(views: [top, result])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 1
            list.addArrangedSubview(row)
            for view in [row, top] { view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        }
        list.layoutSubtreeIfNeeded()
        let height = min(max(list.fittingSize.height, 24), 280)
        scroll.constraints.filter { $0.firstAttribute == .height }.forEach { scroll.removeConstraint($0) }
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.documentView?.scroll(NSPoint(x: 0, y: list.fittingSize.height))
    }
}

/// A stack as a scroll view's document, laid out from the top.
private final class FlippedStack: NSView {
    init(_ stack: NSStackView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.pin(to: self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
}

extension AppDelegate {
    /// Tools ▸ Agents ▸ Agent Activity (and the agent chip's menu): the agents' popover, under the chip.
    @objc func showAgentActivity(_ sender: Any?) {
        guard let main, let model else { return }
        if model.agentStatus == nil { model.agentStatus = "Agents off" }
        main.showWindow(nil)
        main.updateStatus()
        main.statusBar.agent.showPopover()
    }

    /// Help ▸ AI Agents: the page of AirSQL Help about agents.
    @objc func showAgentGuide(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "agents.html", relativeTo: HelpPage.site)?.absoluteURL ?? HelpPage.site)
    }
}
