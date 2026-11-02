import Foundation

/// What a dump file does besides filling tables (plan §2.9, restore safety): the databases it switches to, creates or
/// drops, whether it sets GTID_PURGED, and how many tables it drops first. The restore sheet says which database the
/// file will really write to before anything runs.
public struct DumpScan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case use, createDatabase, dropDatabase, gtidPurged
    }

    /// A statement the person must know about, on its line (from 1).
    public struct Finding: Equatable, Sendable {
        public var kind: Kind
        public var database: String?
        public var line: Int
    }

    public var findings: [Finding] = []
    /// Tables the file drops (DROP TABLE, as mysqldump writes before each CREATE TABLE).
    public var droppedTables = 0

    public init() {}

    /// Notes what a statement starting on `line` does, from its significant tokens' texts: no comments, executable
    /// comments' marks left out (their text is code), quoted names without their quotes, symbols as written.
    public mutating func add(words: [String], line: Int) {
        let upper = words.map { $0.uppercased() }
        func name(after index: Int) -> String? {
            var i = index
            if upper.count > i + 1, upper[i] == "IF" { i += upper[i + 1] == "NOT" ? 3 : 2 }
            return i < words.count ? words[i] : nil
        }
        guard let first = upper.first else { return }
        switch first {
        case "USE":
            if let database = name(after: 1) { findings.append(Finding(kind: .use, database: database, line: line)) }
        case "CREATE":
            let at = upper.count > 2 && upper[1] == "OR" && upper[2] == "REPLACE" ? 3 : 1
            if upper.count > at, upper[at] == "DATABASE" || upper[at] == "SCHEMA", let database = name(after: at + 1) {
                findings.append(Finding(kind: .createDatabase, database: database, line: line))
            }
        case "DROP":
            if upper.count > 1, upper[1] == "DATABASE" || upper[1] == "SCHEMA", let database = name(after: 2) {
                findings.append(Finding(kind: .dropDatabase, database: database, line: line))
            } else if upper.count > 1, upper[1] == "TABLE" || (upper[1] == "TEMPORARY" && upper.count > 2) {
                droppedTables += 1 + upper.filter { $0 == "," }.count
            }
        case "SET":
            if upper.contains(where: { $0.contains("GTID_PURGED") || $0.contains("GTID_SLAVE_POS") }) {
                findings.append(Finding(kind: .gtidPurged, database: nil, line: line))
            }
        default:
            break
        }
    }

    /// The database the file's tables go into when it is run in `picked`: the first it switches to, else `picked`.
    public func target(picked: String) -> String {
        findings.first { $0.kind == .use }?.database ?? picked
    }

    /// What the restore's confirmation must say, run in `picked`, one sentence per finding that matters: databases other
    /// than `picked` it switches to, creates or drops (even `picked` itself, dropped), and GTID_PURGED.
    public func warnings(picked: String) -> [String] {
        var warnings: [String] = [], said = Set<String>()
        for finding in findings {
            let name = finding.database ?? ""
            let text: String
            switch finding.kind {
            case .use where name != picked:
                text = "The file switches to the database “\(name)” (line \(finding.line)): what follows is written there, not in “\(picked)”."
            case .createDatabase where name != picked:
                text = "The file creates the database “\(name)” (line \(finding.line)), if it isn't there."
            case .dropDatabase:
                text = "The file drops the database “\(name)” (line \(finding.line)), with every table in it."
            case .gtidPurged:
                text = "The file sets GTID_PURGED (line \(finding.line)): on a server that has GTIDs already this fails or changes "
                    + "replication. Dumps made with --set-gtid-purged=OFF leave it out."
            default:
                continue
            }
            if said.insert("\(finding.kind)\(name)").inserted { warnings.append(text) }
        }
        return warnings
    }
}
