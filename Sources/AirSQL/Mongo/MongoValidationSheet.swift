import AirSQLCore
import AppKit

/// Validation Rules… (mongo-plan, Phase 2 admin): the collection's validator in shell form ($jsonSchema or query
/// operators) with its level and action, as listCollections gives them now. Check Existing Documents counts those the
/// rules would refuse ({ $nor: [rules] }) before anything changes; Preview… shows the collMod, which runs as the other
/// admin commands do.
@MainActor
final class MongoValidationSheet: MongoAdminSheet {
    let validator: NSTextView
    let level: NSPopUpButton
    let action: NSPopUpButton
    let checkButton: NSButton
    let checked = label("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor, wraps: true)
    /// The documents that failed the rules last checked, and the rules they were checked against.
    private(set) var failing: (count: Int64, validator: BSONDocument)?
    private var checking: Task<Void, Never>?
    private let ref: MongoCollectionRef

    /// Reads the collection's rules now, then shows the sheet on `window`.
    static func open(_ ref: MongoCollectionRef, model: AppModel, on window: NSWindow) {
        let activity = model.activity.start("Read the rules of \(ref.collection)", connection: ref.open.saved.id)
        Task { @MainActor in
            defer { activity.end() }
            do {
                let found = try await ref.open.connection.session(.data, slot: "admin").listCollections(database: ref.database)
                guard let info = found.first(where: { $0.name == ref.collection }) else {
                    return showError("\(ref.database).\(ref.collection) isn't there any more.", title: "No rules to show", on: window)
                }
                MongoValidationSheet(ref, info: info, model: model, window: window).begin(on: window)
            } catch {
                showError(error.localizedDescription, title: "The rules of \(ref.collection) weren't read", on: window)
            }
        }
    }

    private init(_ ref: MongoCollectionRef, info: MongoCollectionInfo, model: AppModel, window parent: NSWindow) {
        self.ref = ref
        let now = MongoAdmin.validation(info)
        let (scroll, text) = shellTextView(now.validator, id: "mongoValidation.validator",
                                           tip: "The rules in shell form, such as { $jsonSchema: { … } } or { qty: { $gte: 0 } }; empty: none",
                                           height: 220)
        validator = text
        level = popup(MongoAdmin.validationLevels, selected: MongoAdmin.validationLevels.firstIndex(of: now.level) ?? 0,
                      id: "mongoValidation.level",
                      tip: "Check every insert and update (strict), leave documents that already fail alone (moderate), or none",
                      target: nil, action: nil)
        action = popup(MongoAdmin.validationActions, selected: MongoAdmin.validationActions.firstIndex(of: now.action) ?? 0,
                       id: "mongoValidation.action", tip: "Refuse a document that fails the rules (error), or only log it (warn)",
                       target: nil, action: nil)
        checkButton = button("Check Existing Documents", id: "mongoValidation.check",
                             tip: "Count the collection's documents that fail these rules; nothing changes", target: nil, action: nil)
        let form = Form()
        form.row("Level", [level])
        form.row("Action", [action])
        let check = NSStackView(views: [checkButton, checked])
        check.alignment = .firstBaseline
        checked.setAccessibilityIdentifier("mongoValidation.checked")
        let content = NSStackView(views: [scroll, form.finish(), check])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        check.widthAnchor.constraint(equalToConstant: 540).isActive = true
        var sheet: MongoValidationSheet?
        super.init(id: "mongoValidation", title: "Validation Rules", heading: "Validation Rules of \(ref.database).\(ref.collection)",
                   note: "Documents written to the collection must match these rules. The collMod command shows before it runs.",
                   content: content, width: 580) { command in
            guard let sheet else { return }
            let rules = (try? MongoAdmin.validator(sheet.validator.string)) ?? BSONDocument()
            var warnings: [String] = []
            if let failing = sheet.failing, failing.validator == rules, failing.count > 0 {
                warnings.append("\(failing.count.formatted()) document\(failing.count == 1 ? "" : "s") already fail\(failing.count == 1 ? "s" : "") "
                                + "these rules: they stay, but an update to one must make it pass (unless the level is moderate).")
            }
            MongoAdminActions.run(command, on: ref.open, model: model, window: parent, title: "Change the rules of \(ref.collection)",
                                  heading: "Change the validation rules of \(ref.database).\(ref.collection)?",
                                  caption: rules.fields.isEmpty ? "The collection's rules are removed: any document may be written."
                                    : "Documents already there aren't checked; inserts and updates are, from now on.",
                                  action: "Apply", destructive: false, warnings: warnings) {
                ref.open.refresh(ref.database)
            }
        }
        sheet = self
        checkButton.target = self
        checkButton.action = #selector(checkDocuments(_:))
        make = { [unowned self] in
            try MongoAdmin.setValidation(database: ref.database, collection: ref.collection, validator: MongoAdmin.validator(validator.string),
                                         level: level.titleOfSelectedItem ?? "strict", action: action.titleOfSelectedItem ?? "error")
        }
        window?.initialFirstResponder = validator
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Counts the documents that fail the rules as typed, on the admin session; the sheet says how many.
    @objc func checkDocuments(_ sender: Any?) {
        let rules: BSONDocument
        do { rules = try MongoAdmin.validator(validator.string) } catch {
            NSSound.beep()
            checked.stringValue = "\(error)"
            return fit()
        }
        guard !rules.fields.isEmpty else {
            checked.stringValue = "No rules: every document passes."
            return fit()
        }
        checkButton.isEnabled = false
        checked.stringValue = "Counting…"
        let ref = self.ref
        checking = Task { @MainActor [weak self] in
            let words: String
            do {
                let count = try await ref.open.connection.session(.data, slot: "admin")
                    .countFailing(database: ref.database, collection: ref.collection, validator: rules)
                self?.failing = (count, rules)
                words = count == 0 ? "Every document passes these rules."
                    : "\(count.formatted()) document\(count == 1 ? " fails" : "s fail") these rules."
            } catch {
                words = "Not counted: " + error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            checking = nil
            checked.stringValue = words
            checkButton.isEnabled = true
            fit()
        }
    }

    override func finish() {
        if let checking {
            checking.cancel()
            let connection = ref.open.connection
            Task { try? await connection.session(.data, slot: "admin").cancel() }
        }
        super.finish()
    }
}
