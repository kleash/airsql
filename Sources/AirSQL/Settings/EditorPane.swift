import AirSQLCore
import AppKit

/// Settings ▸ Editor: the SQL editor's text. The console (L4) adds its own settings here.
final class EditorPane: SettingsPaneController {
    override func build() {
        form.row("Text size", [choice(\.editorFontSize, id: "settings.editorFontSize",
                                      tip: "Choose the size of the SQL editor's text (13 pt by default)", fontSizes)],
                 caption: "The editor uses SF Mono. ⌘+ and ⌘− change it for a moment; Actual Size goes back to this.")
        form.row("", [toggle("Wrap long lines", id: "settings.editorWordWrap", tip: "Wrap long lines at the editor's edge instead of scrolling sideways",
                             \.editorWordWrap)])
        for (index, inspection) in SQLInspections.all.enumerated() {
            form.row(index == 0 ? "Checks" : "", [inspectionToggle(inspection)])
        }
    }

    private func inspectionToggle(_ inspection: SQLInspections.Inspection) -> NSButton {
        let box = checkbox(inspection.title, id: "settings.inspection.\(inspection.code)", tip: "Underline this in the SQL editor while typing",
                           on: !model.data.settings.disabledInspections.contains(inspection.code), target: self, action: #selector(inspectionChanged(_:)))
        box.identifier = NSUserInterfaceItemIdentifier(inspection.code)
        return box
    }

    @objc private func inspectionChanged(_ sender: NSButton) {
        guard let code = sender.identifier?.rawValue else { return }
        var disabled = Set(model.data.settings.disabledInspections)
        if sender.state == .on { disabled.remove(code) } else { disabled.insert(code) }
        model.data.settings.disabledInspections = disabled.sorted()
    }
}
