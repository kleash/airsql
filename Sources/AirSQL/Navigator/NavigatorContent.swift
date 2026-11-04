import AirSQLCore
import AppKit

/// Where the navigator hands over to the table tab (`TableDataController`).
@MainActor
enum NavigatorHooks {
    /// A table's or view's rows, filtered by a WHERE condition when one is given: what a single click shows in the
    /// preview tab. A double-click and Open Data use `MainWindowController.openTableData`, which reuses an open tab.
    static var tableData: (OpenConnection, DatabaseObject, String?) -> NSViewController = { open, table, condition in
        guard let model = open.model, let context = Editors.context(model.connection(open.id), in: model) else {
            return TextContent(title: table.name, caption: "Connect to the server again to see its rows.", text: "")
        }
        return TableDataController(model: model, context: context, database: table.database, table: table.name, filter: condition)
    }
}

/// The tab a single click in the tree shows things in (plan §2.12): a database's tables, a table's rows, an object's
/// definition. The next single click replaces what it shows; a double-click opens a tab of its own.
@MainActor
final class PreviewContent: NSViewController, TabContent {
    private(set) var shown: NSViewController

    init(_ content: NSViewController) {
        shown = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = NSView()
        view.setAccessibilityIdentifier("preview")
        place(shown)
    }

    func show(_ content: NSViewController) {
        (shown as? TableDataController)?.abandoned = true
        (shown as? TableDataController)?.cancelQuery(nil)  // its rows aren't wanted any more
        shown.view.removeFromSuperview()
        shown.removeFromParent()
        shown = content
        place(content)
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    private func place(_ content: NSViewController) {
        addChild(content)
        view.addSubview(content.view)
        content.view.pin(to: view)
    }

    var statusAccessory: NSView? { (shown as? TabContent)?.statusAccessory }
    var isEdited: Bool { (shown as? TabContent)?.isEdited ?? false }
    var transactionBadge: String? { (shown as? TabContent)?.transactionBadge }
    var reopen: ((MainWindowController) -> Void)? { (shown as? TabContent)?.reopen }
    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        if let content = shown as? TabContent { content.shouldClose(answer) } else { answer(true) }
    }
}

extension MainWindowController {
    /// Shows `content` in the window's preview tab (made the first time), named `title`. A preview with pending changes
    /// stays open as a tab, with its dot, and a new preview takes over.
    func preview(_ content: NSViewController, title: String, connection: UUID) {
        if let tab = tabs.first(where: { $0.content is PreviewContent && $0.tabContent?.isEdited == false }),
           let preview = tab.content as? PreviewContent {
            preview.show(content)
            tab.connectionID = connection
            tab.title = title
            select(tab)
        } else {
            open(PreviewContent(content), title: title, connection: connection)
        }
    }
}

/// Read-only text with a title and a caption: an object's CREATE statement, the results of maintenance. What has to
/// be read from the server loads off the main thread under a spinner.
@MainActor
final class TextContent: NSViewController, TabContent {
    private let heading: String
    private var captionText: String
    private var body: String
    private let load: (() async throws -> String)?
    private let textView = NSTextView()
    private let caption = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, wraps: true)
    private let spinner = NSProgressIndicator()

    init(title: String, caption: String, text: String = "", load: (() async throws -> String)? = nil) {
        heading = title
        captionText = caption
        body = text
        self.load = load
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// What the text shows now (tests read it).
    var text: String { textView.string }

    override func loadView() {
        let root = SurfaceView(.content)
        root.setAccessibilityIdentifier("navigator.text")
        let title = label(heading, font: .systemFont(ofSize: 15, weight: .semibold), truncates: true)
        title.toolTip = heading
        caption.stringValue = captionText
        caption.setAccessibilityIdentifier("navigator.text.caption")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setAccessibilityLabel("Loading")
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: Spacing.unit, height: Spacing.unit)
        textView.drawsBackground = false
        textView.setAccessibilityIdentifier("navigator.text.body")
        textView.string = body
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let line = Hairline()
        [title, spinner, caption, line, scroll].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            spinner.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: Spacing.unit),
            spinner.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            spinner.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.double),
            caption.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Spacing.half),
            caption.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.double),
            line.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: Spacing.unit + Spacing.half),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        if let load { reload(load) }
    }

    private func reload(_ load: @escaping () async throws -> String) {
        spinner.startAnimation(nil)
        Task { [weak self] in
            do {
                let text = try await load()
                self?.textView.string = text
            } catch {
                self?.caption.stringValue = "Couldn't read it: " + ((error as? AirSQLError)?.message ?? error.localizedDescription)
                self?.caption.textColor = .statusBad
            }
            self?.spinner.stopAnimation(nil)
        }
    }

    /// An object's CREATE statement, read through the schema session; the editors (L5b) replace it.
    static func definition(_ open: OpenConnection, _ object: DatabaseObject) -> TextContent {
        TextContent(title: object.name, caption: "The \(object.kind.noun)’s definition in \(object.database), as the server gives "
                    + "it (read-only)") { [weak open] in
            guard let open else { throw AirSQLError.disconnected }
            return try await open.createStatement(object) + ";\n"
        }
    }
}

extension OpenConnection {
    /// The statement that makes the object, as SHOW CREATE gives it, read through the schema session.
    func createStatement(_ object: DatabaseObject) async throws -> String {
        let session = try await connection.session(.schema)
        guard let rows = try await session.query(NavigatorSQL.showCreate(object)).first?.rows, rows.rowCount > 0,
              let column = rows.columns.firstIndex(where: { $0.name.hasPrefix("Create ") || $0.name == "SQL Original Statement" })
        else { throw AirSQLError(.notFound, "The server didn't show how \(object.name) is made.") }
        return rows.string(0, column) ?? ""
    }

    /// A routine's parameters in order, read through the schema session.
    func parameters(_ routine: DatabaseObject) async throws -> [NavigatorSQL.Parameter] {
        let session = try await connection.session(.schema)
        return try await session.rows(NavigatorSQL.parameters(routine, noBackslashEscapes: session.noBackslashEscapes)).map {
            NavigatorSQL.Parameter(mode: $0[0] ?? "IN", name: $0[1] ?? "", type: $0[2] ?? "")
        }
    }
}
