# AirSQL 1.0 implementation plan

Version 2, 3 November 2026. Changed after an adversarial review (findings are referenced as R1–R19). Scope: the
1.0 rows of `docs/dev/scope.html`, the grid in `docs/dev/grid-spec.md`, the look in `docs/dev/mockups.html`, the
lessons in `docs/dev/research.md`.

## 1. Ground rules (every lane, every commit)

- **Simplicity first:** the smallest change that solves the problem; no speculative abstractions, no new layers or
  settings unless a scope row needs them. Follow AirSCP's patterns (`../porter`, Apache 2.0, same author). Keep
  AirSCP's type names in ported files so the two can be diffed.
- **Toolchain:** Swift 5 language mode, compiles with Swift 5.9+, deployment target macOS 13.1, no Xcode project,
  universal (arm64 + x86_64). No third-party Swift packages. Nothing from Homebrew in the build or the app. The one C
  dependency is MariaDB Connector/C with OpenSSL, built by a pinned, checksummed script. Builds use the macOS 26 SDK
  (as AirSCP's CI does: the macOS 27 SDK's SwiftUI needs a macro plugin only Xcode has); tests run with Xcode 26's
  toolchain in CI (Swift Testing macros).
- **Native feel:** single click selects or shows, double click opens or edits, right click opens the item's menu, on
  every surface (§2.12); ⌘/⇧ multi-select; every action in the menu bar with its shortcut; full keyboard use; no
  database, network or file work on the main thread; a busy indicator for anything slow (§2.11); a polished layout
  with no cut text (§2.13).
- **The app explains itself:** every control and menu item has a one-line tooltip (verb first, no full stop);
  disabled items say why; plain words before jargon; empty states say what to do next (`HelpTests`).
- **Security defaults:** secrets only in the Keychain, never on a command line, in logs, in agent replies or the SQL
  log; SQL built only with quoting helpers; TLS verified against the real server name; restricted login plugins;
  `LOCAL INFILE` off; multi-statements off; local endpoints are Unix sockets in a private folder, never TCP ports.
- **Data safety:** nothing is written without Run or Apply; Apply checks affected rows exactly; no silent reconnect;
  destructive steps are opt-in and marked.
- **Docs follow the code:** user page in `docs/`, `Resources/AgentGuide.md` for anything agents reach.
- **Public repository** (github.com/kleash/airsql): no secrets, real hostnames, personal paths or e-mail addresses in
  code, tests, docs, screenshots or commits; short imperative commit messages, no attribution trailers.
- **Safety on this Mac:** never read or write `~/.ssh` in tests (throwaway SSH dir as AirSCP's `testenv/AGENT.md`);
  tests keep passwords in an in-memory store, never the login Keychain (R18); never stop or recreate AirSCP's
  `porter-lab` containers or the old `mysqlmacclient-test` ones; AirSQL's lab is the Compose project `airsql-lab`.

## 2. Architecture

### 2.1 Targets

| Target | Kind | What |
|---|---|---|
| `CPTY` | C | Ported from AirSCP: run a program on a pseudo-terminal |
| `CMariaDB` | C module map | Headers of the bundled libmariadb; links `vendor/out/universal/lib/libmariadb.3.dylib` |
| `AirSQLCore` | Swift, no UI | Driver and sessions, routes, SQL text tools, schema cache, grid data model, SQL generation, formats, client tools, recon, Liquibase, agent bridge, models, settings, activity |
| `AirSQL` | Swift executable | The AppKit app. SwiftUI only for Swift Charts |
| `AirSQLTests` | Swift Testing | Unit, app, interaction, layout, lab (`AIRSQL_LAB=1`) and performance tests |

### 2.2 Driver and sessions

- **libmariadb (Connector/C 3.4.x, LGPL-2.1-or-later)** from `scripts/build-mariadb.sh`: pinned version and SHA-256,
  static OpenSSL (AirSCP's pin) with a fixed `--openssldir`, client plugins `caching_sha2_password`,
  `sha256_password`, `client_ed25519`, `mysql_clear_password`, `dialog` compiled in, zlib from the SDK, universal via
  `lipo`. Shipped as `Contents/Frameworks/libmariadb.3.dylib` with an `@rpath` install name, signed from P0 on
  (`codesign --verify --deep --strict` in CI), library validation on. The build output is cached outside the repo
  (`$AIRSQL_VENDOR_CACHE`, default `../airsql-vendor-cache/<script hash>`) so worktrees don't rebuild it. Releases
  attach the exact Connector/C source and patches; NOTICE explains relinking and the licence combination (R18).
- **`DBConnection`** (Core): one dedicated thread per session running blocking libmariadb calls; `async` API.
  - `connect(options)` runs the whole session setup every time: charset `utf8mb4`, `time_zone` as configured,
    startup SQL, `SET SESSION TRANSACTION READ ONLY` where required. **Never** `MYSQL_OPT_RECONNECT` (R8).
  - `query(sql)` reads rows promptly into a `ResultStore` (compact column buffers) up to a row cap, so the server is
    never left waiting on a slow reader (R10). Hitting the cap cancels the statement and marks the result
    "first N rows"; "Export all" re-runs it streamed to a file, only when the classifier proves it is a read.
  - Flags: `CLIENT_FOUND_ROWS`, `CLIENT_MULTI_RESULTS` (for procedures), **no** `CLIENT_MULTI_STATEMENTS` (R4).
  - Options: `MYSQL_OPT_LOCAL_INFILE = 0`; `MARIADB_OPT_RESTRICTED_AUTH` = native, caching_sha2, ed25519 by default,
    cleartext and dialog only for PAM/LDAP logins over verified TLS; `MYSQL_PLUGIN_DIR` set to an empty folder in
    the bundle (R5).
  - Every statement carries a `/* airsql:<session>:<n> */` tag. `cancel()` opens a short side connection, checks
    `@@server_uuid` matches, checks the processlist row for that thread still runs the tagged statement, then sends
    `KILL QUERY` (MariaDB: `KILL QUERY ID`). Through ProxySQL or MaxScale, where the uuid check fails, Cancel says it
    can't cancel safely and offers Disconnect (R10).
  - The SQL log is written inside `DBConnection` (so nothing bypasses it), with credentials masked the way MySQL
    masks its own logs (IDENTIFIED BY, PASSWORD(), SET PASSWORD, CHANGE REPLICATION SOURCE … PASSWORD, CREATE SERVER
    … PASSWORD, AES/ENCRYPT keys) and startup SQL logged as "startup SQL (n statements)". File mode 0600, rotated
    (R16). What is logged is documented.
  - MySQL and MariaDB errors mapped to plain language (`ErrorMapping`), with the original code and text kept.
- **TLS (R2):** verification is done against the **real database host name** (as typed in the connection), not the
  local socket, using macOS trust (`SecTrust`, system roots plus an optional CA file) through Connector/C's TLS
  verification callback. Self-signed or private servers: the certificate fingerprint is shown in a Trust sheet and
  pinned (`MARIADB_OPT_TLS_PEER_FP`). P0 proves this works on 3.4 through the bastion; if the callback can't do it, a
  small patch in the build script adds an expected-host option. Lab test: a CA-signed certificate for the
  database's internal name, reached through the bastion, plus a wrong-name certificate that must fail.
- **Session model (frozen in P0, R12):** per connected connection:
  - *main* session: the console tabs share it (one transaction context, shown in the toolbar);
  - *data* session: table tabs, grid paging and Apply (Apply runs its own transaction here, so it never commits the
    console's open transaction, R7);
  - *schema* session: introspection;
  - *agent* session: read-only, created on first agent use;
  - *tools*: client tools and recon open their own;
  - a side connection only for Cancel.
  "Ask each time" passwords are held in memory for the app's life (cleared on Disconnect), never written.
- **Reconnect (R8):** a dropped session is reported, not hidden. Reconnect runs `connect()` again; if a transaction
  was open, the user is told it was rolled back and the old thread is killed (via a fresh session) so its locks go.
  Keep-alive pings stop for a session whose transaction has been open longer than a setting (default 15 minutes) and
  the Tx badge warns. Pending grid edits survive on the client; Apply's affected-row check catches rows changed
  meanwhile.
- **Quoting (`SQLQuote`, R18):** identifiers in backticks with doubling; strings with `mysql_real_escape_string` in
  single quotes, or quote doubling when the server reports `NO_BACKSLASH_ESCAPES`; binary as `X'…'`; bits as
  `b'…'`. Every generator uses it; a test feeds hostile names and values through every generator.
- **Minimum servers:** MySQL 5.7 and MariaDB 10.5 (still common), tested in the lab next to MySQL 8.0, 8.4, 9.x and
  MariaDB 10.6, 10.11, 11.4, 11.8 (R14).

### 2.3 Routes: every route ends in a private Unix socket (R1)

Local endpoints are Unix sockets in a 0700 folder under Application Support, never TCP ports, so no other local user
or process can use the tunnel. The driver connects with `unix_socket`; the client tools with `--protocol=SOCKET
--socket=…`; Terminal the same.

| Route | How |
|---|---|
| Direct | TCP to host:port, or the server's own Unix socket |
| SSH tunnel | One OpenSSH ControlMaster per connection, `-L <dir>/<id>.sock:db:3306` with `StreamLocalBindUnlink=yes` |
| SSH via jump hosts | A generated per-connection `ssh_config` (0600, private folder) with one `Host` block per hop and a `ProxyJump` chain; each hop's login prompt comes through Askpass with the hop's name (R13: AirSCP has one hop only, so this is new work, M) |
| SSH + proxy | The first hop's block uses AirSCP's `ProxyConnect` helper as `ProxyCommand` |
| Proxy only | The app listens on a private Unix socket; each accepted connection runs AirSCP's tested blocking `ProxyConnect` (SOCKS5, HTTP CONNECT with Basic and Digest) on its own thread and pipes bytes (R19: no NWConnection rewrite) |

Ported from AirSCP (a port, not a copy, R13): `Commands`, `Askpass`, `ProxyConnect`, `Runner`, `Keychain`, `DebugLog`,
`ErrorMapping` with the slices of `Models`/`Store`/`Env`/`Quote` they need; a new, small `Tunnel` type replaces
AirSCP's `Session` (master, forward, check, exit). Also ported for tests: `Support.swift` (throwaway sshd) and the
fake proxies from `ProxyTests.swift`. Each ported file keeps a header naming its AirSCP origin and version.

### 2.4 Main window and shared UI (frozen in P0)

```
┌ toolbar: connection ▾ · database ▾ · Run ⌘↩ · Run all ⇧⌘↩ · Explain · Tx: Auto ▾ · Commit · Rollback · Cancel ┐
├ colour tint of the connection ───────────────────────────────────────────────────────────────────────────────┤
│ sidebar: connections + tree │ tabs (tinted) │ editor or table view / results tabs / DataGridView / grid bar   │
└ status: route · server version · Tx badge · activity (running work, Cancel) · agent chip · SQL log ──────────┘
```

P0 builds and freezes, so lanes plug in instead of inventing:
- main window, tab bar, toolbar, status bar, connection colour tint, sidebar container;
- **menu bar**: P0 declares the menus and their order; each lane adds its items in its own `Menus+<Lane>.swift`
  file that P0 slots in; actions go through the responder chain via an `@objc` protocol of selectors declared in
  P0 (R17); P0 settles the shortcut map (no system conflicts: ⌥⌘D is the Dock, so Set DEFAULT has no shortcut; ⌘S
  saves a file in the console and applies in a table tab; ⌘↩ only runs);
- **Settings window** with panes (General, Editor, Grid, Connections, Safety, Agents, Client tools); lanes add
  their own pane files;
- **Activity** model and status-bar list (§2.11);
- **Safety settings** model with per-connection overrides (§2.10);
- **SQL preview sheet**: the one sheet that shows SQL before it runs (grid Apply, table editor, drop/rename,
  restore, recon sync), with the production prompt, "Save as Liquibase changeset" (hook: `ChangeSQL` = statements +
  title + connection; L8 implements the writer behind it), cascade and engine warnings, and the agent gate;
- per-table view settings store (`TableViewSettings`: filters, sort, hidden columns, widths, display types);
- Help menu, first-run empty state ("Add your first connection", "Set up agents"), Trust and password sheets;
- the agent UI-driving harness ported from AirSCP's `AgentSnapshot`/`AgentServer` core (snapshot, screenshot, menu,
  press, set, select, key, type, click, double-click, right-click, wait) **as a test harness**; the agent-facing
  gate and database tools come in L7.

### 2.5 Data grid (decision D5)

- `DataGridView`: custom layer-backed `NSView` in an `NSScrollView`, draws visible cells with Core Text; header and
  row-number views synced; one editor overlay for the cell being edited. A glyph cache only if the spike shows it is
  needed (R19).
- `GridSource` protocol and the **embedding API** (how a console result tab, a table tab, Transpose and recon host a
  grid) are frozen in P0 by the spike (R12). Sources: `TableDataSource` (paged `LIMIT … OFFSET`, one strategy, R19),
  `ResultSetSource` (a `ResultStore`), `TransposedSource`, `DiffSource`.
- `PendingChanges` (Core): edits, inserts, deletes keyed by primary key or NOT NULL unique key; undo; persisted to
  Application Support on every change so a crash doesn't lose them; `statements()` via `SQLQuote`.
- **Apply (R7):** on the data session, one transaction; each statement's affected rows must equal what it should
  touch (with `CLIENT_FOUND_ROWS`); on any mismatch everything rolls back and the grid points at the row ("this row
  was changed or deleted by someone else; reload it"). Key columns are never shortened for display, so their values
  are exact. Tables on MyISAM, Aria or MEMORY get a warning in the preview (no rollback); deletes list the tables
  that `ON DELETE CASCADE` will touch.
- Header: clicking a column header selects the column (spreadsheet habit); the sort control at the header's right
  (shown on hover and when sorted) sorts; ⌥-click on it adds a sort. On a table estimated over 1 M rows, sorting by a
  column without an index asks first (R17).
- Accessibility: an `NSAccessibility` table with total counts, lazily created cell elements, focus notifications and
  editing; built in the spike, not after (R15).
- **Spike (gate):** the targets in grid-spec §8; frame rate measured on this Mac's 120 Hz ProMotion display; CI
  checks deterministic numbers instead (R14).

### 2.6 Console

- `SQLLexer`, splitter and classifier (Core, built in P0, security-critical): MySQL and MariaDB tokens; backticks;
  `--`, `#`, `/* */`; `/*! … */` and `/*M! … */` executable comments lexed as code; `DELIMITER` lines; custom
  delimiters. Re-lex the whole buffer first; incremental only if measured slow (R19).
- Completion from `SchemaCache` only (no network while typing): keywords, functions per flavour and version,
  databases, tables, columns, the statement's own tables and aliases, `JOIN … ON` from real and virtual foreign keys
  (R15 scope).
- Run: ⌘↩ statement at caret (highlight what ran, no chooser), ⇧⌘↩ all, the selection when there is one; ⌘. cancels.
  Statements are split client-side and sent one at a time (no multi-statements). Results: one tab per result set,
  reused unless pinned, named from the comment above the query; Messages with rows affected, timing, warnings,
  errors at the line.
- Transactions: Auto/Manual, isolation, Commit/Rollback, open-transaction badge, warning on closing.
- Formatter: whitespace and keyword case only; never touches literals, comments, executable comments or DELIMITER
  blocks; a round-trip test proves the token stream is unchanged (R15).
- EXPLAIN: a table plus a text tree (MySQL TREE format; MariaDB JSON flattened); no graphical plan in 1.0 (R15).
- History per connection, SQL log viewer, unsaved tabs restored after relaunch, drag and drop of tree items and .sql
  files into the editor.

### 2.7 Schema cache and navigator

- `SchemaCache` types and introspection queries are frozen in P0 (R12).
- **At connect and on Refresh (⌘R):** names first for every database the connection's filter allows (databases,
  tables, views, routines, triggers, events), using only columns that don't make MariaDB open every table (R11).
  Then columns, indexes, foreign keys and checks, one query per kind across databases, **unless** the server has more
  than a threshold of tables (setting, default 3,000): then a database's details load when it is expanded, or when
  completion, an editor or an agent needs them. Table statistics (rows, size, engine, update time) load for the
  database being viewed.
- The cache survives reconnects (cleared on Disconnect); after DDL only the named objects are refreshed; each load
  has a schema hash.
- Navigator: `NSOutlineView`, grouped by type, filter field, the click contract (§2.12), drag source, process list.

### 2.8 Agents (MCP)

Goal: few round trips, and agents that can never change anything without the person at the Mac.

- **Protocol:** MCP over stdio, current spec revision: tools with `outputSchema` + `structuredContent` (and a short
  text fallback), tool annotations (`readOnlyHint`, `destructiveHint`), read-only **resources** for schemas
  (`airsql://<connection>/schema`), progress notifications for long calls. No resource subscriptions in 1.0: the
  schema hash already avoids resending (R19).
- `AirSQL --mcp` talks to the running app over a Unix socket in Application Support (0600, per-launch token). The
  token is readable by processes of the same user, as in AirSCP; documented (R18).
- **Tools (batch-first):** `context` (connections, flavour/version, colour, agent access, active connection and
  database, schema hashes, open console tabs, applicable safety settings); `get_schema {connection, databases?,
  format: compact | ddl, if_changed_from?}`; `describe {connection, objects: [...]}`; `run_queries {connection,
  queries: [{sql, max_rows?}], format: csv | json, to_file?}`; `profile {connection, table, columns?, where?}` (one
  call, several server-side queries: counts, NULLs, distinct, min, max, average, top values for the chosen columns,
  R15); `explain`; `open_in_console {sql, title}`; `read_console {tab}`; `guide`. UI driving (`snapshot`,
  `screenshot`, `menu`, `press`, `set`, `select`, `key`, `type`, `click`, `wait` incl. "idle") arrives in L7b.
- **Access levels per connection:** Off / Schema / Schema + read / Schema + read + analytics (larger row cap, longer
  timeout, `to_file`); sample rows a separate switch. Production starts Off. Agent export folder: Application
  Support/AirSQL/Agent Exports (no privacy prompts, R18), shown in Settings with Reveal in Finder.
- **Read-only queries (R4):** on the agent session (`SET SESSION TRANSACTION READ ONLY`, `max_execution_time` /
  `max_statement_time`, `@@transaction_read_only` checked before each query), each query wrapped in `START
  TRANSACTION READ ONLY` … `ROLLBACK`, plus a client-side watchdog that cancels at the timeout. The classifier
  accepts one statement only: SELECT, WITH … SELECT (the statement after the CTE list is classified), SHOW,
  DESCRIBE, EXPLAIN (not EXPLAIN ANALYZE, not EXPLAIN of a write). It refuses `INTO`, locking clauses (`FOR UPDATE`,
  `LOCK IN SHARE MODE`), optimizer hints, temporary tables, and any function not on the built-in allow-list (which
  excludes `SLEEP`, `BENCHMARK`, `GET_LOCK` and friends, `LOAD_FILE`, `SETVAL`/`NEXTVAL`, UDFs and stored
  functions). Executable comments are lexed as code. A read-only database user is still recommended in the guide.
- **The gate fails closed (R3):** while an agent call is in progress, `DBConnection` refuses any statement on a
  non-agent session that the classifier cannot prove read-only unless the person at the Mac approves it in a sheet
  showing the SQL; the same for file writes, Restore, Kill, Commit, Apply, Drop, sync scripts, and edits to
  connections or settings. Person-only (an agent can never change them, even with approval): agent access levels,
  connection colour, read-only, routes, credentials, and every safety setting. The WHERE bar and console text typed
  by an agent count as SQL and pass the same check. Paste into a field during an agent call needs approval (the
  clipboard is the person's). Snapshots and screenshots redact grid cells, value panels and result text for
  connections below "read + sample rows".
- Agents never receive passwords; every agent action is in the activity list and the history.

### 2.9 Client tools, recon, Liquibase

- **Client tools (R9):** discovery (Homebrew keg paths, `/usr/local/mysql/bin`, MAMP, PATH), version parse,
  per-connection override, mismatch rules. Invocation: `--defaults-file=<private 0600 file>` as the **first**
  argument (so `~/.my.cnf` can't override), explicit `--protocol` and socket or host/port, options only one family
  knows written with the `loose-` prefix. The file is deleted as soon as the tool has started reading it (Terminal:
  once `mysql` is running, at most 10 s), and on next launch. gzip through `/usr/bin/gzip` (R19). The command line
  shown never contains secrets.
- **Restore safety:** the dump is scanned before running for `USE`, `CREATE DATABASE`, `DROP DATABASE` and
  `GTID_PURGED`; when found, the sheet says which database the file will really write to and asks. "Has tables"
  checks the database the file will write to.
- **Recon (R6):** structure diff on normalised `SchemaCache` objects with ignore rules. Data diff by key, both sides
  with `time_zone = '+00:00'`, keys compared and chunked as `BINARY`; per chunk `COUNT(*)` and `SUM` of a 64-bit row
  hash (`CONV(LEFT(MD5(<encoded row>),16),16,10)`), each column encoded with an ISNULL flag and its length so NULLs
  and separators can't collide; differing chunks split recursively, then rows compared in the app (JSON and floats
  compared as values). Sync scripts: CREATE/ALTER ADD/INSERT/UPDATE by default; DROP, DELETE and narrowing ALTERs
  only when ticked, each marked as destructive in the script; renames asked as mappings first so they aren't DROP +
  ADD; the script opens in a console tab marked "sync script", and running it goes through the SQL preview sheet.
- **Liquibase:** formatted SQL changelog (`--liquibase formatted sql`, `--changeset author:id`, `--rollback`,
  `splitStatements:false` + `endDelimiter` for routines and triggers); dependency order from foreign keys and from
  view bodies parsed with `SQLLexer` (one method for both flavours, R19); "Save as changeset" in the SQL preview
  sheet and for console statements.

### 2.10 Safety settings (on by default, overridable)

Settings ▸ Safety holds the defaults; each connection can override them in its Options tab; a connection coloured
Production starts with the strict preset. Every switch says in plain words what it protects against; overrides
show a small "custom safety" mark on the connection; agents see the applicable settings in `context` and can never
change them.

| Setting | Default | Production preset |
|---|---|---|
| Ask before UPDATE or DELETE without WHERE | on | on |
| Ask before any write from the console | off | on |
| Show the SQL preview before grid Apply | off | on |
| Ask before DROP or TRUNCATE; type the name to drop a database | on | on, typed name for tables too |
| Ask before Restore into a database that has tables, or when the dump names another database | on | on |
| Sync scripts leave out DROP and DELETE unless ticked | on (fixed) | on (fixed) |
| Agents: ask before changes (UI driving) | on | on |
| Agents: row cap / statement timeout | 10,000 / 30 s | 1,000 / 15 s |
| Warn when a transaction stays open (minutes) | 15 | 5 |
| Ask before sorting a large table by a column without an index | on | on |
| Read-only connection | off | user's choice |
| Warn when closing with an open transaction or pending edits | on | on |

### 2.11 Busy indicators everywhere

Anything that can take longer than 150 ms shows that it is working, where its result will appear, within 150 ms;
anything longer than 2 s also shows progress or elapsed time and Cancel. The UI never freezes.
- `Activity` (Core, P0): each operation registers title, connection, progress or elapsed, cancel handler; the status
  bar lists running work with Cancel; the agent snapshot exposes it (`wait until=idle`).
- In place: tree nodes spin while loading; the grid shows "Loading…" rows; Run turns into Cancel with a timer and the
  result tab spins; connecting shows each hop; sheets show a progress bar with rows or bytes and time left; the agent
  chip shows "working".
- Controls that can't be used while work runs are disabled with a tooltip that says why.

### 2.12 Interaction contract: single, double and right click everywhere

Every surface answers all three, as Finder, Mail and Numbers do. ⌘-click and ⇧-click extend the selection wherever
there is more than one item. Right-clicking an item that isn't selected selects it first; right-clicking a
multi-selection acts on all of it. Every context-menu item is also in the menu bar with its shortcut and has a
tooltip. Drag and drop works where a Mac user expects it (tree items into the editor, files onto the window).

| Surface | Single click | Double click | Right click |
|---|---|---|---|
| Connection in the sidebar | Select, show its summary | Connect (or show if connected) | Connect, Disconnect, Edit…, Duplicate, New Query, Open in Terminal, Export…, Restore…, Compare…, Colour, Delete… |
| Database in the tree | Select, show its tables in the database view | Make it current and expand | New Query, Create Table…, Export…, Restore…, Generate Liquibase…, Compare…, Refresh, Drop… |
| Table or view in the tree | Select, preview its data in the current table tab | Open in its own tab | Open Data, Open Structure, Copy Name, Generate SELECT/INSERT/UPDATE, Export…, Copy Table…, Maintenance ▸, Truncate…, Rename…, Drop…, Refresh |
| Routine, trigger or event | Select, show its definition | Open its editor | Open, Run… (procedures), Copy CREATE, Drop…, Refresh |
| Folder or category in the tree | Select | Expand or collapse | New…, Refresh, Expand All, Collapse All |
| Grid cell | Select the cell | Edit in place (typed editor) | Copy, Copy As ▸, Paste, Quick Filter ▸, Column Summary…, Related Rows, Set NULL, Set DEFAULT, Insert Value ▸, Value Panel, Display As ▸, Delete Rows… |
| Grid column header | Select the column; the sort control sorts | Auto-fit width on the border | Sort ▸, Filter by Values…, Hide Column, Column List…, Freeze, Display As ▸, Copy Column Name, Column Summary… |
| Grid row number | Select the row | Open Record View | Copy Rows As ▸, Duplicate Row, Delete Rows…, Record View |
| Result tab | Show it | Rename | Pin, Rename, Close, Close Others, Export…, Compare With… |
| Editor tab | Show it | Rename (unsaved) | Close, Close Others, Duplicate, Rename, Reveal in Finder, Change Connection |
| SQL editor | Place the cursor | Select the word | Run Statement, Run Selection, Explain, Format, Copy As ▸, Cut, Copy, Paste |
| Process list row | Select | Show the full query | Kill Query…, Kill Connection…, Copy Query, Explain |
| Lists in sheets | Select | The list's default action | The item's actions |
| Status bar items | Show its popover | — | Copy, plus the item's actions (Cancel, Commit, Rollback, Clear) |

`InteractionTests` (P0 scaffold, extended by every lane) check each row: a click selects, a double click acts, the
right-click menu has the listed items (enabled, or disabled with a reason), and every context-menu item exists in
the menu bar (R14).

### 2.13 Visual polish standard

- **No cut text:** Auto Layout with hugging and compression resistance, never fixed widths for text; truncation only
  for naturally unbounded content (cell values, long names, paths), always with an ellipsis and the full text in a
  tooltip; text never touches a container edge.
- **Rounded corners respect content:** content inset by at least the corner radius; one radius scale: 4 (cells,
  chips), 6 (controls, fields), 8 (popovers, cards), 10–12 (sheets, windows).
- **Crisp boundaries:** one-device-pixel hairlines aligned to pixels, no double borders, no gaps or overlaps between
  bars, focus rings never clipped, an 8-point spacing grid, aligned baselines.
- **Sizing:** a minimum window size where every screen still works; sheets fit a 13-inch display without scrolling;
  split views keep minimums and remember sizes.
- **Long and odd content:** fixtures with 60-character names, 255-character values, right-to-left text, emoji,
  empty, 1 and 1,000,000 items (R19: no pseudo-localisation layer).
- **States:** hover, pressed, selected, disabled and focused distinct in both themes; WCAG AA contrast; Reduce
  Motion honoured.
- **Checks:** `LayoutTests` (P0 scaffold) walk every window, sheet and popover in light and dark at minimum and
  default size with the long-content fixtures, and fail on text views that need more space than they have without
  truncating, subviews crossing a rounded parent's inset, or overlapping siblings. Each lane saves light and dark
  screenshots of every new screen; the UI/UX reviewer and the orchestrator compare them with the mockups.

## 3. Test strategy

- **Unit:** lexer, splitter, classifier (a corpus of attack statements from R4 must be refused), quoting, every SQL
  generator with hostile input, `PendingChanges` and Apply checks, formats (golden files), filters, diff engine
  (swapped equal-length values, NULL placement, separators, collations must be detected), Liquibase writer,
  client-tool invocation, ssh_config generation, dump scanning, credential masking.
- **Lab (`AIRSQL_LAB=1`, Compose project `airsql-lab`):** MySQL 5.7 (amd64 emulation), 8.0, 8.4, 9.x; MariaDB 10.5,
  10.6, 10.11, 11.4, 11.8, pinned by digest, seeded with one fixture schema (every column type, FKs, views,
  routines, triggers, events, a table without a primary key, a MyISAM table, a 1 M-row table) plus one server with
  5,000 tables; an SSH bastion and a second jump host, an HTTP proxy (Basic and Digest), a SOCKS5 proxy, a ProxySQL
  hop, added latency (`tc netem` sidecar), and a private CA with correct-name and wrong-name server certificates.
  Databases reachable only through their route. Lab tests share containers read-only and create their own
  `lane_<x>_*` databases for writes.
- **App, interaction and layout tests** drive the built app through the harness; screenshots saved as artifacts.
- **Performance:** CI gates on deterministic measures (cells drawn per scroll step, page build time with a 5×
  margin, bytes held in `ResultStore`, launch work done before first frame); frame rate, launch time and memory
  measured on this Mac's ProMotion display before each merge (R14).
- **CI (GitHub-hosted macOS):** universal build, codesign verify, unit/app/interaction/layout tests, keg-only
  `mysql@8.4` and `mariadb@11.4` servers on two ports, routes proven with the ported throwaway sshd and fake proxies,
  gitleaks, CodeQL, version checks. The full lab runs locally before every wave merges.

## 4. Phases and lanes

Lanes own files. Shared files (Package.swift, menu skeleton, Settings window, shared UI, docs index) belong to P0 and
then to the integrator; lanes list wanted changes in their report. Effort is in the scope page; big lanes are split
into sequential batches (R12).

### P0: Foundation

| Batch | Items | Done when |
|---|---|---|
| **P0-1** (first, alone) | Repo skeleton (Package.swift with every target, `build.sh`, `test.sh`, VERSION 0.1.0, LICENSE, NOTICE, README stub, CLAUDE.md, AGENTS.md, .gitignore, .gitleaks.toml, CI), `scripts/build-mariadb.sh` with the shared vendor cache, `CMariaDB`, bundling and signing of the dylib | `./build.sh --native` builds a signed app that links libmariadb; `codesign --verify --deep --strict` passes; CI green |
| **P0-2** Driver | `DBConnection`, `ResultStore`, session model, `SQLQuote`, cancel with tag + uuid check, SQL log with masking, `ErrorMapping`, restricted auth, TLS verification against the real host name + fingerprint pinning, reconnect semantics | Connects to every lab server with every login method; TLS name check passes through the bastion and fails for the wrong-name cert; hostile quoting tests pass; cancel only kills its own statement |
| **P0-3** Lab and routes harness | `testenv/` (all servers, bastion, jump, proxies, ProxySQL, netem, CA), `up.sh`/`down.sh`, `AGENT.md`, ported throwaway sshd and fake proxies for CI | `testenv/up.sh` is idempotent; each server reachable only by its route |
| **P0-4** SQL text core | `SQLLexer`, splitter, classifier with the attack corpus, formatter token-safety test harness | Corpus refused; DELIMITER and executable comments handled |
| **P0-5** App shell and shared UI | Everything in §2.4 frozen list, Themes (Porcelain, Deep Water, radius and spacing scale), connection store + Keychain (in-memory under tests), `Activity`, safety-settings model, SQL preview sheet with `ChangeSQL` hook, Settings panes, `HelpTests`, `InteractionTests` and `LayoutTests` scaffolds, harness port | App launches; every menu item has a tooltip; harness can snapshot, screenshot, click, double-click, right-click |
| **P0-6** Grid spike | `DataGridView`, `GridSource` + embedding API, selection and keyboard basics, editor overlay, accessibility table | grid-spec §8 targets met (frame rate on this Mac, deterministic numbers in CI), or the fallback recorded |
| **P0-7** Schema cache | `SchemaCache` types, names-first introspection with the table threshold, schema hash, targeted refresh | Correct on every lab flavour; 5,000-table server stays within the threshold behaviour |

P0-2 to P0-7 run in parallel after P0-1.

### Wave 1 (parallel)

| Lane | Scope rows |
|---|---|
| **L1 Connections and routes** | Connection editor (General, TLS, SSH and Proxy, Options, Agents tabs), all routes with sockets, jump chains, Trust sheet, logins, read-only, startup SQL, compression, database filter, `~/.ssh/config` import, connecting progress per hop |
| **L2 Grid view** | Grid "understand" group: headers, aggregates, column summary, value panel, record view, Transpose, display types, heatmap, view as text/tree, charts (pie hidden with a reason on macOS 13: `SectorMark` needs 14), `TableViewSettings`, go to row, column list, performance tests |
| **L3a Grid data** | Filter/sort/search group, `PendingChanges` + Apply with the affected-row checks, crash persistence, all copy and export formats (shared by L6), multi-cell edit |
| **L4 Console** | Console group, completion, run/cancel, result tabs, Tx, safety prompts, history, SQL log viewer, formatter, helpers panel, EXPLAIN table + tree, profile, tab restore, editor drag and drop |
| **L5a Navigator** | Tree with the click contract and drag source, database view, create/drop database, rename/truncate/drop, copy table, bulk editor, maintenance, find text on server, process list |

### Wave 2 (parallel)

| Lane | Scope rows |
|---|---|
| **L3b Grid editing** | Typed editors (date/time, JSON, ENUM/SET, BIT, text, hex), auto-generated values, Insert Value, FK drop-down and related rows, virtual FKs, paste from Excel (locale-aware numbers and dates), inner-JOIN result editing where every table's key is present (others refused with a reason, R15), Edit as Table |
| **L5b Editors** | Table editor (columns, indexes, FKs, checks, options, live ALTER), object editors as CREATE code, ER diagram (tables layered by foreign key, no edge routing, R15) |
| **L6 Client tools and transfer** | Client tools group, restore scanning, built-in SQL export, copy to another server, CSV import, run a .sql file |
| **L7a Agent tools** | MCP server, access levels, `context`, `get_schema`, `describe`, `run_queries` (incl. `to_file`), `profile`, `explain`, `open_in_console`, `read_console`, resources, activity list, Claude Code plugin, Gemini CLI setup, mcpb |
| **L8a Recon** | Compare and reconcile group, result-grid compare |

### Wave 3 (parallel)

| Lane | Scope rows |
|---|---|
| **L7b Agent UI driving and gate** | UI-driving tools, the fail-closed gate across every write path, person-only settings, redaction, paste gate, `AgentGuide.md` covering every screen |
| **L8b Liquibase** | Liquibase group, "Save as changeset" behind the preview sheet's hook and in the console |
| **Polish pass** | Every screen against the mockups and §2.13; copy and tooltip audit; empty states; the busy-indicator rule checked screen by screen |

### Wave 4: Ship

Docs site (task-first pages, screenshots light and dark from neutral demo data), README, SECURITY.md, CONTRIBUTING.md,
`scripts/llms.sh`, SBOM, release workflow (sign, notarize, staple, SHA-256, provenance, Connector/C source attached),
Homebrew cask in `kleash/homebrew-tap`, full lab run on every server, a fresh-account install test.

## 5. How each wave runs (fast, few tokens, no cut corners)

1. **Implement:** one agent per lane (Opus 5.5, max effort), each in its own worktree
   (`../airsql-wt-<lane>`, branch `lane/<lane>`). It reads this plan, the grid spec and the AirSCP files it ports,
   implements its rows as one batch with tests and docs, and commits as it goes.
2. **Verify once per lane:** zero-warning build, `./test.sh`, its lab tests, its interaction and layout tests, and
   light/dark screenshots of each new screen. A lane that runs out of room returns a report of rows done and not
   done; a continuation agent picks up from the branch.
3. **Review once per wave, not per lane:** three reviewers over the whole wave's diff, each with one lens:
   (a) security and data safety, (b) UI/UX polish and native feel (looks at every screenshot), (c) correctness,
   simplicity and over-engineering. Findings go back to the lane agents as one batch of fixes, then are re-checked
   once.
4. **Integrate (orchestrator):** merge lanes in a fixed order, full test run and the local lab, frame-rate check,
   look at the screenshots, reject anything over-engineered, push, wait for CI.

Small cross-lane fixes found in review (copy, tooltips, menu wiring) are applied by the integrator in one commit per
wave.

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Custom grid misses targets | Spike gate in P0; fallback recorded |
| TLS verification through tunnels | P0-2 proves the callback or adds a small patch; lab certificates test both outcomes |
| libmariadb build with Command Line Tools | P0-1 first; CMake pinned like AirSCP's FreeRDP script; vendor cache shared by worktrees |
| Agent writes or reads beyond access | Fail-closed gate in `DBConnection`, person-only settings, redaction, attack corpus |
| Data loss from Apply, reconnect, restore, sync | Affected-row checks, own sessions, no silent reconnect, dump scanning, opt-in destructive steps |
| Load on production at connect | Names first, details lazily above a threshold, statistics only for the viewed database |
| Merge conflicts between lanes | Frozen shared UI and models in P0, per-lane menu and settings files, integrator owns shared files |
| Lane too large for one agent | Split batches; reports list rows done and not done; continuation agents |
| No Docker on GitHub macOS runners | Keg-only servers and ported sshd/proxies in CI; full lab locally before each wave merges |
