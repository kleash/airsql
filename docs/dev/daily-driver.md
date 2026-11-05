# From working client to daily driver

Why AirSQL still feels like a proof of concept next to DataGrip and HeidiSQL, and the plan to fix it. Researched in
November 2026 against DataGrip 2026.2.4 (its bundled action list, settings, inspections and tips, plus use of the app on
the lab) and HeidiSQL (the full source at master; not run). Every gap is in
[daily-driver-backlog.md](daily-driver-backlog.md): 800 rows, each with a phase.

## Why it feels like a POC

AirSQL has more features than it shows. Compare, safe editing, routes and charts are ahead of both tools. The gap is
mostly in how the app behaves from minute to minute. Five causes, biggest first:

1. **Actions live in menus, not beside the work.** With the same query on screen, DataGrip's result has its own toolbar
   (view, chart, reload, add and remove row, revert, submit, transaction, DDL, pin, find, compare, export format, import,
   export), a filter and sort on every column, a pager, and a tick with the time at the end of the statement. AirSQL's
   result has a tab strip and nothing to press; most of those actions exist, in a menu bar with 200-odd items.
2. **One slow query stops the connection.** All query tabs of a connection share one session, so a second tab can't run
   while the first does, and they share one transaction and one current database (`ConsoleViewController.swift`,
   `struct Shared`). No daily driver works like this.
3. **The editor is a text box with colours.** There is no duplicate, delete or move line, no toggle case, no multiple
   carets, no current-line highlight, no line and column in the status bar, no font choice. Completion matches by prefix
   only. The formatter leaves subqueries and WHERE on one line. There is no SQL parser, only a lexer, which caps
   everything smarter.
4. **Connecting leads nowhere.** HeidiSQL lands on a page of databases with sizes, then variables, status and processes.
   AirSQL shows a settings card. Nothing shows sizes at a glance, and there's no way to see variables or status at all.
5. **Rough edges where a person expects flow.** A query tab with no connection says "choose a connection" while the
   toolbar already shows one, and takes a sheet to fix. A click always opens rows, and structure is a separate tab rather
   than a switch on the same one. The SQL log is another window. Nothing tells you a long query has finished.

Density isn't the problem next to DataGrip: its grid rows are about 27 points against AirSQL's 23. HeidiSQL is likely
denser, but it wasn't run, so that's a reading of its code.

## Keep these

They're why AirSQL is worth finishing, and no phase below may weaken them: Apply with exact row checks and undo; read-only
and Production modes; every route ending in a private socket; nothing on the main thread; real compare and sync (HeidiSQL's
form isn't wired up); foreign-key lookups and labels; charts, heatmaps, Column Summary, freeze columns; agents behind the
gate; a native universal Mac app.

## The owner's three items

**Compare at every level (Phase 4).** Today it compares two databases, and a result with a table.

| Level | What it does | Work |
|---|---|---|
| Server | Two connections: pair every database by name, one summary, open any pair | New level above the current run |
| Database | Already there | None |
| Table | Any two tables, with different names or in the same database: structure and rows | Pair by chosen names, not only equal names |
| Object | Two views, routines or triggers: definitions side by side | Reuse the definition diff |

Start any of them from the tree: **Compare With…** on a selected row, or **Compare** on two selected rows. Same window,
same engine and same sync script.

**Disk usage (Phase 2).** A new **Disk Usage** view, from Tools and from the connection, database and table menus.

- Server level: every database with data, indexes, free space, rows and share, as sorted bars. Select several databases
  to compare them or total them.
- Inside a database: its tables the same way, and click through to a table's indexes and partitions.
- Filter, sort, copy and export. **Free space** links to the existing Optimize.
- Sizes come from the query the schema cache already runs (`statisticsSQL`). That query opens every table it names, so
  it runs one database at a time, in the background, with Cancel and a progress count: a server with thousands of tables
  mustn't stall.
- It says plainly that InnoDB's sizes and row counts are estimates, and that it shows only what the login can see.
- The same figures give the tree and the database view their size bars.

A treemap and growth over time can follow if the bars prove too plain.

**Double-click closes what it opened (Phase 1).** Connections, folders, databases, groups and the JSON tree all toggle on
double-click, in the code and in the real app. A table doesn't: a double-click opens its tab and doesn't expand it, which
doesn't match what was seen, so see decision 1. A harness test then walks every kind of row, so this stays true.

## Phases

Each phase ships as a release and ends with the app better to use. Counts are backlog rows; sizes are estimates.

### Phase 1: Feel (54 rows, all small)

- Result toolbar with the actions that exist already; a tick and the time at the end of each statement.
- A tab with no connection takes the window's. New tabs follow it.
- Editor basics: duplicate, delete and move line; toggle case; current line; line and column in the status bar; font
  choice; the current statement marked; next and previous statement.
- Completion: abbreviations and middle of a word; INSERT column lists; `*` expansion; aliases; name-match joins.
- Quick Open for everything (routines, triggers, tabs, commands), fuzzy; **Select in Tree** from any tab.
- Long query finished: notification and Dock bounce. Rerun a result. Copy a table's query to a tab.
- EXPLAIN ANALYZE, kept out of read-only mode as it runs the statement. Preview the rows an UPDATE or DELETE would touch.
- Page Down at the end loads more; single-click sort if decision 4 says so.
- Token-level checks: ambiguous column, INSERT value count, `= NULL`, did-you-mean.

**Done when:** the first ten minutes with AirSQL show no missing basic, checked by the owner.

### Phase 2: Server home and disk use (92 rows)

- Host page on connect: Databases with sizes, Variables, Status, Processes, Command statistics.
- Disk Usage. Size bars in the tree and the database view.
- A table tab with Data, Structure and DDL as a switch that stays chosen as you walk the tree.
- SQL log docked under the window, on by default, as in HeidiSQL. Quick Documentation for any object.
- Tree: flat mode, favourites, filters for big schemas. Opt-in reconnect at launch (decision 3).

**Done when:** a stranger can see what's on a server and where the space went without writing SQL.

### Phase 3: Sessions, results and big data (90 rows)

- A session per query tab: its own transaction and database, with several tabs running at once. Shared session stays an
  option for temp tables. Respect `max_connections`, and show how many sessions are open.
- Long values cut at the server, with Load Full Cell; hidden columns not fetched. Today one page of LONGBLOBs reads
  everything, which is a stability risk as well as a speed one.
- Real EXPLAIN tree with columns. Query parameters (`?`, `:name`). Run a subquery, or from the caret.
- Default transaction mode per connection; manual transactions in table tabs. Notice when the schema changed elsewhere.

**Done when:** a ten-minute query in one tab doesn't change how the others work, and a table of large blobs opens at once.

### Phase 4: Compare, import, users, schema (60 rows)

- Compare at every level, as above.
- Import that creates the table, with detection, preview, encoding and skipping bad rows.
- Users, roles and grants (decision 2).
- ER diagrams of chosen tables, with boxes you can move and layouts that save.

**Done when:** the common admin jobs no longer need another tool.

### Phase 5: Editor engine (120 rows, the largest)

- **A SQL parser for MySQL and MariaDB (XL).** It unlocks accurate completion in CTEs and subqueries, go to declaration,
  find usages, rename, real syntax errors and most inspections.
- **An editor layer over the text view (L):** multiple carets, select next occurrence, column selection, folding.
- A real formatter with rules; an Option-Return menu for fixes; snippets and live templates; local history of files.

**Done when:** a daily DataGrip user doesn't reach for it to write SQL.

### Phase 6: Workspace (29 rows)

Several main windows, split editors, a file tree, keymaps, and AI in the editor beyond today's agents.

### Later, or a decision first (355 rows)

Low daily value, or against a rule. They stay listed so nothing's lost.

## Decisions for the owner

1. **Double-clicking a table.** It opens the table's tab, and only the arrow expands it. Which row did you see expand?
   Recommendation: keep double-click opening the tab, as in DataGrip.
2. **Reversing "Skip" in `scope.html`.** Users, server variables, snippets, favourites and bind parameters were skipped.
   The research says all five matter. Recommendation: reverse them all, and update `scope.html`.
3. **Reconnecting at launch.** The rule is no silent reconnect. Recommendation: opt-in per connection, never for
   Production.
4. **Sort on a single header click.** HeidiSQL does it; today a click selects the column. Recommendation: use a sort
   arrow in the header, as DataGrip does, so a click still selects.
5. **HeidiSQL's auto-save on leaving a row.** It's the most direct edit there is, and it breaks "nothing is written
   without Apply". Recommendation: don't add it. ⌘S already applies.
6. **The parser.** It's the largest single item. Recommendation: build it, after Phases 1 to 3, as those need no parser.

## Not doing

Other engines (Oracle, SQL Server, Postgres, Mongo and the rest); JVM and IDE plumbing; VCS inside the app; a built-in
terminal; DDL data sources. HeidiSQL's Windows-only features.

## How far to trust this

- Value and size marks are judgement, and "missing" often rests on an empty code search. The claims behind the top gaps
  were checked by hand; the other rows weren't.
- HeidiSQL wasn't run, and its macOS build may lack some of what its Windows code has.
- Hands-on DataGrip use covered connecting, a console and a result. Its table tab, EXPLAIN view and context menus weren't
  seen in use; those rows come from its bundle and help.
- The same feature under two names can appear twice in the backlog.
