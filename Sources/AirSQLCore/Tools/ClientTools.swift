import Foundation

/// A client tool's version, as its --version line says it.
public struct ToolVersion: Equatable, Sendable, CustomStringConvertible {
    public enum Family: String, Sendable {
        case mysql, mariadb

        public var title: String { self == .mysql ? "MySQL" : "MariaDB" }
    }

    public var family: Family
    /// The server release the tool comes with: [8, 4, 3], [11, 8, 3].
    public var numbers: [Int]

    public init(family: Family, numbers: [Int]) {
        self.family = family
        self.numbers = numbers
    }

    /// "8.4.3".
    public var number: String { numbers.map(String.init).joined(separator: ".") }
    /// "MySQL 8.4.3".
    public var description: String { family.title + " " + number }

    /// Major × 100 + minor (804, 1108), to compare with a server's.
    public var majorMinor: Int { numbers[0] * 100 + (numbers.count > 1 ? numbers[1] : 0) }

    /// Reads the release from what `mysql --version` and its kin print:
    /// - "mysql  Ver 8.4.3 for macos14.7 on arm64 (Homebrew)" (MySQL 8 and later);
    /// - "mysqldump  Ver 10.13 Distrib 5.7.44, for osx10.19 (x86_64)" (MySQL 5.7, MariaDB before 10.6);
    /// - "mariadb-dump from 11.8.3-MariaDB, client 10.19 for osx10.20 (arm64)" (MariaDB 10.6 and later).
    public static func parse(_ text: String) -> ToolVersion? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        func release(after marker: String) -> [Int]? {
            guard let range = line.range(of: marker) else { return nil }
            let digits = line[range.upperBound...].prefix { $0.isNumber || $0 == "." }
            let numbers = digits.split(separator: ".").compactMap { Int($0) }
            return numbers.count >= 2 ? numbers : nil
        }
        guard let numbers = release(after: "Distrib ") ?? release(after: " from ") ?? release(after: "Ver ") else { return nil }
        return ToolVersion(family: line.localizedCaseInsensitiveContains("MariaDB") ? .mariadb : .mysql, numbers: numbers)
    }
}

/// A mysql or mysqldump program on this Mac (or MariaDB's mariadb and mariadb-dump) and its version, nil when it
/// didn't say one AirSQL understands.
public struct ClientTool: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// mysql or mariadb: restore, run a file, Terminal.
        case client
        /// mysqldump or mariadb-dump: export.
        case dump

        /// The program names, MariaDB's first: MariaDB installs the mysql names as links to them, deprecated.
        public var names: [String] { self == .client ? ["mariadb", "mysql"] : ["mariadb-dump", "mysqldump"] }
    }

    public var path: String
    public var version: ToolVersion?
    /// The program is there and can be run (a chosen path may not be).
    public var found: Bool

    public init(path: String, version: ToolVersion?, found: Bool = true) {
        self.path = path
        self.version = version
        self.found = found
    }

    /// "mariadb-dump".
    public var name: String { (path as NSString).lastPathComponent }
    /// "mariadb-dump 11.8.3", or the name alone.
    public var title: String { version.map { name + " " + $0.number } ?? name }
}

/// How well a tool suits a server (plan §2.9): fine, usable with a warning, or not at all, each with its reason.
public enum ToolFit: Equatable, Sendable {
    case good(String)
    case warning(String)
    case unusable(String)

    public var message: String {
        switch self {
        case .good(let text), .warning(let text), .unusable(let text): return text
        }
    }

    public var isUsable: Bool {
        if case .unusable = self { return false }
        return true
    }
}

/// Finds the client tools (Settings ▸ Client tools): in Homebrew's folders, /usr/local/mysql/bin, MAMP's and PATH.
public enum ClientTools {
    /// The oldest tools AirSQL runs: their options (--ssl-mode, --set-gtid-purged, MariaDB's TLS switches) and logins.
    public static let oldestMySQL = 507
    public static let oldestMariaDB = 1003

    /// Where AirSQL looks, in order: each mysql* and mariadb* Homebrew formula's bin (Apple silicon, then Intel) and
    /// Homebrew's bin, /usr/local/mysql/bin (MySQL's installer), MAMP's, then PATH. File work: off the main thread.
    public static func searchFolders(environment: [String: String] = ProcessInfo.processInfo.environment,
                                     root: String = "") -> [String] {
        let files = FileManager.default
        func formulas(_ opt: String) -> [String] {
            let names = (try? files.contentsOfDirectory(atPath: root + opt)) ?? []
            return names.filter { $0.hasPrefix("mysql") || $0.hasPrefix("mariadb") }.sorted().reversed()
                .map { root + opt + "/" + $0 + "/bin" }
        }
        let mamp = root + "/Applications/MAMP/Library/bin"
        let mampVersions = ((try? files.contentsOfDirectory(atPath: mamp)) ?? []).filter { $0.hasPrefix("mysql") }.sorted()
            .reversed().map { mamp + "/" + $0 + "/bin" }
        let path = (environment["PATH"] ?? "").split(separator: ":").map { root + $0 }
        var seen = Set<String>()
        return (formulas("/opt/homebrew/opt") + [root + "/opt/homebrew/bin"] + formulas("/usr/local/opt")
                + [root + "/usr/local/bin", root + "/usr/local/mysql/bin"] + mampVersions + [mamp] + path)
            .filter { seen.insert($0).inserted }
    }

    /// The programs of `kind` in `folders`, each once (a link and what it points to are one program). File work.
    public static func candidates(_ kind: ClientTool.Kind, in folders: [String]) -> [String] {
        var seen = Set<String>(), found: [String] = []
        for folder in folders {
            for name in kind.names {
                let path = folder + "/" + name
                guard FileManager.default.isExecutableFile(atPath: path) else { continue }
                let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                if seen.insert(real).inserted { found.append(path) }
            }
        }
        return found
    }

    /// What `path --version` says (at most 5 s); nil when it doesn't run or says something else.
    public static func version(of path: String) async -> ToolVersion? {
        let result = await Runner.run([path, "--version"], timeout: 5)
        return result.status == 0 ? ToolVersion.parse(result.output) : nil
    }

    /// The tools of `kind` on this Mac with their versions: `chosen` (Settings, or a connection's own) first when it is
    /// set, then those found, by family and newest first. A chosen path that isn't there is still listed, without a version.
    public static func find(_ kind: ClientTool.Kind, chosen: String = "",
                            folders: [String] = searchFolders()) async -> [ClientTool] {
        var paths = candidates(kind, in: folders)
        if !chosen.isEmpty { paths.removeAll { $0 == chosen } }
        var tools: [ClientTool] = []
        for path in paths { tools.append(ClientTool(path: path, version: await version(of: path))) }
        // By family (MariaDB, MySQL), each newest first.
        tools.sort { a, b in
            let (familyA, familyB) = (a.version?.family.rawValue ?? "~", b.version?.family.rawValue ?? "~")
            if familyA != familyB { return familyA < familyB }
            return (b.version?.numbers ?? []).lexicographicallyPrecedes(a.version?.numbers ?? [])
        }
        if !chosen.isEmpty {
            let found = FileManager.default.isExecutableFile(atPath: chosen)
            tools.insert(ClientTool(path: chosen, version: found ? await version(of: chosen) : nil, found: found), at: 0)
        }
        return tools
    }

    /// The tool to use for `server`: of its family and at least its release, the oldest such (closest to the server);
    /// else the newest of its family; else the newest that can be used at all.
    public static func best(_ tools: [ClientTool], for server: ServerInfo?) -> ClientTool? {
        let usable = tools.filter { fit($0, server: server).isUsable }
        guard let server else { return usable.first }
        let family = usable.filter { $0.version?.family.rawValue == server.flavor.rawValue }
        let serverRelease = server.versionNumber / 100
        let newEnough = family.filter { ($0.version?.majorMinor ?? 0) >= serverRelease }
        return newEnough.last ?? family.first ?? usable.first
    }

    /// How well `tool` suits `server` (nil: not known yet): too old or silent tools can't be used; another family's or
    /// an older release's tool can, with a warning.
    public static func fit(_ tool: ClientTool, server: ServerInfo?) -> ToolFit {
        guard tool.found else {
            return .unusable("\(tool.path) isn't there or can't be run. Choose another in Settings ▸ Client Tools.")
        }
        guard let version = tool.version else {
            return .unusable("\(tool.name) didn't say its version, so AirSQL can't tell which options it takes. Choose "
                + "another in Settings ▸ Client Tools.")
        }
        let oldest = version.family == .mysql ? oldestMySQL : oldestMariaDB
        guard version.majorMinor >= oldest else {
            return .unusable("\(tool.title) is too old: AirSQL needs MySQL 5.7 or MariaDB 10.3 tools, or newer. Install newer "
                + "client tools (for example with Homebrew) and choose them in Settings ▸ Client Tools.")
        }
        guard let server else { return .good(version.description) }
        let serverTitle = (server.flavor == .mysql ? "MySQL " : "MariaDB ") + release(server.versionNumber)
        if version.family.rawValue != server.flavor.rawValue {
            return .warning("\(version.family.title)'s tool for a \(serverTitle) server: it may miss or fail on "
                + "\(server.flavor == .mysql ? "MySQL" : "MariaDB")-only features. \(server.flavor == .mysql ? "MySQL" : "MariaDB")'s "
                + "own tools are safer.")
        }
        if version.majorMinor < server.versionNumber / 100 {
            return .warning("\(tool.title) is older than the server (\(serverTitle)): it may miss newer features. A tool "
                + "of \(release(server.versionNumber)) or newer is safer.")
        }
        return .good("✓ suits the server (\(serverTitle))")
    }

    /// 80413 → "8.4".
    private static func release(_ number: Int) -> String { "\(number / 10000).\(number / 100 % 100)" }
}
