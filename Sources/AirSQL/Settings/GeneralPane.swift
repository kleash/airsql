import AirSQLCore
import AppKit

/// Settings ▸ General: the look, and where AirSQL keeps its settings.
final class GeneralPane: SettingsPaneController {
    override func build() {
        form.row("Appearance", [choice(\.appearance, id: "settings.appearance",
                                       tip: "Follow the Mac's light or dark mode (System, the default), or always use one",
                                       [("System", .system), ("Light", .light), ("Dark", .dark)])],
                 caption: "Porcelain is the light look, Deep Water the dark one.")
        let folder = label(Self.shown(Store.directory), font: .systemFont(ofSize: NSFont.systemFontSize), truncates: true)
        folder.toolTip = Self.shown(Store.directory)
        folder.isSelectable = true
        form.row("Settings folder", [folder, action("Show in Finder", id: "settings.showFolder",
                                                    tip: "Show the folder with AirSQL's settings and SQL log in Finder") {
            [weak self] in self?.reveal(Store.directory)
        }], caption: "Saved connections and settings, as JSON. Passwords are in your Keychain, never here.")
    }
}
