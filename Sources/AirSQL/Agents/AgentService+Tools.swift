import AirSQLCore
import AppKit

/// A console tab as agents see it. The console (L4) conforms; `read_console` reads it.
@MainActor
protocol AgentConsole: AnyObject {
    /// The editor's text.
    var agentText: String { get }
    /// The database its statements run in.
    var agentDatabase: String? { get }
    /// What the person ran last and how it ended; nil: nothing yet.
    var agentLastRun: AgentConsoleRun? { get }
}

/// A statement run in a console, as `read_console` reports it.
struct AgentConsoleRun {
    var sql: String
    /// nil while it runs.
    var finished: Date?
    var error: String?
    var rows: ResultStore?
    var affectedRows: UInt64?
}

/// Opens console tabs for agents: the console (L4) sets `AgentService.consoles`. A tab it opens holds the SQL, never
/// runs it, and shows that an agent proposed it.
@MainActor
protocol AgentConsoles: AnyObject {
    func open(sql: String, title: String, connection: UUID?) -> Tab?
}

/// The tools that read the app's own state: context, the console, the schema resources.
extension AgentService {
    func context() -> [String: Any] {
        let visible = model.data.connections.filter { $0.agentAccess != .off }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let connections = visible.map { saved -> [String: Any] in
            let target = target(saved)
            var entry: [String: Any] = [
                "connection": saved.displayName, "id": saved.id.uuidString, "colour": saved.colour.rawValue,
                "access": saved.agentAccess.rawValue, "accessTitle": saved.agentAccess.title,
                "sampleRows": saved.agentSampleRows, "readOnly": saved.readOnly, "connected": target.connection != nil,
                "rowCap": target.rowCap, "timeoutSeconds": target.timeout,
            ]
            if let database = target.database { entry["database"] = database }
            if let snapshot = target.schema?.snapshot, let server = snapshot.server {
                entry["flavour"] = server.flavour.rawValue
                entry["version"] = server.versionString
                entry["schemaHash"] = snapshot.hash
            }
            return entry
        }
        var reply: [String: Any] = ["connections": connections,
                                    "hiddenConnections": model.data.connections.count - visible.count,
                                    "consoleTabs": consoleTabs().map { tab, _, saved in
                                        ["tab": tab.id.uuidString, "title": tab.title,
                                         "connection": saved?.displayName ?? NSNull()] as [String: Any]
                                    }]
        if let active = main?.activeConnection, active.agentAccess != .off {
            reply["active"] = ["connection": active.displayName, "id": active.id.uuidString,
                               "database": database(of: active) ?? NSNull()] as [String: Any]
        }
        return reply
    }

    /// The console tabs agents may see: those of connections open to agents, and those without a connection.
    func consoleTabs() -> [(Tab, AgentConsole, SavedConnection?)] {
        (main?.tabs ?? []).compactMap { tab in
            guard let console = tab.content as? AgentConsole else { return nil }
            let saved = model.connection(tab.connectionID)
            if tab.connectionID != nil && (saved?.agentAccess ?? .off) == .off { return nil }
            return (tab, console, saved)
        }
    }

    func openInConsole(_ arguments: [String: Any]) throws -> [String: Any] {
        let sql = arguments["sql"] as? String ?? ""
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AirSQLError(.other, "open_in_console needs sql.")
        }
        let named = arguments["connection"].map { _ in true } ?? false
        let saved = named ? try target(arguments).saved : main?.activeConnection.flatMap { $0.agentAccess == .off ? nil : $0 }
        let title = (arguments["title"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? "From an agent"
        guard let consoles else {
            throw AirSQLError(.other, "This AirSQL build has no console yet, so there is nowhere to put the SQL.")
        }
        guard let tab = consoles.open(sql: sql, title: title, connection: saved?.id) else {
            throw AirSQLError(.other, "AirSQL couldn't open a console tab.")
        }
        return ["tab": tab.id.uuidString, "title": tab.title, "connection": saved?.displayName ?? NSNull()]
    }

    func readConsole(_ arguments: [String: Any]) throws -> [String: Any] {
        let tabs = consoleTabs()
        let wanted = (arguments["tab"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let found = wanted.isEmpty ? tabs.first { $0.0 === main?.selectedTab } ?? tabs.last
            : tabs.first { $0.0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame } ?? tabs.first { $0.0.title == wanted }
        guard let (tab, console, saved) = found else {
            throw AirSQLError(.notFound, wanted.isEmpty ? "No console tab is open." : "No console tab “\(wanted)”: context lists them.")
        }
        var reply: [String: Any] = ["tab": tab.id.uuidString, "title": tab.title, "text": console.agentText,
                                    "connection": saved?.displayName ?? NSNull()]
        if let last = console.agentLastRun {
            var run: [String: Any] = ["sql": last.sql, "state": last.finished == nil ? "running" : last.error == nil ? "done" : "failed"]
            if let error = last.error { run["error"] = error }
            if let affected = last.affectedRows { run["affectedRows"] = Int(affected) }
            if let rows = last.rows {
                run["rowCount"] = rows.rowCount
                run["columns"] = rows.columns.map(\.name)
                // The rows are data: only with read access to the tab's connection.
                if (saved?.agentAccess.rank ?? 0) >= AgentAccess.schemaRead.rank {
                    run["rows"] = AgentFormat.json(rows, count: AgentTarget.defaultRows)
                } else {
                    run["note"] = "Rows hidden: this connection allows agents Schema access only."
                }
            }
            reply["run"] = run
        }
        return reply
    }

    // MARK: Schema resources

    /// `airsql://<name>/schema` for each connected connection agents may read.
    func resources() -> [[String: Any]] {
        model.data.connections.filter { $0.agentAccess != .off }.compactMap { saved in
            let target = target(saved)
            guard target.schema != nil else { return nil }
            return ["uri": Self.uri(saved), "name": saved.displayName + " schema", "mimeType": "text/plain",
                    "description": "The compact schema of \(saved.displayName), as get_schema gives it"]
        }
    }

    static func uri(_ saved: SavedConnection) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return "airsql://" + (saved.displayName.addingPercentEncoding(withAllowedCharacters: allowed) ?? saved.id.uuidString)
            + "/schema"
    }

    func resource(_ uri: String) async throws -> String {
        guard uri.hasPrefix("airsql://"), uri.hasSuffix("/schema"),
              let name = String(uri.dropFirst(9).dropLast(7)).removingPercentEncoding else {
            throw AirSQLError(.notFound, "No resource “\(uri)”: AirSQL's are airsql://<connection>/schema.")
        }
        return try await target(["connection": name]).schemaText()
    }

    // MARK: The activity list's words

    /// What a call asks, in a few words: "run_queries · SELECT COUNT(*) … (+2)".
    func summary(_ tool: String, _ arguments: [String: Any]) -> String {
        func short(_ text: String) -> String {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.count > 50 ? line.prefix(50) + "…" : line
        }
        let connection = (arguments["connection"] as? String).map { " · " + $0 } ?? ""
        switch tool {
        case "run_queries":
            let queries = (arguments["queries"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["sql"] as? String ?? $0 as? String }
            return "run_queries · " + short(queries.first ?? "") + (queries.count > 1 ? " (+\(queries.count - 1))" : "")
        case "describe": return "describe · " + (arguments["objects"] as? [String] ?? []).joined(separator: ", ")
        case "profile": return "profile · " + (arguments["table"] as? String ?? "")
        case "explain": return "explain · " + short(arguments["sql"] as? String ?? "")
        case "open_in_console": return "open_in_console · “\(arguments["title"] as? String ?? "From an agent")”"
        case "read_console": return "read_console" + ((arguments["tab"] as? String).map { " · " + $0 } ?? "")
        case "resources/read": return "schema resource · " + (arguments["uri"] as? String ?? "")
        default: return tool + connection
        }
    }

    /// How a call ended, in a few words.
    static func outcome(_ tool: String, _ reply: [String: Any]) -> String {
        switch tool {
        case "run_queries":
            let results = reply["results"] as? [[String: Any]] ?? []
            let failed = results.filter { $0["ok"] as? Bool == false }.count
            let rows = results.compactMap { $0["rowCount"] as? Int }.reduce(0, +)
            return "\(rows) row\(rows == 1 ? "" : "s")" + (failed > 0 ? ", \(failed) refused or failed" : "")
        case "get_schema":
            return reply["unchanged"] as? Bool == true ? "unchanged" : "\((reply["databases"] as? [Any])?.count ?? 0) databases"
        case "describe": return "\((reply["objects"] as? [Any])?.count ?? 0) objects"
        case "profile": return "\((reply["columns"] as? [Any])?.count ?? 0) columns"
        case "context": return "\((reply["connections"] as? [Any])?.count ?? 0) connections"
        default: return "done"
        }
    }
}
