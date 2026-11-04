import Foundation

/// Compares one table's rows on two sessions (`ReconTableSQL` explains the hashing). It walks the source's key in
/// chunks of `chunkRows` rows; each server sums its chunk up (COUNT and SUM of row hashes). A chunk that differs is
/// split into about ten smaller ones on the keys of the side with more rows there, recursively, down to `leafRows`
/// rows; only those come over the network, first as each row's key and hash, then, for the keys whose hashes differ or
/// that one side lacks, as whole rows, which are compared value by value here.
final class ReconDataCompare {
    /// Rows per chunk: one index range scan of this many rows per side per chunk.
    static let chunkRows = 10_000
    /// A differing chunk is split until it has no more rows than this on either side; then its rows' hashes are read.
    static let leafRows = 1_000
    /// More differing rows than this and the table is reported as having too many differences to list.
    static let maxDifferences = 100_000
    /// Keys looked up per statement when fetching whole rows.
    static let batchKeys = 500

    struct Progress {
        var chunk: Int
        var chunks: Int
        var rowsChecked: Int
        var rowsFetched: Int
    }

    private let source: DBConnection, target: DBConnection
    private let sourceSQL: ReconTableSQL, targetSQL: ReconTableSQL
    private let chunks: Int
    /// The key can be walked in ranges; else the table is one chunk.
    private let rangeable: Bool
    private let progress: (Progress) -> Void

    private var tally = ReconTally()
    private var data: ReconTableData
    private var seen = Set<[[UInt8]]>()
    private var checked = 0, fetched = 0, chunk = 0

    private struct TooMany: Error {}

    /// `estimatedRows` (the source's statistics) only sizes the progress.
    init(source: DBConnection, target: DBConnection, sourceSQL: ReconTableSQL, targetSQL: ReconTableSQL,
         estimatedRows: Int, rangeable: Bool = true, progress: @escaping (Progress) -> Void) {
        self.source = source
        self.target = target
        self.sourceSQL = sourceSQL
        self.targetSQL = targetSQL
        chunks = rangeable ? max(1, (estimatedRows + Self.chunkRows - 1) / Self.chunkRows) : 1
        self.rangeable = rangeable
        self.progress = progress
        data = ReconTableData(outcome: .same)
        data.key = sourceSQL.key.map(\.name)
        data.columns = sourceSQL.columns
    }

    var rowsChecked: Int { checked }
    var rowsFetched: Int { fetched }

    func run() async throws -> ReconTableData {
        do {
            var after: [[UInt8]]?
            repeat {
                let upTo = rangeable ? try await boundary(source, sourceSQL, after: after, upTo: nil, rows: Self.chunkRows)
                    : nil
                let (sourceCount, targetCount) = try await compare(after: after, upTo: upTo)
                data.sourceRows += sourceCount
                data.targetRows += targetCount
                checked += max(sourceCount, targetCount)
                chunk += 1
                progress(Progress(chunk: chunk, chunks: max(chunks, chunk), rowsChecked: checked, rowsFetched: fetched))
                after = upTo
            } while after != nil
            try await resolve(Array(tally.sourceOnly.keys) + Array(tally.targetOnly.keys))
        } catch is TooMany {
            var tooMany = ReconTableData(outcome: .tooManyDifferences)
            tooMany.key = data.key
            tooMany.columns = data.columns
            return tooMany
        }
        // In key order (numbers as numbers), whichever chunk each row turned up in.
        let width = sourceSQL.key.count, kinds = sourceSQL.key.map(\.kind)
        func before(_ a: [[UInt8]?], _ b: [[UInt8]?]) -> Bool {
            for index in 0..<width where a[index] != b[index] {
                let x = a[index] ?? [], y = b[index] ?? []
                if [.integer, .decimal, .float].contains(kinds[index]),
                   let p = Double(String(decoding: x, as: UTF8.self)), let q = Double(String(decoding: y, as: UTF8.self)), p != q {
                    return p < q
                }
                return x.lexicographicallyPrecedes(y)
            }
            return false
        }
        data.missing.sort { before($0.values, $1.values) }
        data.extra.sort { before($0.values, $1.values) }
        data.changed.sort { before($0.source.values, $1.source.values) }
        data.outcome = data.differenceCount == 0 ? .same : .different
        return data
    }

    /// Whole-table checksums only, for a table without a key to match rows on.
    func checksumOnly() async throws -> ReconTableData {
        async let left = checksum(source, sourceSQL, after: nil, upTo: nil)
        async let right = checksum(target, targetSQL, after: nil, upTo: nil)
        let (a, b) = try await (left, right)
        checked += max(a.count, b.count)
        progress(Progress(chunk: 1, chunks: 1, rowsChecked: checked, rowsFetched: fetched))
        var result = ReconTableData(outcome: a == b ? .same : .differentWithoutKey)
        result.columns = data.columns
        result.sourceRows = a.count
        result.targetRows = b.count
        return result
    }

    /// Compares a key range on both sides; returns its row counts.
    private func compare(after: [[UInt8]]?, upTo: [[UInt8]]?) async throws -> (Int, Int) {
        async let left = checksum(source, sourceSQL, after: after, upTo: upTo)
        async let right = checksum(target, targetSQL, after: after, upTo: upTo)
        let (a, b) = try await (left, right)
        if a == b { return (a.count, b.count) }
        let most = max(a.count, b.count)
        if rangeable, most > Self.leafRows {
            let (session, sql) = a.count >= b.count ? (source, sourceSQL) : (target, targetSQL)
            let rows = max(Self.leafRows, most / 10)
            var from = after
            while true {
                let to = try await boundary(session, sql, after: from, upTo: upTo, rows: rows)
                _ = try await compare(after: from, upTo: to ?? upTo)
                guard let to else { break }
                from = to
            }
        } else {
            async let leftRows = ReconQuery.store(source, sourceSQL.rowHashes(after: after, upTo: upTo))
            async let rightRows = ReconQuery.store(target, targetSQL.rowHashes(after: after, upTo: upTo))
            let (s, t) = try await (leftRows, rightRows)
            fetched += s.rowCount + t.rowCount
            let differing = tally.add(source: hashes(s), target: hashes(t))
            if tally.count > Self.maxDifferences { throw TooMany() }
            try await resolve(differing)
        }
        return (a.count, b.count)
    }

    /// Looks the keys up on both sides and sorts them into missing, extra and changed rows.
    private func resolve(_ keys: [[[UInt8]]]) async throws {
        let keys = keys.filter { !seen.contains($0) }
        let width = sourceSQL.key.count
        var start = 0
        while start < keys.count {
            let batch = Array(keys[start..<min(start + Self.batchKeys, keys.count)])
            start += batch.count
            async let left = ReconQuery.store(source, sourceSQL.rows(keys: batch))
            async let right = ReconQuery.store(target, targetSQL.rows(keys: batch))
            let (s, t) = try await (left, right)
            fetched += s.rowCount + t.rowCount
            let sourceRows = Self.rows(s, keyWidth: width), targetRows = Self.rows(t, keyWidth: width)
            for key in batch {
                seen.insert(key)
                switch (sourceRows[key], targetRows[key]) {
                case let (row?, nil): data.missing.append(row)
                case let (nil, row?): data.extra.append(row)
                case let (left?, right?):
                    let columns = data.columns.indices.filter {
                        !ReconTableSQL.same(left.values[$0], right.values[$0], data.columns[$0].kind)
                    }
                    if !columns.isEmpty { data.changed.append(ReconRowChange(source: left, target: right, columns: columns)) }
                case (nil, nil): break // gone since the chunk was read
                }
            }
            if data.differenceCount > Self.maxDifferences { throw TooMany() }
        }
    }

    private func checksum(_ session: DBConnection, _ sql: ReconTableSQL, after: [[UInt8]]?,
                          upTo: [[UInt8]]?) async throws -> Checksum {
        let store = try await ReconQuery.store(session, sql.checksum(after: after, upTo: upTo))
        guard store.rowCount == 1 else { return Checksum(count: 0, sum: "") }
        return Checksum(count: Int(store.string(0, 0) ?? "") ?? 0, sum: store.string(0, 1) ?? "")
    }

    private func boundary(_ session: DBConnection, _ sql: ReconTableSQL, after: [[UInt8]]?, upTo: [[UInt8]]?,
                          rows: Int) async throws -> [[UInt8]]? {
        try Task.checkCancellation()
        let store = try await ReconQuery.store(session, sql.boundary(after: after, upTo: upTo, rows: rows))
        guard store.rowCount == 1 else { return nil }
        return (0..<sql.key.count).map { store.bytes(0, $0) ?? [] }
    }

    private func hashes(_ store: ResultStore) -> [([[UInt8]], UInt64)] {
        let width = sourceSQL.key.count
        return (0..<store.rowCount).map { row in
            ((0..<width).map { store.bytes(row, $0) ?? [] }, UInt64(store.string(row, width) ?? "") ?? 0)
        }
    }

    /// Whole rows by key (the key columns come first).
    static func rows(_ store: ResultStore, keyWidth: Int) -> [[[UInt8]]: ReconRow] {
        var rows: [[[UInt8]]: ReconRow] = [:]
        for row in 0..<store.rowCount {
            let values = (0..<store.columns.count).map { store.bytes(row, $0) }
            rows[values.prefix(keyWidth).map { $0 ?? [] }] = ReconRow(values)
        }
        return rows
    }

    private struct Checksum: Equatable {
        var count: Int
        var sum: String
    }
}

/// Keys and row hashes from the chunks that differed, matched up across chunks: a row two servers place in different
/// chunks (their key collations order differently) still meets its other half.
struct ReconTally {
    /// Keys seen on one side only so far, with their row hashes.
    private(set) var sourceOnly: [[[UInt8]]: UInt64] = [:]
    private(set) var targetOnly: [[[UInt8]]: UInt64] = [:]

    var count: Int { sourceOnly.count + targetOnly.count }

    /// Adds a chunk's keys and hashes from both sides; returns the keys both sides have with different hashes.
    mutating func add(source: [([[UInt8]], UInt64)], target: [([[UInt8]], UInt64)]) -> [[[UInt8]]] {
        var other: [[[UInt8]]: UInt64] = [:]
        for (key, hash) in target { other[key] = hash }
        var differing: [[[UInt8]]] = []
        for (key, hash) in source {
            if let match = other.removeValue(forKey: key) ?? targetOnly.removeValue(forKey: key) {
                if match != hash { differing.append(key) }
            } else {
                sourceOnly[key] = hash
            }
        }
        for (key, hash) in target where other[key] != nil {
            if let match = sourceOnly.removeValue(forKey: key) {
                if match != hash { differing.append(key) }
            } else {
                targetOnly[key] = hash
            }
        }
        return differing
    }
}

/// One statement's first result set, with the statement stopped on the server when the task is cancelled.
enum ReconQuery {
    static func store(_ session: DBConnection, _ sql: String) async throws -> ResultStore {
        try Task.checkCancellation()
        let results = try await withTaskCancellationHandler {
            try await session.query(sql, rowCap: .max)
        } onCancel: {
            Task { _ = try? await session.cancel() }
        }
        try Task.checkCancellation()
        let store = results.first(where: { $0.rows != nil })?.rows ?? ResultStore(columns: [])
        // Past the store's limit the rest is gone, and rows missing here would read as differences.
        if store.capped { throw AirSQLError(.other, "A batch of rows is too large to hold in memory, so the compare stopped.") }
        return store
    }
}
