import Foundation

/// What asks first, and the limits agents work within (plan §2.10). Settings ▸ Safety holds the defaults; a connection
/// can have its own in its Safety tab (`SavedConnection.safety`), and a Production connection starts with
/// `production`. Agents read the settings that apply in `context` and can never change them. Read-only is a switch of
/// each connection (`SavedConnection.readOnly`), and sync scripts always leave out DROP and DELETE unless ticked
/// (`syncLeavesOutDestructive`, not a setting).
public struct SafetySettings: Codable, Hashable {
    /// Ask before an UPDATE or DELETE without WHERE.
    public var askBeforeUnboundedWrite = true
    /// Ask before any statement from the console that writes.
    public var askBeforeConsoleWrite = false
    /// Show the SQL preview before the grid's Apply.
    public var previewBeforeApply = false
    /// Ask before DROP or TRUNCATE (dropping a database always needs its name typed).
    public var askBeforeDrop = true
    /// Dropping or truncating a table needs its name typed too.
    public var typeNameForTables = false
    /// Ask before restoring into a database that has tables, or when the dump names another database.
    public var askBeforeRiskyRestore = true
    /// Agents' changes through the UI wait for the person at the Mac.
    public var askBeforeAgentChanges = true
    /// The most rows an agent's query returns, and how long it may run (seconds).
    public var agentRowCap = 10_000
    public var agentTimeout = 30
    /// Warn when a transaction has been open this long (minutes); keep-alive pings stop for it then.
    public var openTransactionMinutes = 15
    /// Ask before sorting a large table by a column without an index.
    public var askBeforeUnindexedSort = true
    /// Warn when closing a tab or quitting with an open transaction or pending edits.
    public var warnOnClose = true

    /// Sync scripts leave out DROP and DELETE unless ticked: always, in every preset.
    public static let syncLeavesOutDestructive = true

    public init() {}

    /// The strict preset a connection coloured Production starts with.
    public static let production: SafetySettings = {
        var settings = SafetySettings()
        settings.askBeforeConsoleWrite = true
        settings.previewBeforeApply = true
        settings.typeNameForTables = true
        settings.agentRowCap = 1_000
        settings.agentTimeout = 15
        settings.openTransactionMinutes = 5
        return settings
    }()

    /// Settings saved by another version may lack keys; those keep their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let defaults = SafetySettings()
        askBeforeUnboundedWrite = try value(.askBeforeUnboundedWrite, defaults.askBeforeUnboundedWrite)
        askBeforeConsoleWrite = try value(.askBeforeConsoleWrite, defaults.askBeforeConsoleWrite)
        previewBeforeApply = try value(.previewBeforeApply, defaults.previewBeforeApply)
        askBeforeDrop = try value(.askBeforeDrop, defaults.askBeforeDrop)
        typeNameForTables = try value(.typeNameForTables, defaults.typeNameForTables)
        askBeforeRiskyRestore = try value(.askBeforeRiskyRestore, defaults.askBeforeRiskyRestore)
        askBeforeAgentChanges = try value(.askBeforeAgentChanges, defaults.askBeforeAgentChanges)
        agentRowCap = try value(.agentRowCap, defaults.agentRowCap)
        agentTimeout = try value(.agentTimeout, defaults.agentTimeout)
        openTransactionMinutes = try value(.openTransactionMinutes, defaults.openTransactionMinutes)
        askBeforeUnindexedSort = try value(.askBeforeUnindexedSort, defaults.askBeforeUnindexedSort)
        warnOnClose = try value(.warnOnClose, defaults.warnOnClose)
    }
}
