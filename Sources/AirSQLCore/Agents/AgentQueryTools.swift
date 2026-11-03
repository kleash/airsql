import Darwin
import Foundation

/// run_queries and explain: agents' own SQL, read-only (`AgentReadOnly`).
extension AgentTarget {
    /// Rows a statement returns when the call doesn't say.
    public static let defaultRows = 200

    /// Where agents' exports go: inside AirSQL's folder, so macOS asks nothing (R18). Shown in Settings ▸ Agents.
    public static var exportFolder: URL { Store.directory.appendingPathComponent("Agent Exports", isDirectory: true) }

    public func runQueries(_ arguments: [String: Any], exports: URL = exportFolder,
                           progress: @escaping AgentProgress = { _, _, _ in }) async throws -> [String: Any] {
        try require(.schemaRead)
        let queries = (arguments["queries"] as? [Any] ?? []).compactMap { item -> (sql: String, rows: Int?)? in
            if let sql = item as? String { return (sql, nil) }
            guard let object = item as? [String: Any], let sql = object["sql"] as? String else { return nil }
            return (sql, (object["max_rows"] as? NSNumber)?.intValue)
        }
        guard !queries.isEmpty else { throw AirSQLError(.other, "run_queries needs queries: [{sql}].") }
        let csv = arguments["format"] as? String == "csv"
        let toFile = arguments["to_file"] as? Bool == true
        if toFile { try require(.schemaReadAnalytics) }
        let database = (arguments["database"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? self.database
        var results: [[String: Any]] = []
        try await AgentReadOnly.session(try await session(), timeout: timeout) { runner in
            if let database { _ = try await runner.run("USE " + SQLQuote.identifier(database), written: false) }
            for (index, query) in queries.enumerated() {
                if queries.count > 1 {
                    progress(Double(index), Double(queries.count), "Statement \(index + 1) of \(queries.count)")
                }
                var entry: [String: Any] = ["sql": query.sql]
                do {
                    if toFile {
                        entry.merge(try await export(query.sql, runner, csv: csv, folder: exports, index: index)) { $1 }
                    } else {
                        let cap = min(max(1, query.rows ?? Self.defaultRows), rowCap)
                        entry.merge(Self.result(try await runner.run(query.sql, written: true, rowCap: cap), csv: csv)) { $1 }
                    }
                    entry["ok"] = true
                } catch {
                    entry["ok"] = false
                    entry["error"] = AgentReply.message(error)
                }
                results.append(entry)
            }
        }
        return ["connection": saved.displayName, "database": database ?? NSNull(), "results": results]
    }

    /// A statement's result for a reply: its rows as JSON arrays or CSV, or what it did.
    static func result(_ result: StatementResult?, csv: Bool) -> [String: Any] {
        guard let result else { return [:] }
        var entry: [String: Any] = ["durationMs": Int(result.duration * 1000), "warnings": result.warnings]
        guard let rows = result.rows else {
            entry["affectedRows"] = Int(result.affectedRows)
            if let info = result.info { entry["info"] = info }
            return entry
        }
        let columns = AgentFormat.columns(rows)
        entry["columns"] = columns.names
        entry["types"] = columns.types
        entry["rowCount"] = rows.rowCount
        entry["capped"] = rows.capped
        if csv { entry["csv"] = AgentFormat.csv(rows) } else { entry["rows"] = AgentFormat.json(rows) }
        return entry
    }

    /// Streams a statement's rows into a new CSV or JSON file in `folder`, up to the row cap; its path, rows and size.
    private func export(_ sql: String, _ runner: AgentReadOnly.Runner, csv: Bool, folder: URL,
                        index: Int) async throws -> [String: Any] {
        let (url, handle) = try Self.newFile(in: folder, name: saved.displayName, index: index, csv: csv)
        defer { try? handle.close() }
        final class State: @unchecked Sendable { var rows = 0, capped = false, columns: [String]? }
        struct Full: Error {}
        let state = State(), cap = rowCap
        func start(_ columns: [String]) throws {
            state.columns = columns
            let head = csv ? columns.map(AgentFormat.csvField).joined(separator: ",") + "\r\n"
                : "{\"columns\":" + AgentJSON.text(columns) + ",\"rows\":["
            try handle.write(contentsOf: Data(head.utf8))
        }
        do {
            _ = try await runner.run(sql, written: true, batch: { store in
                if state.columns == nil { try start(AgentFormat.columns(store).names) }
                let take = min(store.rowCount, cap - state.rows)
                let body = csv ? AgentFormat.csv(store, count: take, header: false, limit: nil)
                    : AgentFormat.json(store, count: take, limit: nil).enumerated()
                    .map { (state.rows + $0.offset == 0 ? "\n" : ",\n") + AgentJSON.text($0.element) }.joined()
                try handle.write(contentsOf: Data(body.utf8))
                state.rows += take
                if take < store.rowCount {
                    state.capped = true
                    throw Full()
                }
            })
        } catch is Full {
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)  // no half-written files
            throw error
        }
        if state.columns == nil { try start([]) }
        if !csv { try handle.write(contentsOf: Data("\n]}\n".utf8)) }
        let size = (try? handle.offset()) ?? 0
        return ["file": url.path, "rowCount": state.rows, "capped": state.capped, "columns": state.columns ?? [],
                "bytes": Int(size)]
    }

    /// A new file only this user can read, named after the connection, the time and the statement.
    static func newFile(in folder: URL, name: String, index: Int, csv: Bool) throws -> (URL, FileHandle) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let stem = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.prefix(40))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let base = "\(stem)-\(formatter.string(from: Date()))-\(index + 1)"
        for attempt in 0..<100 {
            let url = folder.appendingPathComponent(base + (attempt == 0 ? "" : "-\(attempt)") + (csv ? ".csv" : ".json"))
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 { return (url, FileHandle(fileDescriptor: fd, closeOnDealloc: true)) }
            guard errno == EEXIST else { break }
        }
        throw AirSQLError(.other, "Can't create a file in the agent export folder: \(String(cString: strerror(errno)))")
    }
}
