import AirSQLCore
import AppKit

/// Settings ▸ Editor: the SQL editor's text. The console (L4) adds its own settings here.
final class EditorPane: SettingsPaneController {
    override func build() {
        form.row("Text size", [choice(\.editorFontSize, id: "settings.editorFontSize",
                                      tip: "Choose the size of the SQL editor's text (13 pt by default)", fontSizes)],
                 caption: "The editor uses SF Mono. ⌘+ and ⌘− change it for a moment; Actual Size goes back to this.")
    }
}
