import Foundation

/// The MCP tools agents get (plan §2.8): name, description, input and output schemas and annotations. The app answers
/// each of these names (`guide` the bridge answers itself). Every result has `structuredContent` matching its output
/// schema, and the same JSON as text for clients that read only text.
public enum AgentTools {
    /// Names a connection: its name as `context` lists it, or its id.
    private static let connection = string("The connection: its name or id, as context lists it")
    private static let database = string("The database the statements run in (default: the connection's current one)")

    public static let list: [[String: Any]] = [
        tool("context", "Start here: the connections you may use (name, id, access level, engine (MySQL or MariaDB, or "
             + "MongoDB) and version, current database, schema hash, row cap and timeout), the person's active connection and the open console "
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
        tool("search_columns", "Finds columns by name in every database (or those named), from AirSQL's schema cache: no "
             + "query runs. pattern: part of a column's name, or a whole name with * and ? (case doesn't matter). type: "
             + "only columns of this data type (varchar, json; *text for every text type). Each match: database, table, "
             + "column, type, nullable, primaryKey, kind (view, sequence). Needs Schema access.",
             ["connection": connection, "pattern": string("Part of a column's name, or a name with * and ?"),
              "type": string("A data type, such as varchar or *text"),
              "databases": strings("Databases (default: all but the system ones)")], required: ["connection", "pattern"],
             output: ["connection": string("The connection"), "columns": arrayOf("One per matching column"),
                      "capped": boolean("More columns match than the reply lists"), "note": string("")],
             outputRequired: ["connection", "columns", "capped"]),
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
    ] + mongo + [
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
    ] + ui

    /// The MongoDB tools (`AgentTarget.mongo`): typed reads on a MongoDB connection with Schema + read access. Documents
    /// are Extended JSON text in strings, both ways: they keep their keys' order and their types.
    static let mongo: [[String: Any]] = {
        let database = string("The database (default: the connection's own)")
        let collection = string("The collection or view")
        let filter = string("A query document as Extended JSON text, such as {\"status\": \"A\"} (default: every document)")
        let place: [String: Any] = ["connection": connection, "database": database, "collection": collection]
        let found: [String: Any] = ["connection": string("The connection"), "database": string("The database"),
                                    "collection": string("The collection"),
                                    "documents": strings("The documents, each its relaxed Extended JSON text (keys in "
                                                         + "order, doubles as 1.0)"),
                                    "count": integer("How many documents the reply has"),
                                    "capped": boolean("There may be more than the reply has")]
        let refusals = " $where, $function, $accumulator, $out and $merge are refused anywhere; so are the admin, local and "
            + "config databases and system.* collections. Needs Schema + read access on a MongoDB connection."
        return [
            tool("mongo_find", "Finds documents in a MongoDB collection, read-only, within the connection's row cap and "
                 + "timeout: 200 documents unless limit says more (up to the row cap)." + refusals,
                 place.merging(["filter": filter, "projection": string("Fields to return, as Extended JSON text"),
                                "sort": string("The order, as Extended JSON text: {\"a\": 1, \"b\": -1}"),
                                "skip": integer("Documents to skip"), "limit": integer("At most this many (default 200)"),
                                "collation": string("A collation document, as Extended JSON text"),
                                "hint": string("An index's name, or its key pattern as Extended JSON text")]) { $1 },
                 required: ["connection", "collection"], output: found, outputRequired: ["connection", "documents", "capped"]),
            tool("mongo_aggregate", "Runs a read-only aggregation pipeline on a MongoDB collection. Stages on an allow-list "
                 + "only ($match, $project, $group, $sort, $lookup and $unionWith in the same database, $facet, …); the row "
                 + "cap is added as a last $limit." + refusals,
                 place.merging(["pipeline": string("The stages: Extended JSON text of an array, such as "
                                                   + "[{\"$match\": {}}, {\"$group\": {\"_id\": \"$k\", \"n\": {\"$sum\": 1}}}]"),
                                "max_documents": integer("At most this many (default 200)"),
                                "collation": string("A collation document, as Extended JSON text"),
                                "hint": string("An index's name, or its key pattern as Extended JSON text")]) { $1 },
                 required: ["connection", "collection", "pipeline"], output: found,
                 outputRequired: ["connection", "documents", "capped"]),
            tool("mongo_count", "Counts the documents of a MongoDB collection that match a filter." + refusals,
                 place.merging(["filter": filter]) { $1 }, required: ["connection", "collection"],
                 output: ["connection": string("The connection"), "count": integer("Matching documents")],
                 outputRequired: ["connection", "count"]),
            tool("mongo_distinct", "The distinct values of a field (a dotted path) among a MongoDB collection's documents "
                 + "that match a filter, up to the row cap." + refusals,
                 place.merging(["key": string("The field, such as address.city"), "filter": filter]) { $1 },
                 required: ["connection", "collection", "key"],
                 output: ["connection": string("The connection"), "values": arrayOf("The values, as relaxed Extended JSON"),
                          "capped": boolean("There were more than the row cap")],
                 outputRequired: ["connection", "values", "capped"]),
            tool("mongo_list_databases", "The databases of a MongoDB connection with their sizes, without MongoDB's own "
                 + "(admin, local, config). Needs Schema + read access.",
                 ["connection": connection], required: ["connection"],
                 output: ["connection": string("The connection"), "databases": arrayOf("name, sizeOnDisk, empty")],
                 outputRequired: ["connection", "databases"]),
            tool("mongo_list_collections", "The collections, views and time series of a MongoDB database, with their "
                 + "options (a view's pipeline, a validator), without system.* ones. Needs Schema + read access.",
                 ["connection": connection, "database": database], required: ["connection"],
                 output: ["connection": string("The connection"), "collections": arrayOf("name, type, options")],
                 outputRequired: ["connection", "collections"]),
            tool("mongo_list_indexes", "A MongoDB collection's indexes as the server describes them (key, name, unique, "
                 + "partialFilterExpression, …). Needs Schema + read access.",
                 place, required: ["connection", "collection"],
                 output: ["connection": string("The connection"),
                          "indexes": strings("One per index: its relaxed Extended JSON text, keys in order")],
                 outputRequired: ["connection", "indexes"]),
            tool("mongo_stats", "Sizes and counts: a collection's storage stats, or the database's (dbStats) without a "
                 + "collection. Needs Schema + read access.",
                 ["connection": connection, "database": database, "collection": string("The collection (default: the database's)")],
                 required: ["connection"], output: ["connection": string("The connection"), "stats": object("The figures")],
                 outputRequired: ["connection", "stats"]),
            tool("mongo_schema_sample", "What a random sample ($sample) of a MongoDB collection's documents holds, per "
                 + "dotted path (items of arrays under path.[]): how often present, missing and null, the types and their "
                 + "counts, distinct values, the most common values and the range of numbers and dates. size: how many "
                 + "documents (default 200, up to the row cap). Needs Schema + read access.",
                 place.merging(["size": integer("Documents to sample (default 200)")]) { $1 },
                 required: ["connection", "collection"],
                 output: ["connection": string("The connection"), "documents": integer("Documents sampled"),
                          "fields": arrayOf("Per path: path, present, missing, nulls, types, distinct, top, min, max")],
                 outputRequired: ["connection", "documents", "fields"]),
        ]
    }()

    /// Driving AirSQL's windows as the person does (plan §2.8). Whatever would change data, structure, files or settings
    /// waits for the person at the Mac, or is theirs alone. Replies are JSON as text (screenshot: a PNG), isError on
    /// failure; no output schema.
    static let ui: [[String: Any]] = {
        let within = string("Where: \"sheet\", \"popover\" or \"window:<title>\" (default: the frontmost sheet, then the windows)")
        let point: [String: Any] = ["x": number("Points from the left of the main window (or of in), as a screenshot at scale 1"),
                                    "y": number("Points from the top"), "in": within,
                                    "modifiers": string("\"cmd\", \"shift\", \"option\", \"control\", joined by +")]
        return [
            tool("snapshot", "What AirSQL's windows show now: the windows, sidebar, tabs, status bar, activity and open sheets "
                 + "(buttons with why a disabled one is off). include adds menus (every menu-bar command, enabled or why not), "
                 + "elements (the accessibility tree: id, role, title, value, frame) and settings. Data of connections whose "
                 + "agent access doesn't include reading is left out.",
                 ["include": ["type": "array", "items": ["type": "string", "enum": ["sidebar", "tabs", "status", "activity",
                                                                                 "sheets", "menus", "elements", "settings"]],
                              "description": "Sections (default: sidebar, tabs, status, activity, sheets)"], "in": within]),
            tool("screenshot", "A PNG of a window as the person sees it, drawn by AirSQL (no screen recording). Grids and "
                 + "results of connections whose agent access doesn't include reading are covered.",
                 ["target": string("main (default), sheet, window:<title> or element:<id>"),
                  "scale": number("1 (default, points) or 2 (pixels)")]),
            tool("menu", "Chooses a menu-bar command by its path, as validated now: a disabled one says why. "
                 + "\"context > <item>\" chooses from the menu the last right-click opened.",
                 ["path": string("For example \"Query > Run Statement\" or \"context > Copy\""), "in": within],
                 required: ["path"], readOnly: false),
            tool("press", "Presses a button, checkbox, segment or link by its accessibility id (snapshot elements) or title.",
                 ["id": string("Accessibility id"), "title": string("Title"), "in": within], readOnly: false),
            tool("set", "Sets a field: text, a checkbox (true or false), a pop-up or segment (the option's title), the "
                 + "console's editor. By id, title, placeholder or \"password\".",
                 ["id": string("Accessibility id"), "title": string("Label, title or placeholder"),
                  "value": ["description": "The text, true or false, or the option's title"], "in": within],
                 required: ["value"], readOnly: false),
            tool("select", "Selects by name as a click does: connections in the sidebar (pane sidebar), a tab (pane tabs), "
                 + "or the rows of a list in a sheet or window that show these names.",
                 ["pane": choice(["sidebar", "tabs"], "sidebar or tabs (default: a list in the frontmost sheet or window)"),
                  "names": strings("Names, as shown"), "none": boolean("Select nothing"), "in": within], readOnly: false),
            tool("key", "Presses a key combination in the frontmost sheet or the key window, as the keyboard does: menu "
                 + "shortcuts, Return for the default button, Escape, arrows. For example \"cmd+return\" or \"escape\".",
                 ["combo": string("For example cmd+shift+n, return, escape, down, f5, a"), "in": within],
                 required: ["combo"], readOnly: false),
            tool("type", "Types text where the cursor is (the focused field or the console's editor).",
                 ["text": string("The text"), "in": within], required: ["text"], readOnly: false),
            tool("click", "Clicks at a point: lists select rows, buttons press, a right-click (button right) answers with the "
                 + "menu it opens. count 2 double-clicks.",
                 point.merging(["count": integer("1 (default), 2 or 3"),
                                "button": choice(["left", "right"], "left (default) or right")]) { $1 },
                 required: ["x", "y"], readOnly: false),
            tool("double_click", "Double-clicks at a point: opens or edits what it is on (a connection, a table, a cell).",
                 point, required: ["x", "y"], readOnly: false),
            tool("right_click", "Right-clicks at a point and answers with the menu it opens; choose from it with menu "
                 + "\"context > <item>\".", point, required: ["x", "y"], readOnly: false),
            tool("wait", "Waits until a sheet is open (with text in it), no sheet is, a popover is shown, nothing runs "
                 + "(idle), or text shows anywhere; at most timeout seconds (default 30).",
                 ["until": choice(["sheet", "no_sheet", "popover", "idle", "text"], "What to wait for"),
                  "text": string("Text to find"), "timeout": number("Seconds (default 30, at most 600)")],
                 required: ["until"]),
        ]
    }()

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
    private static func number(_ text: String) -> [String: Any] { ["type": "number", "description": text] }
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
