import AirSQLCore
import AppKit

/// Settings ▸ Client Tools: the mysql and mysqldump AirSQL runs for export, restore and Terminal. The client tools lane
/// (L6) adds finding them and their versions.
final class ClientToolsPane: SettingsPaneController {
    private var fields: [WritableKeyPath<AppSettings, String>: NSTextField] = [:]

    override func build() {
        form.row("Client", [field(\.clientPath, id: "settings.clientPath", what: "mysql or mariadb"),
                            choose(\.clientPath, id: "settings.chooseClient", what: "mysql or mariadb")])
        form.row("Dump tool", [field(\.dumpPath, id: "settings.dumpPath", what: "mysqldump or mariadb-dump"),
                               choose(\.dumpPath, id: "settings.chooseDump", what: "mysqldump or mariadb-dump")],
                 caption: "Empty: AirSQL looks in Homebrew's folders, /usr/local/mysql/bin, MAMP and your PATH. A connection "
                    + "can use others in its Options tab.")
    }

    private func field(_ path: WritableKeyPath<AppSettings, String>, id: String, what: String) -> NSTextField {
        let field = text(path, id: id, tip: "The \(what) program to run; empty: found automatically",
                         placeholder: "Found automatically")
        fields[path] = field
        return field
    }

    private func choose(_ path: WritableKeyPath<AppSettings, String>, id: String, what: String) -> NSButton {
        action("Choose…", id: id, tip: "Choose the \(what) program to use") { [weak self] in
            guard let self, let window = self.view.window else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.message = "Choose the \(what) program."
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                self.model.data.settings[keyPath: path] = url.path
                self.fields[path]?.stringValue = url.path
            }
        }
    }
}
