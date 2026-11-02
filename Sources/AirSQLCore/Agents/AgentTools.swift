import Foundation

/// The MCP tools agents get (plan §2.8): name, description, input and output schemas and annotations. The app answers
/// each of these names (`guide` the bridge answers itself). Every result has `structuredContent` matching its output
/// schema, and the same JSON as text for clients that read only text.
public enum AgentTools {
    /// Names a connection: its name as `context` lists it, or its id.
    private static let connection = string("The connection: its name or id, as context lists it")
    private static let database = string("The database the statements run in (default: the connection's current one)")

    public static let list: [[String: Any]] = [
        tool("context", "Start here: the connections you may use (name, id, access level, MySQL or MariaDB and version, "
             + "current database, schema hash, row cap and timeout), the person's active connection and the open console "
             + "tabs. Connections whose agent access is Off are not listed.",
             [:], output: ["connections": arrayOf("Connections you may use"), "hiddenConnections": integer("How many are Off"),
                           "active": object("The person's active connection and database"),
                           "consoleTabs": arrayOf("Open console tabs")], outputRequired: ["connections"]),
        tool("get_schema", "A connection's schema in one call. compact (default): per database, one line per table or view "
             + "with its columns (type, PK, NULL, default, auto-increment), indexes and foreign keys. ddl: CREATE statements. "
             + "Databases too big for one reply come as names only: ask for them by name. Each database has a hash: pass the "
             + "reply's hash as if_changed_from to get just {unchanged: true} when nothing changed. Needs Schema access.",
             ["connection": connection, "databases": strings("Databases (default: all but the system ones)"),
              "format": choice(["compact", "ddl"], "compact (default) or ddl"),
              "if_changed_from": string("A hash from an earlier get_schema reply")], required: ["connection"],
             output: ["connection": string("The connection"), "hash": string("The hash of what this reply covers"),
                      "unchanged": boolean("Nothing changed since if_changed_from"),
                      "databases": arrayOf("Per database: name, hash, tables, details, text"), "note": string("")],
             outputRequired: ["connection", "hash", "unchanged"]),
        tool("describe", "Tables and views in detail, several in one call: columns, indexes, foreign keys both ways, checks, "
             + "triggers, statistics (rows, size) and the CREATE statement; a few sample rows when the person allows them "
             + "for this connection. Needs Schema access.",
             ["connection": connection, "objects": strings("Tables or views: name, or database.name"),
              "database": string("The database of names without one (default: the current one)")],
             required: ["connection", "objects"],
             output: ["connection": string("The connection"), "objects": arrayOf("One per object found"),
                      "missing": strings("Names not found")], outputRequired: ["connection", "objects"]),
        tool("run_queries", "Runs several read-only statements in one call (SELECT, WITH … SELECT, SHOW, DESCRIBE, EXPLAIN), "
             + "each on its own, in a read-only transaction on AirSQL's read-only agent session, within the connection's row "
             + "cap and timeout. Anything that could change data is refused. format json (default: rows as arrays of text "
             + "or null) or csv. to_file (analytics access): each result goes to a CSV or JSON file in AirSQL's agent export "
             + "folder and the reply has its path. Needs Schema + read access.",
             ["connection": connection, "database": database,
              "queries": ["type": "array", "description": "The statements, one per item",
                          "items": ["type": "object", "required": ["sql"],
                                    "properties": ["sql": string("One statement"),
                                                   "max_rows": integer("At most this many rows (default 200)")]]],
              "format": choice(["json", "csv"], "json (default) or csv"),
              "to_file": boolean("Write each result to a file instead (analytics access)")],
             required: ["connection", "queries"],
             output: ["connection": string("The connection"), "results": arrayOf("One per statement, in order")],
             outputRequired: ["connection", "results"]),
        tool("profile", "Column statistics of a table in one call, computed on the server: row count, and per column NULLs, "
             + "distinct values, min, max, average (numbers) and the most common values. columns: which (default: all, up to "
             + "40); where: a condition to profile only some rows. Needs Schema + read + analytics access.",
             ["connection": connection, "database": database, "table": string("The table or view"),
              "columns": strings("Columns (default: all)"), "where": string("A condition, as after WHERE")],
             required: ["connection", "table"],
             output: ["connection": string("The connection"), "database": string("The database"), "table": string("The table"),
                      "rows": integer("Rows (matching where)"), "columns": arrayOf("Per column statistics")],
             outputRequired: ["connection", "table", "rows", "columns"]),
        tool("explain", "The server's plan for one read-only statement (EXPLAIN, or EXPLAIN FORMAT=JSON with format json). "
             + "The statement itself doesn't run. Needs Schema + read access.",
             ["connection": connection, "database": database, "sql": string("The statement"),
              "format": choice(["traditional", "json"], "traditional (default) or json")], required: ["connection", "sql"],
             output: ["connection": string("The connection"), "columns": strings("Columns of the plan"),
                      "rows": arrayOf("The plan's rows")], outputRequired: ["connection", "columns", "rows"]),
        tool("open_in_console", "Puts SQL into a new console tab for the person to read, edit and run. It never runs it: "
             + "this is how to propose a change. Then read_console shows what they ran and its result.",
             ["sql": string("The SQL"), "title": string("The tab's title"), "connection": connection], required: ["sql"],
             output: ["tab": string("The tab's id"), "title": string("The tab's title"), "connection": string("The connection")],
             outputRequired: ["tab", "title"], readOnly: false),
        tool("read_console", "A console tab: its text, and what the person last ran in it with the result or error (rows "
             + "only with Schema + read access). tab: an id or title from context (default: the active console tab).",
             ["tab": string("The tab's id or title")],
             output: ["tab": string("The tab's id"), "title": string("The tab's title"), "connection": string("The connection"),
                      "text": string("The editor's text"), "run": object("What was run last, with its result or error")],
             outputRequired: ["tab", "title", "text"]),
        tool("guide", "How to use AirSQL as an agent: the tools, access levels, read-only rules and recipes. topic: a section "
             + "(none: the overview and the list). Works even when AirSQL isn't running.",
             ["topic": string("A topic")]),
    ]

    /// The schema resources: `airsql://<connection>/schema`, the compact schema as get_schema gives it.
    public static let schemaTemplate: [String: Any] = [
        "uriTemplate": "airsql://{connection}/schema", "name": "schema", "title": "A connection's schema",
        "description": "The compact schema of a connection agents may read (its name, percent-encoded)",
        "mimeType": "text/plain",
    ]

    // MARK: Schema helpers

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = [],
                             output: [String: Any]? = nil, outputRequired: [String] = [], readOnly: Bool = true) -> [String: Any] {
        var entry: [String: Any] = [
            "name": name, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "idempotentHint": readOnly,
                            "openWorldHint": false],
        ]
        if let output {
            entry["outputSchema"] = ["type": "object", "properties": output, "required": outputRequired] as [String: Any]
        }
        return entry
    }

    private static func string(_ text: String) -> [String: Any] { ["type": "string", "description": text] }
    private static func integer(_ text: String) -> [String: Any] { ["type": "integer", "description": text] }
    private static func boolean(_ text: String) -> [String: Any] { ["type": "boolean", "description": text] }
    private static func object(_ text: String) -> [String: Any] { ["type": "object", "description": text] }
    private static func arrayOf(_ text: String) -> [String: Any] { ["type": "array", "description": text] }
    private static func strings(_ text: String) -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": text]
    }
    private static func choice(_ values: [String], _ text: String) -> [String: Any] {
        ["type": "string", "enum": values, "description": text]
    }
}
