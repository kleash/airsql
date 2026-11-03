import AirSQLCore
import AppKit

/// Settings ▸ Connections: how much of a server's schema loads at connect. The connections lane (L1) adds its own.
final class ConnectionsPane: SettingsPaneController {
    override func build() {
        form.row("Load details up to", [number(\.detailsTableThreshold, id: "settings.detailsTableThreshold",
                                               tip: "Type the most tables whose details load at connect; above it, a database's load when you open it "
                                                   + "(3,000 by default)", range: 100...1_000_000, width: 90),
                                        label("tables", color: .secondaryLabelColor)],
                 caption: "Names always load at connect. On a server with more tables than this, a database's columns, "
                    + "indexes and keys load when you open it, so connecting stays quick and the server isn't loaded down.")
    }
}
