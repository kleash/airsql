import Foundation

extension Recon {
    /// Compares two servers: pairs every database by name (the system ones left out) and runs the database compare on
    /// each pair in turn, through the same two sessions. A pair that can't be read is reported and the others go on.
    /// Each side's `database` is empty; the result's objects are the pairs.
    public static func runServer(source: ReconSide, target: ReconSide, options: ReconOptions,
                                 progress: @escaping (ReconProgress) -> Void = { _ in }) async throws -> ReconResult {
        let started = Date()
        progress(ReconProgress(step: "Listing the databases"))
        async let left = server(source)
        async let right = server(target)
        let (ours, theirs) = try await (left, right)
        var result = ReconResult(
            source: ReconEnd(name: source.name, database: "", version: ours.version,
                             noBackslashEscapes: source.session.noBackslashEscapes),
            target: ReconEnd(name: target.name, database: "", version: theirs.version,
                             noBackslashEscapes: target.session.noBackslashEscapes),
            options: options)
        let pairs = paired(ours.databases, theirs.databases, caseless: ours.caseless || theirs.caseless)
        var each = options
        each.tables = [:]  // chosen for one database's tables
        each.only = nil
        for (done, pair) in pairs.enumerated() {
            guard let name = pair.source, let other = pair.target else {
                let status: ReconObject.Status = pair.source != nil ? .onlyInSource : .onlyInTarget
                result.objects.append(ReconObject(kind: .database, name: pair.source ?? pair.target ?? "", status: status))
                continue
            }
            var object = ReconObject(kind: .database, name: name, targetName: other, status: .same)
            let (checked, fetched) = (result.rowsChecked, result.rowsFetched)
            do {
                var sides = (source, target)
                sides.0.database = name
                sides.1.database = other
                let found = try await run(source: sides.0, target: sides.1, options: each) { inner in
                    var step = ReconProgress(step: "\(done + 1) of \(pairs.count) · \(name) · \(inner.step)")
                    step.chunk = Int(inner.fraction * 100)
                    step.chunks = 100
                    step.tablesDone = done
                    step.tables = pairs.count
                    step.rowsChecked = checked + inner.rowsChecked
                    step.rowsFetched = fetched + inner.rowsFetched
                    progress(step)
                }
                object.status = found.objects.contains(where: \.differs) ? .different : .same
                result.databases[name] = found
                result.rowsChecked += found.rowsChecked
                result.rowsFetched += found.rowsFetched
            } catch let error where !stops(error) {
                object.status = .different
                object.parts = [ReconPart(kind: .options, name: "error", change: .changed, detail: error.localizedDescription)]
            }
            result.objects.append(object)
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    /// Databases paired by name, source's first, then those only the target has.
    static func paired(_ left: [String], _ right: [String], caseless: Bool) -> [(source: String?, target: String?)] {
        func same(_ a: String, _ b: String) -> Bool { caseless ? a.caseInsensitiveCompare(b) == .orderedSame : a == b }
        var rest = right
        var pairs: [(source: String?, target: String?)] = left.map { name in
            guard let match = rest.firstIndex(where: { same($0, name) }) else { return (name, nil) }
            return (name, rest.remove(at: match))
        }
        pairs += rest.map { (nil, $0) }
        return pairs
    }

    /// The person stopped, or the session is gone: no use going on to the next pair.
    private static func stops(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return [.cancelled, .disconnected].contains((error as? AirSQLError)?.kind)
    }

    private static func server(_ side: ReconSide) async throws -> (version: String, caseless: Bool, databases: [String]) {
        let info = try await ReconQuery.store(side.session, "SELECT VERSION(), @@lower_case_table_names")
        let list = try await ReconQuery.store(side.session, "SHOW DATABASES")
        let names = (0..<list.rowCount).compactMap { list.string($0, 0) }
            .filter { !AgentFormat.systemDatabases.contains($0.lowercased()) }
        return (info.string(0, 0) ?? "", info.string(0, 1) != "0", names)
    }
}

extension ReconResult {
    /// A server compare with one pair's newer result (the pair was opened and compared again).
    public mutating func update(pair name: String, with found: ReconResult) {
        guard let index = objects.firstIndex(where: { $0.kind == .database && $0.name == name }) else { return }
        databases[name] = found
        objects[index].parts = []
        objects[index].status = found.objects.contains(where: \.differs) ? .different : .same
    }
}
