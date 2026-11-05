import Foundation

/// How the sidebar's tree shows a server's objects (View ▸ Tree). New fields go last with a default (see `init(from:)`).
public struct TreeSettings: Codable, Equatable {
    /// Objects straight under their database, without a group for each kind.
    public var flat = false
    public var favouritesOnly = false
    /// Sizes and bars where the schema cache has them; off: estimated rows, as far as it has them.
    public var showsSizes = true
    public var showsComments = false
    /// Objects that share a name's first part (`wp_`) fold into a group.
    public var groupsByPrefix = false
    /// The tree selects what the tab shown is about.
    public var followsTab = false
    /// `DatabaseObject.Kind`s left out, by raw value.
    public var hiddenKinds: [String] = []
    /// Objects left out everywhere: names or patterns with * and ?, separated by commas.
    public var hiddenNames = ""
    /// The page a table tab opens on (0 Data, 1 Structure, 2 DDL): what was chosen last, as you walk the tree.
    public var tablePage = 0
    /// View ▸ SQL Log: the log shows under the tabs while a server is connected.
    public var showsLog = true
    /// How tall the log is there, in points.
    public var logHeight = 100.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let defaults = TreeSettings()
        flat = try value(.flat, defaults.flat)
        favouritesOnly = try value(.favouritesOnly, defaults.favouritesOnly)
        showsSizes = try value(.showsSizes, defaults.showsSizes)
        showsComments = try value(.showsComments, defaults.showsComments)
        groupsByPrefix = try value(.groupsByPrefix, defaults.groupsByPrefix)
        followsTab = try value(.followsTab, defaults.followsTab)
        hiddenKinds = try value(.hiddenKinds, defaults.hiddenKinds)
        hiddenNames = try value(.hiddenNames, defaults.hiddenNames)
        tablePage = try value(.tablePage, defaults.tablePage)
        showsLog = try value(.showsLog, defaults.showsLog)
        logHeight = try value(.logHeight, defaults.logHeight)
    }

    /// Whether `hiddenNames` leaves this object out; patterns compare without case.
    public func hides(_ name: String) -> Bool {
        hiddenNames.split { $0 == "," || $0 == ";" || $0.isNewline }.map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { !$0.isEmpty && fnmatch($0, name, FNM_CASEFOLD) == 0 }
    }
}

/// What a filter box matches: part of a name, without case; between slashes, a regular expression (`/^wp_/`).
public struct NameFilter {
    private let text: String
    private let regex: NSRegularExpression?

    public init(_ text: String) {
        self.text = text
        var pattern: String?
        if text.count > 2, text.hasPrefix("/"), text.hasSuffix("/") { pattern = String(text.dropFirst().dropLast()) }
        // Half-typed brackets aren't a regular expression yet: until they are, it matches as text.
        regex = pattern.flatMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }

    public func matches(_ name: String) -> Bool {
        if let regex { return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil }
        return text.isEmpty || name.localizedCaseInsensitiveContains(text)
    }
}

/// Group by Prefix: names sharing a first part fold into a group of it.
public enum TreeGrouping {
    /// The fewest names a group is worth folding.
    public static let smallest = 3

    /// A name's first part with its underscore (`wp_`); nil: it has none.
    public static func prefix(of name: String) -> String? {
        guard let end = name.firstIndex(of: "_"), end != name.startIndex, name.index(after: end) != name.endIndex else { return nil }
        return String(name[...end])
    }

    /// The names in their order, each prefix with enough of them as one group where its first name was.
    public static func groups(_ names: [String]) -> [(prefix: String?, names: [String])] {
        let byPrefix = Dictionary(grouping: names) { prefix(of: $0) ?? "" }
        var placed = Set<String>()
        return names.compactMap { name in
            guard let prefix = prefix(of: name), let members = byPrefix[prefix], members.count >= smallest else { return (nil, [name]) }
            return placed.insert(prefix).inserted ? (prefix, members) : nil
        }
    }
}
