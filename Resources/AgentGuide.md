# AirSQL agent guide

AirSQL is a Mac app for MySQL and MariaDB, and MongoDB. Through its MCP server you can read the schemas of the
connections the person at the Mac allows, run read-only queries (on MongoDB: finds, aggregations and counts; see
mongodb), profile tables, propose SQL in a console tab for the person to edit
and run, and drive AirSQL's windows as they do. You never see passwords, and you can't change data, connections or
settings on your own: whatever would change something waits for the person at the Mac (see gate), and each
connection's access level is their choice alone.

## overview

1. `context` first: the connections you may use (name, id, access level, `engine` (`mysql` or `mongodb`) and the
   server's version, current database, schema hash, row cap and timeout), the person's active connection and the open console tabs. A connection
   whose access is Off isn't listed; `hiddenConnections` counts them.
2. `get_schema` once per connection: every database's tables in one compact reply. Keep its `hash` and pass it back as
   `if_changed_from` later: an unchanged schema answers `{unchanged: true}` and costs nothing.
3. `describe` the tables you'll query (columns, keys both ways, indexes, CREATE statement, row estimates).
   `search_columns` finds a column by name (`email`, `*_id`) in every database without reading the whole schema.
4. `run_queries` with several statements at once; `explain` a slow one; `profile` a table you don't know yet.
5. To change anything, write the SQL and call `open_in_console`: the person reads it, edits it, runs it. Then
   `read_console` shows what they ran and the result or error.
6. To work in AirSQL's windows (open a table, use a menu, fill a sheet), `snapshot` first, then `menu`, `press`, `set`,
   `type`, `key` and the clicks, and `wait` for what they start (see ui and screens).

Connections must be connected in AirSQL (by the person) before the database tools work on them. After a relaunch, tabs
other than consoles are placeholders: they hold names only, and they connect nothing until their button is pressed.

## access

Each connection has one level, set by the person in Settings ▸ Agents (or the connection's Agents tab):

- **Off** (the default; Production connections start here): invisible to agents.
- **Schema**: `get_schema`, `describe`, `search_columns`, the schema resource, `open_in_console`; `read_console` without
  result rows.
- **Schema + read**: also `run_queries` and `explain`, within the connection's row cap and timeout (Settings ▸ Safety:
  10,000 rows and 30 s by default, 1,000 and 15 s on Production).
- **Schema + read + analytics**: also `profile`, `to_file`, ten times the rows and four times the timeout.

On a MongoDB connection every `mongo_` tool needs Schema + read; with analytics, ten times the documents and four
times the timeout. Sample rows are a separate switch: when on, `describe` shows a few rows of each table. A call beyond
the level is refused with the level it needs. Ask the person to change a level; you can't.

## read-only

Statements you write run only when AirSQL's classifier proves them read-only: one statement, `SELECT`,
`WITH … SELECT`, `SHOW`, `DESCRIBE` or `EXPLAIN` (not `EXPLAIN ANALYZE`). It refuses `INTO`, `FOR UPDATE`,
`LOCK IN SHARE MODE`, optimizer hints, temporary tables, and functions such as `SLEEP`, `BENCHMARK`, `GET_LOCK`,
`LOAD_FILE` and stored functions. Each statement then runs on AirSQL's own agent session, which is read-only, inside
`START TRANSACTION READ ONLY` … `ROLLBACK`, with the server's statement timeout and a watchdog. Both guards always apply.
A refused statement comes back with `ok: false` and the reason; the other statements of the call still run.
The person sees each statement you ran and the rows you got in the connection's Agent tab (View ▸ Agent Results).

## tools

- `context {}`: start here.
- `get_schema {connection, databases?, format?: compact | ddl, if_changed_from?}`: compact lines look like
  `orders: id bigint PK AI, customer_id int NULL → customers.id, total decimal(12,2) ='0.00'; KEY(customer_id)`:
  PK primary key, AI auto-increment, NULL nullable, `=` default, `→` foreign key, then composite keys and indexes, and
  `-- comment`. Views start with `view`, sequences with `sequence`. System databases are left out unless named. A
  database too big for the reply comes as names only: name it, or describe its tables.
- `describe {connection, objects: ["table" or "db.table"], database?}`: names in backquotes may contain dots.
- `search_columns {connection, pattern, type?, databases?}`: from AirSQL's schema cache, so no query runs. `pattern` is
  part of a column's name, or a whole name with `*` and `?`; `type` a data type (`varchar`, `json`, `*text`); neither
  minds case. Each match has `database`, `table`, `column`, `type` (as `varchar(255)`), `nullable`, and `primaryKey`
  and `kind` (`view`, `sequence`) when they apply. At most 500 (`capped: true` means more matched). Databases whose
  columns aren't loaded yet (a very big server) are searched once you name them.
- `run_queries {connection, database?, queries: [{sql, max_rows?}], format?: json | csv, to_file?}`: 200 rows per
  statement unless `max_rows` says more (up to the row cap); `capped: true` means there were more. `types` names each
  column's type as AirSQL's grid does (`bigint unsigned`, `varchar`, `datetime`). Values are text (binary as 0x…
  hex), NULL is null in JSON and an empty field in CSV, long values are cut at 2,000 characters.
  `to_file: true` (analytics) writes each result to a CSV or JSON file in AirSQL's agent export folder and answers with
  its path, rows and size instead of the rows.
- `profile {connection, table, database?, columns?, where?}`: row count, and per column NULLs, distinct values, min,
  max, average (numbers) and the five most common values, computed on the server.
- `explain {connection, sql, database?, format?: traditional | json}`.
- `open_in_console {sql, title?, connection?}`: never runs anything.
- `read_console {tab?}`: by id or title from `context`, in any main window; default the active console tab. A person's
  Ask an Agent request names a tab by id, and lines to look at.
- `guide {topic?}`: this guide.

- The `mongo_` tools, for MongoDB connections: see mongodb.

Long calls send progress notifications when your client asks for them (`_meta.progressToken`).

## mongodb

A connection whose `engine` is `mongodb` has its own tools; the SQL ones (`get_schema`, `describe`, `search_columns`,
`run_queries`, `profile`, `explain`, the schema resource) refuse it, and the `mongo_` tools refuse a MySQL one. Each
needs Schema + read (`mongo_schema`: Schema), and the connection connected in AirSQL. `database` defaults to the connection's own.

Documents you send (`filter`, `projection`, `sort`, `collation`, a `hint` pattern, `pipeline`) are Extended JSON
text, as strings: `"{\"status\": \"A\", \"total\": {\"$gt\": 10}}"`, with `$oid`, `$date`, `$numberLong`,
`$numberDecimal` for the types JSON lacks. A string keeps the keys' order (a sort on two fields); an object is refused.
Documents you get back (`mongo_find`, `mongo_aggregate`, `mongo_list_indexes`, `mongo_stats`) are strings too, each
one document's relaxed Extended JSON text, so their keys keep their order and a double keeps its `.0`
(`{"b": 1, "a": 2.0}`): parse each one; so is each of `mongo_distinct`'s values (`2.0`, `"Paris"`). Numbers are plain, other types `{"$oid": …}`, `{"$date": "2024-…Z"}`, `{"$numberDecimal": "…"}`; strings
longer than 2,000 characters are cut.

- `mongo_find {connection, database?, collection, filter?, projection?, sort?, skip?, limit?, collation?, hint?}`:
  200 documents unless `limit` says more (0: the row cap), at most the row cap and 1 MB of documents; `capped: true`
  means there may be more.
- `mongo_aggregate {connection, database?, collection, pipeline, max_documents?, collation?, hint?}`: the same caps;
  the row cap is added as the last stage, `{$limit: …}`.
- `mongo_count {connection, database?, collection, filter?}`: `count`.
- `mongo_distinct {connection, database?, collection, key, filter?}`: `values`, at most the row cap (`capped`).
- `mongo_list_databases {connection}`: name, sizeOnDisk, empty; never admin, local or config.
- `mongo_list_collections {connection, database?}`: name, type (`collection`, `view`, `timeseries`) and options (a
  view's `viewOn` and pipeline, a validator); never `system.*`.
- `mongo_list_indexes {connection, database?, collection}`: each index as the server describes it, as text.
- `mongo_stats {connection, database?, collection?}`: a collection's storage stats (count, size, avgObjSize,
  storageSize, totalIndexSize, indexSizes), or the database's dbStats without a collection.
- `mongo_schema_sample {connection, database?, collection, size?}`: `$sample` of `size` documents (200, at most the
  row cap), then per dotted path (array items under `path.[]`): `present`, `missing`, `nulls`, `types` with counts,
  `distinct`, the five most common values (`top`, in shell form) and `min`/`max` of numbers or dates. Start here on an
  unknown collection.

Every call is checked before anything is sent, and refused (`Refused: <where>: <why>`) for: `$where`, `$function`,
`$accumulator`, `$out` or `$merge` anywhere in any argument, or JavaScript code (`{"$code": …}`); a stage not on the
allow-list (`$match`, `$project`, `$addFields`, `$set`, `$unset`, `$group`, `$sort`, `$limit`, `$skip`, `$count`,
`$unwind`, `$sortByCount`, `$bucket`, `$bucketAuto`, `$replaceRoot`, `$replaceWith`, `$sample`, `$redact`,
`$densify`, `$fill`, `$setWindowFields`, `$geoNear`, `$documents`, `$collStats`, `$indexStats`, `$lookup`,
`$graphLookup`, `$unionWith`, `$facet`), so not `$currentOp`, `$changeStream` or `$search`; `$lookup`,
`$graphLookup` and `$unionWith` of another database (name the collection plainly); the admin, local and config
databases and `system.*` collections; a negative skip or limit. Every command carries `maxTimeMS` (the timeout), and
a watchdog stops one that runs on. On a replica set or a mongos the reads run inside a transaction that is always
aborted, so even a write that got past the check is refused by the server; there, `$collStats` and `$indexStats`
stages fail (use `mongo_stats`). To change data, describe the change to the person: there is no tool that writes.

`mongo_find` and `mongo_aggregate` take `to_file: true` (Schema + read + analytics): the documents, up to the row
cap, go to a new file in AirSQL's agent export folder, one relaxed Extended JSON document a line (`.jsonl`, nothing
cut), and the reply has `file`, `count`, `capped` and `bytes` instead of the documents. There is no path argument.

A server's error on `mongo_find`, `mongo_aggregate` or `mongo_explain` is JSON text: `{code, codeName, message,
stage?, hint?}`, where `stage` is the pipeline stage that holds the unknown word and `hint` the nearest operator or
stage (`Did you mean $sum?`) or the version a newer one needs (`$median needs MongoDB 7.0`). A refused stage that
MongoDB doesn't have gets the nearest one too. A reply that is likely wrong has `warnings`, from the collection's
sample: a path of the filter, sort or projection (an aggregate's leading `$match` and `$sort`) that is not in the
sample (`customerID is not in the sample of 200 documents; nearest: customerId`), a literal of a type the field never
has there (`createdAt is date in the sample …: compare with {"$date": …}`), and `Nothing matched` after them when
nothing did. A sample shows what it holds, not all there is: check before you conclude.

### mongo_schema

`mongo_schema {connection, database?, collections?, sample?, if_changed_from?}` → `{hash, unchanged, text, capped}`:
start here on a MongoDB database. The whole database in one text within 24 KB, from a sample of each collection (200
documents, kept by AirSQL until refreshed): per collection its count, average size, indexes (`unique`, `partial`)
and validator; per path (the 60 most often present, 4 deep; arrays' items under `path.[]`) its types (with shares
when mixed) and its share when under 100%, and with Schema + read the enums (strings of up to 12 values, with
shares) and the ranges of numbers and dates; views with their pipeline; and references:
`customerId objectId -> customers._id (49/50)` means a path named `<name>Id` (or ending in another collection's
unique-indexed field, `productSku -> products.sku`) of the same type, whose sampled values (up to 50) were looked up
there with one `$in`: kept when 80% or more were found, with the count, so orphans show as a lower ratio. Needs
Schema access (no enums or ranges at Schema alone). `collections` limits it; `sample: false` reads no documents and
lists only collections already sampled. Collections not sampled within the timeout say so and `capped` is true (ask
again: the samples go on and are kept); so is a text that had to leave paths or collections out. Pass `hash` as
`if_changed_from` to get `{hash, unchanged: true}`.

### mongo_explain

`mongo_explain {connection, database?, collection, filter?, projection?, sort?, limit? | pipeline, hint?,
verbosity?}` → `{scan, index, docsExamined, returned, ms, warnings, plan}`. `verbosity: "plan"` (the default) asks
the query planner only and runs nothing: use it to check a query before running it. `"run"` runs it
(executionStats) for `docsExamined`, `returned` (what the query stage returned; a `$group` after it returns fewer)
and `ms`. `scan` is `collection`, `index` or `none`; `index` the indexes it reads; `plan` the winning plan as an
indented tree; `warnings` a whole-collection read, an in-memory sort, and the sample's warnings above. Checked,
refused and capped as `mongo_find` and `mongo_aggregate` are; Schema + read.

### mongo_open

Not in this build yet: describe the query to the person instead.

## resources

Each connected connection you may read has its compact schema as a resource, `airsql://<connection name>/schema`
(percent-encoded), the same text as `get_schema`. `resources/list` lists them.

## recipes

- **Answer a question about the data**: `context` → `get_schema` → `describe` the tables involved → `run_queries`
  with a `COUNT(*)` first, then the query, with `max_rows` small.
- **Analyse a big result**: with analytics, `run_queries` with `to_file: true`, then read the file with your own tools.
- **Change data or structure**: write the statements, then `open_in_console` with a clear title; tell the person what
  they do. After they run them, `read_console`.
- **Find where something is kept**: `search_columns` with part of its name (`email`, `*_at` with type `datetime`),
  then `describe` the tables it found.
- **Check a query's cost**: `explain` it, look for full scans (`type: ALL`) on big tables, `describe` for indexes.

## ui

The UI tools act in AirSQL's windows as the person would, on the main window in front when there are several; replies are JSON as text (`screenshot`: a PNG), `isError` on
failure, and every reply after an action carries the sheet it opened, if any.

- `snapshot {include?, in?}`: windows, sidebar, tabs, status bar, activity and open sheets by default; `menus` lists
  every menu-bar command with its shortcut and, when off, why; `elements` the accessibility tree (id, role, title,
  value, frame in points from the window's top left); `settings` the saved settings.
- `screenshot {target?: main | sheet | window:<title> | element:<id>, scale?: 1 | 2}`: drawn by AirSQL itself.
- `menu {path}`: "Query > Run Statement"; after a right-click, "context > Copy".
- `press {id | title, in?}`: buttons, checkboxes, segments, links. A pop-up is chosen with `set`.
- `set {id | title, value, in?}`: text fields, checkboxes (true or false), pop-ups and segments (the option's title),
  and the console's editor (`console.editor`: the whole text).
- `select {pane: sidebar | tabs, names, none?, in?}` selects connections or a tab by name; without pane, rows of a list in
  the frontmost sheet or window. `none: true` selects nothing.
- `type {text}` types where the cursor is; `key {combo}` presses keys as the keyboard does ("cmd+return", "escape"). The
  menu-bar shortcuts follow the person's Settings ▸ Keys, so prefer `menu`.
- `click {x, y, count?, button?, modifiers?, in?}`, `double_click {x, y}` (opens or edits), `right_click {x, y}`
  (answers with the menu it opens). Points come from `snapshot` frames or a scale-1 screenshot.
- `wait {until: sheet | no_sheet | popover | idle | text, text?, timeout?}`: idle means nothing runs.

Open and Save panels can't be driven: `press` Cancel, or leave them to the person. Every other tool is refused there.

## gate

AirSQL's agents' gate fails closed. While it carries out your request, nothing that could change something runs on
its own:

- **The SQL preview sheet is the person's.** Run in a console, Apply in the grid and the editors, a compare's sync,
  Restore, Copy and Import show what will run in the SQL preview sheet, marked "Asked by <your client>". Only the
  person can press its Run (or Return, or click it): you get "Only the person at the Mac can approve…". You may press
  Decline (`preview.cancel`), and `wait {until: no_sheet}` for their answer. A console run of statements that are all
  proven read-only (see read-only) runs without asking.
- **Statements on the person's sessions** that what you did sends, and that aren't proven read-only (a Commit, a
  Roll Back, the transaction mode, a Kill), wait in the same sheet, one by one.
- **A read-only connection** refuses in the console (and the navigator, a sync, Restore and Import) any statement
  that isn't proven read-only, a bare USE aside, before anything asks: there is nothing to approve. A table tab's WHERE
  filter must pass the same check inside its SELECT. Open in Terminal starts a read-only session there; the process
  list's Kill (the person's sheet) still works, as it changes no data.
- **The person's alone, even with approval:** agent access levels and sample rows, a connection's colour (production),
  read-only switch, server, route, login and safety settings, every Safety setting (this gate's switch among them),
  whether agents are allowed, which connections there are (none can be deleted for you), the client tools AirSQL runs, the shortcuts, and every other setting but the look (theme,
  fonts and sizes, tab width and word wrap, rows per page, long values, the date format, the NULL text). Other saved data (names, folders, the look) is refused too while Settings ▸ Safety ▸
  Ask before agents change anything is on. The Settings window is to look at.
- **Files, the clipboard, trust:** you can't save a console's file, open a client in Terminal, start an export, save a Liquibase changelog, save
  or remember a password, trust a certificate or SSH host key, or paste (the clipboard is the person's); use `type` or
  `set` for text, and run_queries `to_file` for results. A button marked destructive (Don't Save, Disconnect with a
  transaction open, Delete, Clear) is the person's call, and so is Quit. The connection editor opens for you, but its
  Save keeps nothing that is the person's.
- **A production console's text:** `type` or `set` into the editor of a console on a connection coloured Production
  shows the person the text first; single keys that would change it are refused.
  The commands that change its text (Delete Line, Move Statement, Comment Lines, Cut and the like) and the text view's own
  control keys (⌃K, ⌃T, ⌃Y) are refused there: use `type` or `set`.
- **Data you may not read is hidden:** on connections below Schema + read, grids, query results (and the value panel,
  View As, charts, Column Summary and the status bar's figure), the filters a value goes into (`result.filter`,
  `tableData.where`, `values.list`, `quickFilter.value`), the process list and its selected statement (`processes.statement`), Export Rows' and Import's
  previews (`export.preview`, `csv.preview`), a table's note in the tree (`console.insightNote`), a compare's rows and sync script, the
  console's Messages (`console.messages`: a server's error can quote a value), an EXPLAIN's steps in every view (`console.planTree`, `console.planOperations`, `console.planDiagram`, `console.planDetails`, `console.planRaw`), a pick-list's or filter's suggested values (`grid.set`, `grid.lookup`, `tableData.suggestions`),
  who may log in (`list.usersandroles.table`, `users.grants`) and the SQL preview's statements (`preview.sql`) are covered in screenshots ("Hidden from agents") and left out of
  snapshots (`hidden`: no value, title or help; `set` still types into a hidden field). The SQL log's text
  (`sqlLog.text`) and Query History's All connections list (`history.every`), which hold every connection's statements, are
  hidden from you on every connection. A cell's right-click Quick
  Filter ▸ lists the Data menu's items for you (Equal to Selection…), never the value or the clipboard's text.

The person can turn the asking off for a connection or for all (Settings ▸ Safety); person-only things stay theirs.

## screens

Ids for `press`, `set` and `screenshot element:<id>`; `snapshot include elements` lists what is on screen now.

- **Main window toolbar**: `toolbar.connection`, `toolbar.database`, `toolbar.run`, `toolbar.runAll`,
  `toolbar.explain`, `toolbar.transactionMode`, `toolbar.commit`, `toolbar.rollback`, `toolbar.cancel`.
- **Sidebar**: `sidebar.filter`, `sidebar.connections` (select with `select pane=sidebar`), `sidebar.newConnection`,
  `sidebar.processes`. With nothing open: `firstRun.addConnection`, `firstRun.setUpAgents`; a connection's summary:
  `summary.connect` (`summary.disconnect` while it is connecting), `summary.newQuery`, `summary.edit`; a connected one
  shows its host page.
- **Tabs**: `tabs`, `tabs.new`, each `tab` with `tab.close` (select with `select pane=tabs`), `tab.rename`.
- **Navigator** (a connection's tree in the sidebar; double-click opens): a database `database.tables`; text views
  `navigator.text`; Find Text `find.text`, `find.scope`, `find.go`, `find.stop`, `find.results`, `find.status`;
  processes `processes.list`, `processes.refresh`, `processes.interval`, `processes.killQuery`,
  `processes.killConnection`, `processes.statement`; the host page `host.panes`, `host.properties`, `host.readSizes`,
  `host.stopSizes`, `host.diskUsage`, `host.editVariable` (its sheet `host.variable.scope`, `host.variable.value`), and its lists `list.databases.table`, `list.variables.table`,
  `list.status.table`, `list.commandstatistics.table` (each with `.filter` and `.caption`); Disk Usage `disk.heading`,
  `disk.summary`, `disk.back`, `disk.refresh`, `disk.stop`, `disk.compare`, `disk.optimize`, `list.diskusage.table`.
  Edit Variable and Optimize wait for the person, and Read-only and Production refuse Edit Variable; Users and Roles
  (`users`, `list.usersandroles.table`, `users.grants`) can be read with read access, and every change there is refused
  to agents: `users.new`, `users.newRole`, `users.edit` and Modify Grants say so; sheets
  `newDatabase.name`, `rename.name`, `copyTable.name`, `copyTable.database`,
  `copyTable.where`, `copyTable.rows`, `bulk.database`, `bulk.engine`.
- **Connection editor** (File ▸ New Connection, Connection ▸ Edit…; Save is the person's for what is theirs):
  `editor.tabs`, `editor.name`, `editor.folder`, `editor.comment`, `editor.database`, `editor.databaseFilter`, and
  the person's `editor.colour`, `editor.host`, `editor.port`, `editor.socket`, `editor.user`, `editor.password`,
  `editor.askPassword`, `editor.route`, `editor.ssh`, `editor.addJump`, `editor.proxyKind`, `editor.proxyHost`,
  `editor.tlsMode`, `editor.readOnly`, `editor.reconnectAtLaunch`, `editor.sharedSession`, `editor.startsManual`, `editor.startIsolation`, `editor.queryTimeout`,
  `editor.idleDisconnect`, `editor.timeZone`, `editor.startupSQL`, `editor.clientPath`, `editor.dumpPath`, `editor.ownSafety`,
  `editor.agentAccess`, `editor.sampleRows`; what the tools are `editor.clientFound`, `editor.dumpFound`, the route
  `editor.routePath`; `editor.test`, `editor.save`, `editor.saveAndConnect`, `editor.cancel`, `editor.status`.
- **Status bar**: `status.route`, `status.server`, `status.transaction`, `status.activity`, `status.agent`,
  `status.sqlLog`; popovers `popover.route`, `popover.server`, `popover.transaction` (`popover.commit`,
  `popover.rollback`), `popover.agent` (`agents.setUp`, `agents.turnOff`), `activity.popover` (`activity.cancel`,
  `activity.cancelAll`).
- **Console**: `console.editor`, `console.cancel`, `console.summary`, `console.resultTab` (`console.resultRename`),
  `console.messages`, `console.planChoice`, `console.planTree`, `console.empty`, `console.connectionChoice`; Compare
  With… (the result tab's menu) asks with `compare.with` and `compare.key`, and opens the rows that differ in a result
  tab of their own, a grid under the `grid.legend` line (added green, removed red, changed cells amber); find bar
  `find.search`, `find.replace`, `find.matchCase`, `find.regex`, `find.replaceOne`, `find.replaceAll`, `find.done`;
  helpers `console.helpers`, `helpers.choice` (Columns, Functions, Keywords, Snippets, History), `helpers.filter`, `helpers.list`; the snippet sheet (Query ▸ Save as Snippet…) `snippet.name`, `snippet.abbreviation`, `snippet.folder`, `snippet.body`, `snippet.save`, `snippet.cancel`; completion `completion.list`;
  history sheet `history.search`, `history.list`, `history.preview`, `history.all`, `history.insert`, `history.clear`, `history.cancel`; the editor's corner `console.position`, `console.problemCount`; plan views `console.planOperations`, `console.planDiagram`, `console.planDetails`, `console.planRaw`;
  Query ▸ Sessions… `sessions.list`; File ▸ Local History… `localHistory.list`, `localHistory.preview`, `localHistory.restore`, `localHistory.cancel`; Go to Line `goToLine.text`.
- **Grid** (results, table data): `grid`, `grid.header`, `grid.rowNumbers`, `grid.editor` (Return or F2 opens it on the
  focused cell; a value its column refuses keeps it open, saying why in `grid.editor.problem`; Esc leaves the cell as it
  was); the status bar's `grid.rows`,
  `grid.position`, `grid.figure`; the value panel `valuePanel` (`valuePanel.mode`, `valuePanel.text`, `valuePanel.tree`,
  `valuePanel.image`, `valuePanel.actions`, `valuePanel.loadFull`; in a table tab its text edits the selected cell: ⌘↩ keeps it as a pending
  edit, Esc puts it back; Load from File… and Save to File… are the person's); Record View `record.previous`, `record.next`, `record.close`; View As `grid.text`, `grid.tree`,
  `grid.chart` (`chart.kind`, `chart.x`, `chart.y`); Column List `columnList.search`, `columnList.table`; Column
  Summary `columnSummary` (a `columnSummary.value` filters by it); Go to Row `goToRow.text`. A console result filters
  its own rows (Data ▸ Quick Filter, Filter by Values…, Sort by Columns…, Search All Columns): its bar
  `result.filterBar`, shown while a filter or search is on, has `result.scope`, `result.filter` (the conditions as SQL),
  `result.clearFilter` and `result.search` (Return searches).
- **Table tab** (a table's rows: Database ▸ Open Data or a double-click in the tree; a single click shows them in the
  preview tab): `tableData`; its grid bar `tableData.scope` (where filtering runs), `tableData.where` (a WHERE condition:
  set it, then key `return` applies it), `tableData.recentFilters`, `tableData.clearFilter`, `tableData.search`, `tableData.loadedOnly`,
  `tableData.busy`; the notice `tableData.notice` (`tableData.noticeText`, `tableData.preview`, `tableData.revert`,
  `tableData.apply`: Apply opens the SQL preview, whose Run is the person's); the status bar's `tableData.count`,
  `tableData.loadMore`, `tableData.loadAll`; find bar (⌘F) `find.text`, `find.replaceText`, `find.options`,
  `find.previous`, `find.next`, `find.count`, `find.replace`, `find.replaceAll`, `find.done`; Export Rows `export.rows`,
  `export.format`, `export.headers`, `export.null`, `export.separator`, `export.quote`, `export.encoding`, `export.crlf`, `export.joinLines`, `export.open`, `export.copy`, `export.save` (the person's),
  `export.cancel`; Filter by Values `values.search`, `values.list`, `values.all`, `values.none`, `values.ok`,
  `values.cancel`; Data ▸ Quick Filter ▸ Type a Value… `quickFilter.operator`, `quickFilter.value`, `quickFilter.add`
  (then press Filter); Data ▸ Sort ▸ Sort by Columns… `sort.column.N`, `sort.direction.N`, `sort.up.N`, `sort.down.N`,
  `sort.remove.N` (N from 0, the first sort column first), `sort.add`, `sort.ok`, `sort.cancel`. Edits wait as pending changes until Apply. Typing a value checks it by the column's type first. Return
  or a double-click on an ENUM cell shows its values as a menu; on a SET cell a checklist `grid.set` (`grid.set.member`
  checkboxes, `grid.set.done`, `grid.set.cancel`); on a foreign key cell the referenced rows `grid.lookup`
  (`grid.lookup.search`, `grid.lookup.rows`; Return picks); a one-column foreign key's cell shows the referenced row's
  label after its value. A column header's menu (and the Data menu) has Use as Label, Add Virtual Foreign Key… (a sheet
  with `virtualKey.table`; kept on this Mac, never in the database) and Remove Virtual Foreign Key. Data ▸ Set Value ▸ Insert Value ▸ puts in NOW(), UUID() and the like;
  Paste, Paste as New Rows and Paste with Format… (its sheet `pasteFormat.separator`, `pasteFormat.decimal`,
  `pasteFormat.dateOrder`) are the person's (the clipboard is). Query ▸ Edit as Table opens the selected INSERT
  statements in their table's tab as new rows; Apply then shows the SQL preview. Quit is the person's too: it lists pending changes
  and open transactions first.
- **Console result editing**: a console result of a one-table SELECT that includes the key, or of an inner join with
  every table's key, edits like a table tab (`grid.editor`, the pick-lists and foreign key drop-down, Data ▸ Set Value ▸ Set NULL, Set DEFAULT, Insert
  Value, Delete Rows in a one-table result, Undo, Revert); the status bar's `result.editState` says Editable or Read-only (its tooltip says why), and a double-click on
  a read-only cell says why in `grid.readOnlyReason`. Pending changes show in the notice `tableData.notice`
  (`tableData.apply`, `tableData.preview`, `tableData.revert`); Apply opens the SQL preview, whose Run is the person's.
- **SQL log** (View ▸ SQL Log: under the tabs while a server is connected, closed at first; or its window): `sqlLog.text`, `sqlLog.reveal`,
  `sqlLog.clear`, `sqlLog.window`; the window also has `sqlLog.filter`.
- **Table tab's switch**: `tableData.page` (Data, Structure, DDL); View ▸ Table Page does the same. Toolbar buttons that don't fit are hidden
  and listed by `grid.toolbar.more`; use their commands in the menu bar.
- **Sidebar**: `sidebar.filter` (part of a name, or `/a regular expression/`), `sidebar.databaseFilter`, `sidebar.favourites`, `sidebar.options`,
  each row's `tree.star`; View ▸ Tree holds the choices (saving them is the person's while Ask before agents change anything is on).
- **Quick Open** (`quickOpen.field`, `quickOpen.list`, `quickOpen.open`): commands listed there are refused to agents; use the `menu` tool.
  Quick Documentation on a tree row leaves out the table's rows for an agent.
- **Find in Tabs and Files**: `findFiles.text`, `findFiles.results`, `findFiles.status`; `findFiles.replace` is the person's.
- **Files panel** (View ▸ Files): `sidebar.files`, `files.outline`, `files.attach`, `files.newScratch`; Run On opens Run SQL File…, whose Run asks the person.
- **Restored tabs** (placeholders after a relaunch): `restored.what`, `restored.state`, `restored.open`, `restored.edit`, `restored.help`.
- **Agent tab** (View ▸ Agent Results: the statements agents ran on the connection and the rows they got):
  `agentResults`, `agentResults.list`, `agentResults.empty`, `agentResults.detail`, and the result grid `grid`.
- **SQL preview sheet**: `preview.heading`, `preview.agent`, `preview.production`, `preview.warning`, `preview.sql`,
  `preview.confirm`, `preview.saveChangeset`, `preview.copy`, `preview.console`, `preview.cancel`, `preview.run` (the person's).
- **Table editor**: `tableEditor.sections`, `tableEditor.list`, `tableEditor.options` (`.name`, `.database`, `.engine`,
  `.collation`, `.rowFormat`, `.autoIncrement`, `.comment`), `tableEditor.sql`, `tableEditor.apply`,
  `tableEditor.partitions`, `tableEditor.partitionClause`, `tableEditor.discard`, `editor.status`, `editor.retry`. **Object editor**: `objectEditor.code`,
  `objectEditor.definer`, `objectEditor.run`, `objectEditor.apply`, `objectEditor.revert`, and its fields, `objectForm.name` and the like. **ER diagram**: `erDiagram.database`,
  `erDiagram.diagram`, `erDiagram.canvas`, `erDiagram.add`, `erDiagram.arrange`, `erDiagram.show`, `erDiagram.export`, `erDiagram.find`, `erDiagram.fit`. **SQL Generator**: `generator.text`,
  `generator.copy`, `generator.console`, `generator.save`, `generator.layout`, and a box per option (`generator.indexes` and so on).
- **Compare window**: `recon.level` (Servers, Databases, Objects), `recon.source.connection`, `recon.source.database`,
  `recon.source.object`, `recon.target.connection`, `recon.target.database`, `recon.target.object`, `recon.swap`,
  `recon.mode`, `recon.tables`, `recon.compareButton`, `recon.ignore`, `recon.filter`, `recon.hideMatching`, `recon.back`,
  `recon.list` (`recon.tick` in its rows), `recon.tabs`, `recon.diffStyle`, `recon.previousDifference`,
  `recon.nextDifference`, `recon.sourceDDL`, `recon.targetDDL`, `recon.rows` (the rows that differ: a grid),
  `recon.script`, `recon.destructive`,
  `recon.sync`, `recon.changeset`, `recon.export`, `recon.reportFormat`, `recon.progress`, `recon.cancel`; its tables
  sheet `reconTables.filter`, `reconTables.list`, `reconTables.all`, `reconTables.none`, `reconTables.done`, `reconTables.cancel`.
- **Client tools sheets** (windows of their own on screen, which these tools treat as sheets): `tools.heading`, `tools.filter`, `tools.objects` (`tools.include.<name>`), `tools.status`,
  `tools.timeLeft`, `tools.useBuiltIn`, `tools.unchecked` (running with it ticked: the person's), `tools.cancel`,
  `tools.run` (Export: the person's). Export `export.content`,
  `export.singleTransaction`, `export.hexBlob`, `export.gzip`, `export.dropTable`, `export.objects`, `export.tool`,
  `export.chooseTool`, `export.dataMode`, `export.insertSize`, `export.createDatabase`, `export.dropDatabase`, `export.removeDefiner`,
  `export.removeAutoIncrement`, `export.wrapInTransactions`, `export.output`, `export.fileFormat`, `export.saveTo`, `export.choose`, `export.extra`, `export.command`, `export.copyCommand`,
  `export.reveal`; Restore `restore.file`,
  `restore.fileInfo`, `restore.choose`, `restore.database`, `restore.tool`, `restore.chooseTool`, `restore.stopOnError`, `restore.continue`,
  `restore.command`, `restore.copyCommand`; Copy `copy.target`, `copy.database`, `copy.content`, `copy.objects`, `copy.replace`,
  `copy.summary`; CSV import `csv.file`, `csv.choose`, `csv.database`, `csv.table`, `csv.newTable`, `csv.separator`, `csv.quote`, `csv.encoding`,
  `csv.header`, `csv.skip`, `csv.trim`, `csv.emptyIsNull`, `csv.decimalComma`, `csv.duplicates`, `csv.emptyFirst`, `csv.keepGoing` (the person's),
  `csv.mapping`, `csv.ddl`, `csv.preview`; Paste (`csv.paste`) is the person's.
- **Liquibase**: Generate Liquibase Changelog `liquibase.content`, `liquibase.database`, `liquibase.filter`, `liquibase.objects`
  (`liquibase.include.<name>`, `liquibase.rows.<name>`, `liquibase.where.<name>`), `liquibase.author`, `liquibase.ids`,
  `liquibase.rollback`, `liquibase.preconditions`, `liquibase.layout`, `liquibase.saveTo`, `liquibase.choose`,
  `liquibase.preview`, `liquibase.copy`, `tools.run` (the person's); Save as Changeset `changeset.heading`,
  `changeset.file`, `changeset.choose`, `changeset.new`, `changeset.sql`, `changeset.status`, `changeset.copy`,
  `changeset.cancel`, `changeset.save` (the person's).
- **Prompts**: `password.field`, `password.remember`, `login.user`, `login.password`, `prompt.answer`,
  `prompt.remember` (remembering is the person's), `trust.fingerprint` (Trust is the person's), `help`.
- **Settings** (to look at): General `settings.appearance`, `settings.showFolder`; Editor `settings.editorFontSize`,
  `settings.completionTableAlias`, `settings.autoKeywordCase`; Format `settings.format.preset`, `settings.format.preview`, `settings.format.*`;
  Grid `settings.gridFontSize`, `settings.rowsPerPage`, `settings.loadAllAsksAbove`, `settings.nullText`,
  `settings.transposeSingleRow`; Connections
  `settings.detailsTableThreshold`, `settings.schemaRefreshMinutes`; Keys `settings.keysFilter`, `settings.keys`; Safety `settings.safety.*`; Agents `settings.agentsAllowed`,
  `settings.agentAccessList`, `settings.agentExports`, `settings.copyMCPCommand`; Client Tools `settings.findTools`,
  `settings.toolsFound`.

## troubleshooting

- "isn't running, or agents are off": open AirSQL and turn on Settings ▸ Agents ▸ Allow AI agents to use AirSQL.
- "No connection … is open to agents": use a name or id from `context`; the person may have set it to Off.
- "isn't connected": ask the person to connect it in AirSQL.
- "needs Schema + read" (or analytics): the person can raise the level in Settings ▸ Agents.
- "Refused": the statement isn't provably read-only; rewrite it as one plain SELECT, or propose it with
  `open_in_console`.
- "Stopped at the agent timeout": narrow the query (WHERE, LIMIT; on MongoDB a filter on an indexed field), or ask
  for the analytics level.
- "is a MongoDB connection" or "is a MySQL or MariaDB connection": use the tools of that engine (see mongodb).
- "… is Extended JSON text: pass it as a string": send documents and pipelines as strings of JSON.
- "Only the person at the Mac can approve…" or "…can change…": that is the gate; tell the person what waits for them.
- "The person at the Mac declined": nothing ran; ask what they want instead.
- "Settings are the person's", "The clipboard is the person's": use `snapshot include settings` to read settings, and
  `type` or `set` instead of pasting.
