import Foundation

/// A change shown in the SQL preview sheet before it runs (grid Apply, table editor, drop and rename, restore, recon
/// sync), and what "Save as Liquibase changeset" saves: the statements, a title, and the connection they run on.
public struct ChangeSQL: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var title: String
    public var statements: [String]
    public var connection: UUID

    public init(title: String, statements: [String], connection: UUID) {
        self.title = title
        self.statements = statements
        self.connection = connection
    }

    /// The statements as the preview shows them and Copy SQL copies them: each ended by a semicolon, one per line.
    public var text: String {
        statements.map { statement in
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasSuffix(";") ? trimmed : trimmed + ";"
        }.joined(separator: "\n")
    }

    /// Without the statements, wherever a change gets printed: a user's can hold a password.
    public var description: String { title }
    public var debugDescription: String { title }
}

/// Where a saved connection is now, for the sidebar, the status bar and the summary. Set by whatever connects (the
/// routes and the driver); idle connections have no entry.
public enum ConnectionState: Equatable {
    /// `step` says which hop or step is under way ("SSH to bastion.example.com").
    case connecting(step: String)
    /// `server` is the server's name and version ("MariaDB 11.8.3").
    case connected(server: String)
    /// Connecting failed or the connection dropped: the reason in plain words.
    case failed(String)
}
