import AirSQLCore
import AppKit

/// Saves a snippet: its name, the abbreviation Tab expands, a folder to list it under, and its SQL, where `$name$` is a
/// field to fill in and `$SELECTION$` the selected text.
@MainActor
final class SnippetSheet: NSViewController {
    private let snippet: SQLSnippet
    private let save: (SQLSnippet) -> Void
    private lazy var name = textField(snippet.name, placeholder: "Orders of a customer", id: "snippet.name", tip: "Type the name the panel lists it by", width: 340)
    private lazy var abbreviation = textField(snippet.abbreviation, placeholder: "None", id: "snippet.abbreviation",
                                              tip: "Type a short word that turns into this snippet with Tab", width: 120)
    private lazy var folder = textField(snippet.folder, placeholder: "None", id: "snippet.folder", tip: "Type the folder to list it under", width: 200)
    private let body = NSTextView.scrollableTextView()
    private var bodyView: NSTextView { body.documentView as! NSTextView }

    init(_ snippet: SQLSnippet, save: @escaping (SQLSnippet) -> Void) {
        self.snippet = snippet
        self.save = save
        super.init(nibName: nil, bundle: nil)
        title = "Snippet"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        bodyView.string = snippet.body
        bodyView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        bodyView.isRichText = false
        bodyView.isAutomaticQuoteSubstitutionEnabled = false
        bodyView.toolTip = "Type the SQL; $name$ is a field to fill in, $SELECTION$ the selected text, $END$ where the cursor ends"
        bodyView.setAccessibilityIdentifier("snippet.body")
        body.borderType = .bezelBorder
        body.translatesAutoresizingMaskIntoConstraints = false
        let form = Form()
        form.row("Name", [name])
        form.row("Abbreviation", [abbreviation])
        form.row("Folder", [folder])
        form.row("SQL", [body], caption: "$name$ is a field Tab goes to, $SELECTION$ the selected text, $END$ where the cursor ends.")
        let grid = form.finish()
        let saveButton = button("Save", id: "snippet.save", tip: "Save this snippet", target: self, action: #selector(saved(_:)), primary: true)
        saveButton.keyEquivalent = "\r"
        let cancel = button("Cancel", id: "snippet.cancel", tip: "Close without saving", target: self, action: #selector(cancelled(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let root = NSView()
        for view in [grid, saveButton, cancel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalToConstant: 420), body.heightAnchor.constraint(equalToConstant: 160),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double),
            saveButton.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: Spacing.double),
            saveButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double),
            saveButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.double),
            cancel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -Spacing.unit),
        ])
        view = root
    }

    @objc private func saved(_ sender: Any?) {
        var result = snippet
        result.name = name.stringValue.trimmingCharacters(in: .whitespaces)
        result.abbreviation = abbreviation.stringValue.trimmingCharacters(in: .whitespaces)
        result.folder = folder.stringValue.trimmingCharacters(in: .whitespaces)
        result.body = bodyView.string
        if result.name.isEmpty { result.name = String(result.body.prefix(40)) }
        guard !result.body.isEmpty else { return NSSound.beep() }
        save(result)
        dismiss(nil)
    }

    @objc private func cancelled(_ sender: Any?) { dismiss(nil) }
}
