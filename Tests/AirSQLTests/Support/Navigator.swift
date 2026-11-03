import AppKit
import Foundation
@testable import AirSQL
@testable import AirSQLCore

/// Opens connection `id` in `model` with its schema replayed from a recording (SchemaFixtures, no server): the tree,
/// the database view and the menus work; anything that would run SQL fails. Returns once the schema has loaded.
@MainActor
@discardableResult
func openReplayed(_ model: AppModel, _ id: UUID, recording: String = SchemaFixtures.mariadb118) async -> OpenConnection {
    let connection = Connection(options: ConnectOptions(name: "Replay", host: "127.0.0.1", port: 1, user: "replay"))
    let open = OpenConnection(id: id, connection: connection, model: model,
                              includes: { ["airsql_fixture", "airsql other"].contains($0) }, source: ReplaySource(recording))
    model.open[id] = open
    open.load()
    _ = await eventually(timeout: 10) { open.snapshot.server != nil && open.loading.isEmpty }
    return open
}

/// The sidebar row of a tree node of this kind (its database and group opened first), and its middle (points from the
/// window's top left).
@MainActor
func treeRow(_ main: MainWindowController, _ kind: SidebarNode.Kind) -> (row: Int, point: (Double, Double))? {
    let outline = main.sidebar.outline
    var parents: [SidebarNode.Kind] = []
    switch kind {
    case .category(let id, let database, _): parents = [.database(id, database)]
    case .object(let id, let object): parents = [.database(id, object.database), .category(id, object.database, object.kind)]
    default: break
    }
    for parent in parents { main.sidebar.treeNodes[parent].map { outline.expandItem($0) } }
    guard let node = main.sidebar.treeNodes[kind] else { return nil }
    let row = outline.row(forItem: node)
    guard row >= 0 else { return nil }
    outline.scrollRowToVisible(row)
    return (row, windowPoint(outline.rect(ofRow: row), in: outline))
}
