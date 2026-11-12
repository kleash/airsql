import Foundation

/// The figures of a MongoDB server's host page and Disk Usage (mongo-plan, Phase 2 "host"), from serverStatus,
/// replSetGetStatus, currentOp, dbStats and `$collStats`: what each reply says, in the form the page's lists show.
public enum MongoHost {
    /// A row of the Server pane: a figure, and its rate per second between two samples where it is a counter.
    public struct Figure: Hashable, Sendable {
        public var name: String
        public var value: String
        public var number: Double?
        public var perSecond: Double?
        /// A size or a count of bytes: shown as such, per second too.
        public var bytes = false
        public var tip: String
    }

    /// serverStatus's figures; with the sample before, the counters' rates per second between the two.
    public static func figures(_ status: BSONDocument, previous: BSONDocument?) -> [Figure] {
        var found: [Figure] = []
        let elapsed = previous.flatMap { before in
            number(status, "uptimeMillis").flatMap { now in number(before, "uptimeMillis").map { (now - $0) / 1000 } }
        }
        func text(_ name: String, _ value: String?, _ tip: String) {
            if let value, !value.isEmpty { found.append(Figure(name: name, value: value, tip: tip)) }
        }
        func figure(_ name: String, _ path: String, counter: Bool = false, bytes: Bool = false, scale: Double = 1, _ tip: String) {
            guard let value = number(status, path).map({ $0 * scale }) else { return }
            var rate: Double?
            if counter, let elapsed, elapsed > 0, let before = previous.flatMap({ number($0, path) }).map({ $0 * scale }), value >= before {
                rate = (value - before) / elapsed
            }
            found.append(Figure(name: name, value: bytes ? DiskUsage.size(Int(value)) : Int64(value).formatted(), number: value,
                                perSecond: rate, bytes: bytes, tip: tip))
        }
        text("Version", string(status, "version"), "The server's MongoDB version")
        text("Host", string(status, "host"), "The server's own name for itself")
        text("Process", string(status, "process"), "mongod holds data; mongos routes to the shards")
        text("Uptime", number(status, "uptime").map { duration($0) }, "How long the server has been running")
        text("Storage Engine", string(status, "storageEngine.name"), "What keeps the data on disk")
        text("Replica Set", string(status, "repl.setName"), "The replica set this server is a member of")
        text("Primary", string(status, "repl.primary"), "The member that takes writes now")
        figure("Connections Open", "connections.current", "Clients connected now")
        figure("Connections Available", "connections.available", "How many more clients may connect")
        figure("Connections Made", "connections.totalCreated", counter: true, "Connections made since the server started")
        for (name, key) in [("Inserts", "insert"), ("Queries", "query"), ("Updates", "update"), ("Deletes", "delete"),
                            ("Get Mores", "getmore"), ("Commands", "command")] {
            figure(name, "opcounters." + key, counter: true, "\(name) since the server started (opcounters), with the rate between two reads")
        }
        figure("Memory Resident", "mem.resident", bytes: true, scale: 1_048_576, "Memory the server holds in RAM")
        figure("Memory Virtual", "mem.virtual", bytes: true, scale: 1_048_576, "Memory the server has mapped")
        figure("Cache Used", "wiredTiger.cache.bytes currently in the cache", bytes: true, "What WiredTiger's cache holds now")
        figure("Cache Size", "wiredTiger.cache.maximum bytes configured", bytes: true, "The most WiredTiger's cache may hold")
        figure("Network In", "network.bytesIn", counter: true, bytes: true, "Bytes received since the server started")
        figure("Network Out", "network.bytesOut", counter: true, bytes: true, "Bytes sent since the server started")
        figure("Requests", "network.numRequests", counter: true, "Requests received since the server started")
        return found
    }

    /// A member of the replica set as replSetGetStatus describes it.
    public struct Member: Hashable, Sendable {
        public var name: String
        public var state: String
        public var healthy: Bool
        /// Seconds behind the primary's last write; nil without a primary.
        public var lag: Int64?
        /// The round trip from the member that answered; nil for that member itself.
        public var ping: Int64?
        public var uptime: Double?
        /// The member that answered.
        public var isSelf: Bool
        /// What its last heartbeat said, when it said something.
        public var message: String?
    }

    public static func members(_ status: BSONDocument) -> [Member] {
        guard case .array(let all)? = status["members"] else { return [] }
        let members = all.compactMap { value -> BSONDocument? in if case .document(let member) = value { return member } else { return nil } }
        // A member that can't be reached reports an optime at the epoch (0): no lag to show, not 56 years of it.
        func optime(_ member: BSONDocument) -> Int64? {
            if case .datetime(let ms)? = member["optimeDate"], ms > 0, number(member, "health") == 1 { return ms } else { return nil }
        }
        let primary = members.first { string($0, "stateStr") == "PRIMARY" }.flatMap(optime)
        return members.map { member in
            Member(name: string(member, "name") ?? "", state: string(member, "stateStr") ?? "", healthy: number(member, "health") == 1,
                   lag: primary.flatMap { top in optime(member).map { max(0, top - $0) / 1000 } }, ping: number(member, "pingMs").map(Int64.init),
                   uptime: number(member, "uptime"), isSelf: member["self"] == .bool(true),
                   message: string(member, "lastHeartbeatMessage").flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// An operation currentOp lists.
    public struct Operation: Sendable {
        public var opid: BSONValue
        /// The opid as text: the list's key.
        public var id: String
        public var op: String
        public var namespace: String
        public var microseconds: Int64?
        /// Its client's address, and the app it says it is; nil for the server's own work.
        public var client: String?
        public var description: String
        public var plan: String
        /// The server's own: no client, or the internal `__system` user (replication, monitoring).
        public var isInternal: Bool

        /// Why AirSQL won't kill it; nil: it may.
        public var killRefusal: String? {
            isInternal ? "Operation \(id) is the server's own work (replication, monitoring or a background task): AirSQL doesn't kill it" : nil
        }
    }

    public static func operations(_ inprog: [BSONDocument]) -> [Operation] {
        inprog.compactMap { op in
            guard let opid = op["opid"] else { return Operation?.none }
            var client = string(op, "client") ?? string(op, "client_s")
            if let app = string(op, "appName"), !app.isEmpty, client != nil { client! += " (\(app))" }
            var users: [BSONValue] = []
            if case .array(let found)? = op["effectiveUsers"] { users = found }
            let system = users.contains { if case .document(let user) = $0 { return user["user"] == .string("__system") } else { return false } }
            let comment = MongoChanges.value(at: ["command", "comment"], in: op) ?? MongoChanges.value(at: ["cursor", "originatingCommand", "comment"], in: op)
            let commentText: String? = comment.map { if case .string(let text) = $0 { return text } else { return $0.shellForm(maxLength: 200) } }
            // A mongod's is a number; a mongos's is "shard:number".
            let id: String
            if case .string(let text) = opid { id = text } else { id = opid.integer.map(String.init) ?? opid.shellForm() }
            return Operation(opid: opid, id: id, op: string(op, "op") ?? "", namespace: string(op, "ns") ?? "",
                             microseconds: number(op, "microsecs_running").map(Int64.init), client: client,
                             description: commentText ?? string(op, "desc") ?? "", plan: string(op, "planSummary") ?? "",
                             isInternal: client == nil || system)
        }
    }

    // MARK: Disk Usage

    /// A database's row of Disk Usage from dbStats with freeStorage: its documents' space on disk (without the free
    /// space kept for reuse), its indexes', the free space, its documents; and its data's size uncompressed.
    public static func database(_ name: String, _ stats: BSONDocument) -> (row: DiskUsageRow, uncompressed: Int?) {
        let collections = number(stats, "collections").map(Int.init) ?? 0
        return (row(name, detail: "\(collections) collection\(collections == 1 ? "" : "s")", storage: number(stats, "storageSize"),
                    free: number(stats, "freeStorageSize"), index: number(stats, "indexSize"), documents: number(stats, "objects")),
                number(stats, "dataSize").map(Int.init))
    }

    /// A collection's row from `$collStats`' storageStats.
    public static func collection(_ name: String, _ stats: BSONDocument) -> (row: DiskUsageRow, uncompressed: Int?) {
        let capped = stats["capped"] == .bool(true)
        let indexes = number(stats, "nindexes").map(Int.init) ?? 0
        return (row(name, detail: (capped ? "Capped, " : "") + "\(indexes) index\(indexes == 1 ? "" : "es")", storage: number(stats, "storageSize"),
                    free: number(stats, "freeStorageSize"), index: number(stats, "totalIndexSize"), documents: number(stats, "count")),
                number(stats, "size").map(Int.init))
    }

    private static func row(_ name: String, detail: String, storage: Double?, free: Double?, index: Double?, documents: Double?) -> DiskUsageRow {
        let used = storage.map { max(0, $0 - (free ?? 0)) }
        return DiskUsageRow(name: name, detail: detail, data: used.map(Int.init), index: index.map(Int.init), free: free.map(Int.init),
                            rows: documents.map(Int.init))
    }

    // MARK: Words

    /// "3 d 4 h", "12 min 5 s", "4.2 s", "350 ms": how long, as briefly as a list's cell wants it.
    public static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds)
        switch seconds {
        case ..<1: return "\(Int(seconds * 1000)) ms"
        case ..<60: return String(format: "%.1f s", seconds)
        case ..<3600: return "\(whole / 60) min \(whole % 60) s"
        case ..<86_400: return "\(whole / 3600) h \(whole % 3600 / 60) min"
        default: return "\(whole / 86_400) d \(whole % 86_400 / 3600) h"
        }
    }

    /// A number at a dotted path (a key may hold spaces, as WiredTiger's do), of any of BSON's number types.
    public static func number(_ document: BSONDocument, _ path: String) -> Double? {
        switch MongoChanges.value(at: path.components(separatedBy: "."), in: document) {
        case .int32(let value)?: return Double(value)
        case .int64(let value)?: return Double(value)
        case .double(let value)?: return value.isFinite ? value : nil
        default: return nil
        }
    }

    public static func string(_ document: BSONDocument, _ path: String) -> String? {
        if case .string(let text)? = MongoChanges.value(at: path.components(separatedBy: "."), in: document) { return text }
        return nil
    }
}
