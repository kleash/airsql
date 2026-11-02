import Combine
import Foundation

/// One piece of work that may take a while (plan §2.11): a query, a connect, an export, an agent's call. It is listed
/// in the status bar while it runs, with its elapsed time or progress, and Cancel when it can be cancelled; the agent
/// snapshot lists it too (`wait until=idle`). Start it with `ActivityCenter.start` and `end()` it when done.
@MainActor
public final class Activity: ObservableObject, Identifiable {
    public let id = UUID()
    public let title: String
    /// The saved connection it works on, if any.
    public let connection: UUID?
    public let started: Date
    /// 0…1 when the work knows how far it is; nil: elapsed time only.
    @Published public var progress: Double?
    /// What it is doing now, in plain words ("1.9 GB of 3.1 GB", "SSH to bastion").
    @Published public var detail: String?
    /// Cancelled, waiting for the work to stop.
    @Published public private(set) var cancelling = false
    private let onCancel: (() -> Void)?
    fileprivate weak var center: ActivityCenter?

    fileprivate init(title: String, connection: UUID?, started: Date, cancel: (() -> Void)?) {
        self.title = title
        self.connection = connection
        self.started = started
        onCancel = cancel
    }

    public var canCancel: Bool { onCancel != nil && !cancelling }

    /// Asks the work to stop (its cancel handler, once); it is listed until it ends.
    public func cancel() {
        guard let onCancel, !cancelling else { return }
        cancelling = true
        onCancel()
    }

    /// The work is done (or failed, or stopped): it leaves the list.
    public func end() {
        center?.remove(self)
    }

    public func elapsed(at now: Date = Date()) -> TimeInterval { max(0, now.timeIntervalSince(started)) }
}

/// The work running now, oldest first.
@MainActor
public final class ActivityCenter: ObservableObject {
    public static let shared = ActivityCenter()

    @Published public private(set) var running: [Activity] = []
    /// The time; tests set it.
    public var now: () -> Date = Date.init

    public init() {}

    /// Registers work: `title` in plain words ("Running a query on Production"), its connection, and how to cancel it
    /// (nil when it can't be).
    public func start(_ title: String, connection: UUID? = nil, cancel: (() -> Void)? = nil) -> Activity {
        let activity = Activity(title: title, connection: connection, started: now(), cancel: cancel)
        activity.center = self
        running.append(activity)
        return activity
    }

    public var isIdle: Bool { running.isEmpty }

    /// Cancels every activity that can be cancelled.
    public func cancelAll() {
        running.filter(\.canCancel).forEach { $0.cancel() }
    }

    fileprivate func remove(_ activity: Activity) {
        running.removeAll { $0 === activity }
    }
}
