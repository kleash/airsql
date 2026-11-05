import AirSQLCore
import AppKit

/// Settings ▸ Editor: the SQL editor's text. The console (L4) adds its own settings here.
final class EditorPane: SettingsPaneController {
    override func build() {
        let families = NSFontManager.shared.availableFontFamilies.filter { family in
            NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)?.isFixedPitch ?? false
        }
        form.row("Font", [choice(\.editorFontFamily, id: "settings.editorFontFamily", tip: "Choose the SQL editor's font, from those whose letters are all one width",
                                 [("SF Mono", "")] + families.map { ($0, $0) })])
        form.row("Text size", [choice(\.editorFontSize, id: "settings.editorFontSize",
                                      tip: "Choose the size of the SQL editor's text (13 pt by default)", fontSizes)],
                 caption: "⌘+ and ⌘− change it for a moment; Actual Size goes back to this.")
        form.row("", [toggle("Wrap long lines", id: "settings.editorWordWrap", tip: "Wrap long lines at the editor's edge instead of scrolling sideways",
                             \.editorWordWrap)])
        form.row("Tab width", [choice(\.editorTabWidth, id: "settings.editorTabWidth", tip: "Choose how many spaces wide a tab or an indent is",
                                      [2, 3, 4, 8].map { ("\($0) spaces", $0) })])
        form.row("", [toggle("Indent with tabs", id: "settings.editorUsesTabs", tip: "Put in a tab character for Tab and indents instead of spaces",
                             \.editorUsesTabs)])
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
