# Daily-driver backlog

Every gap found in DataGrip 2026.2.4 and HeidiSQL (master, November 2026) against AirSQL, by phase. The plan is
[daily-driver.md](daily-driver.md). **Value:** H, M, L, how much someone who lives in the tool feels it. **Size:** S under a
day, M a few days, L a week or two, XL more. **State:** P partial, M missing. Both are estimates. A mark after a name:
`ok?` reverses a Skip in `scope.html`; `design` goes against a safety rule. Rows of the same name are merged, but the same
feature under two names can still appear twice.

## Phase 1: Feel (54)

### Editing and completion (29)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Abbreviation matching | `fica` finds `film_category`; `ob` gives ORDER BY | M | H | S | DataGrip |
| Ambiguous column | `id` in two joined tables | M | H | S | DataGrip |
| Auto table alias | `orders` becomes `orders o` | P | H | S | DataGrip |
| Column list in INSERT | `INSERT INTO t (` offers the whole list | M | H | S | DataGrip |
| Current line highlight | Band on the caret line | M | H | S | DataGrip |
| Current statement marked | Statement at the caret shaded | M | H | S | DataGrip |
| DELETE/UPDATE without WHERE | Marked while typing | P | H | S | DataGrip |
| Delete line | ⌘⌫ | M | H | S | DataGrip |
| Duplicate line | ⌘D / ⌃D | M | H | S | DataGrip |
| Expand column list | `*` becomes the columns | M | H | S | DataGrip |
| Font family | Choose the font | M | H | S | DataGrip |
| Highlight usages at caret | Same name marked in the file | M | H | S | DataGrip |
| INSERT value count | Values don't match columns | M | H | S | DataGrip |
| Middle-of-word match | `cust` finds `old_customers` | M | H | S | DataGrip |
| Move line | ⌥⇧↑↓ | M | H | S | DataGrip |
| Move line up or down | Alt+↑, Alt+↓ | M | H | S | HeidiSQL |
| NULL comparison | `= NULL`; fix to `IS NULL` | M | H | S | DataGrip |
| Name-match joins | Suggest joins by column names like `customer_id` | M | H | S | DataGrip |
| Parameter info | Shows arguments while inside a call | M | H | S | DataGrip |
| Preview DELETE rows | Shows rows the DELETE would hit | M | H | S | DataGrip |
| Preview UPDATE rows | Shows rows the UPDATE would hit | M | H | S | DataGrip |
| Quick-fix: did you mean | Closest name for a typo | M | H | S | DataGrip |
| Saved snippets panel | Keep reusable queries | M | H | S | DataGrip |
| Shrink selection | ⌥↓ | M | H | S | DataGrip |
| Toggle case | ⌃⇧U on selection | M | H | S | DataGrip |
| VALUES info | Which column this value is for | M | H | S | DataGrip |
| Word case rules | Keywords, types, functions, identifiers, aliases each | P | H | S | DataGrip |
| `SELECT *` expansion in popup | Offers all columns | M | H | S | DataGrip |
| `sel` `selw` `selc` `lim` `ins` `upd` `del` `tab` `view` `col` | The ten MySQL-relevant built-ins (`top` `first` `toprow` are other engines) | M | H | S | DataGrip |

### Running and results (3)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Explain Analyse | Runs and shows actual rows and time | M | H | S | DataGrip |
| Long-query notification | System notice when a slow query ends | M | H | S | DataGrip |
| Rerun last result | Reload a result tab by re-running its query | M | H | S | DataGrip |

### Data grid (4)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Copy Query to Console or Clipboard | Take the tab's SELECT, with filter and sort, into a console | M | H | S | DataGrip |
| Page Down at end loads more | Grid grows as you move; Ctrl+End loads all | M | H | S | HeidiSQL |
| Sort by numeric key | Open in PK order, or reversed | P | H | S | DataGrip |
| Sort by single header click | ASC, DESC, off | P | H | S | HeidiSQL |

### Tree and navigation (12)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Favourites `ok?` | Star at row edge; favourites only button | M | H | S | HeidiSQL |
| Flat object list | Default is no grouping | P | H | S | HeidiSQL |
| Fuzzy in Go To | `fica` finds `film_category` | M | H | S | DataGrip |
| Go to DDL | Show the object's CREATE | P | H | S | DataGrip |
| Go to Database Object | Find any object by name, abbreviations too | P | H | S | DataGrip |
| Go to object | Search tables, views, routines | P | H | S | DataGrip |
| Next/previous statement | Jump by statement | M | H | S | DataGrip |
| Open table data from a name | ⌘↓/F4 from a name in the editor | M | H | S | DataGrip |
| Select current statement | One key | M | H | S | DataGrip |
| Select in Explorer | Reveal the tab's object in the tree | M | H | S | DataGrip |
| Select in tree | From editor to sidebar | M | H | S | DataGrip |
| Structure popup | Outline of statements in the file | M | H | S | DataGrip |

### Server home and disk use (2)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Processes in the host page | List without opening anything | P | H | S | HeidiSQL |
| Row and size bars | Largest tables stand out at once | M | H | S | HeidiSQL |

### Schema tools (1)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| CREATE code tab | Always-there CREATE of the table | P | H | S | HeidiSQL |

### Connections and settings (2)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Editor font | Name and size | P | H | S | HeidiSQL |
| Long query done | Tell me when it ends while I'm elsewhere | M | H | S | DataGrip |

### Workspace (1)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Find Action | Search every command by name | P | H | S | DataGrip |

## Phase 2: Server home and disk use (92)

### Tree and navigation (41)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Find in files | Across files and tabs | M | H | M | DataGrip |
| Go to declaration | ⌘-click/⌘B on a table, column, alias | M | H | M | DataGrip |
| Quick Documentation | Popup: columns, keys, comment, first rows | P | H | M | DataGrip |
| Search Everywhere | One box: objects, files, actions | P | H | M | DataGrip |
| Size column with bars | Size per table, totals per db and server | M | H | M | HeidiSQL |
| Autoscroll from editor | Tree follows the active tab | M | M | S | DataGrip |
| Back / Forward | Return to where you were | M | M | S | DataGrip |
| Back and Forward between tabs | Navigate history | M | M | S | DataGrip |
| Bookmarks | Mark lines, list them | M | M | S | DataGrip |
| Database and table filters | Two boxes, regex, recent list | P | M | S | HeidiSQL |
| Drag a table to copy it | Drop on a schema: Copy dialog | M | M | S | DataGrip |
| Drag into editor | Shift adds db prefix | P | M | S | HeidiSQL |
| Drop primary or foreign key | One action on a node | P | M | S | DataGrip |
| Filter by object kind | Show or hide tables, routines… | M | M | S | DataGrip |
| Find Action | Search every command | P | M | S | DataGrip |
| Go to file | Open a file by name | M | M | S | DataGrip |
| Line and column in status bar | Caret place | M | M | S | DataGrip |
| Manual order | Move connections up or down | M | M | S | DataGrip |
| Modify Comment | Change a comment from the tree | P | M | S | DataGrip |
| New column, index or key on a table | Right-click add | P | M | S | DataGrip |
| Object bookmarks | Bookmark tables and more | M | M | S | DataGrip |
| Open the group as a list | F4 on Tables shows a table of them | P | M | S | DataGrip |
| Pick databases shown | N of M schemas popup in the tree | P | M | S | DataGrip |
| Quick Definition | Peek at DDL without leaving | M | M | S | DataGrip |
| Recent files | Popup of recent | P | M | S | DataGrip |
| Recent tabs switcher | ⌃Tab with a popup, Recent Files | P | M | S | DataGrip |
| Select all matches | From find to carets | M | M | S | DataGrip |
| Show comments in tree | Comment or refresh time beside the node | P | M | S | DataGrip |
| Structure tool window | Outline kept open, filter, run | M | M | S | DataGrip |
| Subfolders | Folders in folders | M | M | S | DataGrip |
| Switcher | ⌃⇥ popup, most recent first | P | M | S | DataGrip |
| Whole word, in selection | Find options | M | M | S | DataGrip |
| Colours on any node | Colour a data source, folder or object; custom hue; apply to children | P | M | M | DataGrip |
| Favourites and bookmarks | Mark objects to return to | M | M | M | DataGrip |
| Find Usages | What uses this table or column | M | M | M | DataGrip |
| Go to symbol | Find any name in files and schema | M | M | M | DataGrip |
| Group by name prefix | `wp_*` folded into a group | M | M | M | DataGrip |
| Object name filter in settings | Hide objects by pattern | M | M | M | DataGrip |
| Replace in files | Same | M | M | M | DataGrip |
| Run routine | Dialog for parameters, then run | P | M | M | DataGrip |
| Rename | Rename object and its usages | P | M | L | DataGrip |

### Server home and disk use (17)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Databases list | Size, items, last change, count per kind, collation | M | H | M | HeidiSQL |
| Status counters | Value, avg per hour, avg per second | M | H | M | HeidiSQL |
| Variables `ok?` | All variables, session and global side by side | M | H | M | HeidiSQL |
| Host tab on connection click | Live server page shown without asking | M | H | L | HeidiSQL |
| 19 columns | Adds created, version, row format, avg row, max data, data free, auto increment, check time, checksum, create options, type | P | M | S | HeidiSQL |
| All object kinds in the list | Tables, views, routines, triggers, events, with Type column | P | M | S | HeidiSQL |
| Bars in list columns | Value as a bar: size, %, time | M | M | S | HeidiSQL |
| Command statistics | Count, per hour, per second, % of each Com_ | M | M | S | HeidiSQL |
| Copy table | Choose columns, keys, FKs, data, WHERE with recent filters | P | M | S | HeidiSQL |
| Edit a variable `ok?` | Set by type, session or global, with Help | M | M | S | HeidiSQL |
| One Size column | Data plus index | P | M | S | HeidiSQL |
| Process SQL pane | Selected process's SQL always visible below | P | M | S | HeidiSQL |
| Regex filter on any list | Filter bar with "n of m" for each list | P | M | S | HeidiSQL |
| Run routines | Prompts for each parameter and runs | P | M | S | HeidiSQL |
| Select top 1000 rows | SELECT in a new query tab | P | M | S | HeidiSQL |
| Show or hide list columns | Header menu on every list | M | M | S | HeidiSQL |
| Edit database | Change collation, rename by moving tables | M | M | M | HeidiSQL |

### Connections and settings (34)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Auto-disconnect | Close after idle | M | M | S | DataGrip |
| Colours shown where | Tree, tab, editor background, toolbar | P | M | S | DataGrip |
| Command line switches | -d, -h, -u, -P, -db, files to open | M | M | S | HeidiSQL |
| Connection-level warnings | Problems list per source | P | M | S | DataGrip |
| Copy, cut, paste data sources | Clipboard as XML | P | M | S | DataGrip |
| Ctrl+1-5 main tabs | Host, Database, Table, Data, Query | P | M | S | HeidiSQL |
| Driver properties | Key-value options | P | M | S | DataGrip |
| Event Log | History of notices | M | M | S | DataGrip |
| Expired password change | Dialog sets a new password at login | M | M | S | HeidiSQL |
| F5 refresh, Shift+F5 full | Refresh | P | M | S | HeidiSQL |
| F9 family | Run, Ctrl+F9 selection, Shift+Ctrl+F9 current | P | M | S | HeidiSQL |
| File ▸ Connect to | Sessions in a menu | P | M | S | HeidiSQL |
| Grid font | Name and size | P | M | S | HeidiSQL |
| History of removed sources | Bring back a deleted one | M | M | S | DataGrip |
| Introspection levels | 1-3, per schema, auto-selected | P | M | S | DataGrip |
| Local number format | 1,234.5 by default | P | M | S | HeidiSQL |
| Log events | Errors, user SQL, internal SQL, info, debug, script | P | M | S | HeidiSQL |
| Outdated notification | Warn when the object changed since read | M | M | S | DataGrip |
| Quick filter keys | Shift+Ctrl+1-6 | P | M | S | HeidiSQL |
| Restore last database | Back in the db you left | P | M | S | HeidiSQL |
| Session colour on tree | Whole tree of the session tinted; result tabs too | P | M | S | HeidiSQL |
| Session list columns | Host, port, user, version, last connect, counter, comment, sortable | P | M | S | HeidiSQL |
| Snippets folder | Own folder | M | M | S | HeidiSQL |
| Tab names | Template, shorten source and object names | P | M | S | DataGrip |
| Tab width, tabs to spaces | Editor | M | M | S | HeidiSQL |
| Time zone | Connection's zone | P | M | S | DataGrip |
| Transaction control | Default mode and isolation | M | M | S | DataGrip |
| CSV formats pane | Edit formats centrally | M | M | M | DataGrip |
| Detect others' changes | Timed introspection | M | M | M | DataGrip |
| Schema cached on disk | Instant tree, browse while offline | M | M | M | DataGrip |
| Shared SSH configs | One config, many sources | P | M | M | DataGrip |
| Shortcuts | Rebind any action, two per action | M | M | M | HeidiSQL |
| Syntax colours, presets | Each element, bold, italic | M | M | M | HeidiSQL |
| New window | A second window or instance | M | M | L | HeidiSQL |

## Phase 3: Sessions, results and big data (90)

### Running and results (41)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Attached folders / Files tool window | Tree of folders of .sql scripts next to the database tree | M | H | M | DataGrip |
| Local history of files | Every saved state of a file, diff, restore | M | H | M | DataGrip |
| Named params by pattern | `:id`, `#{id}`, `${x}` by regex, same name one value | M | H | M | DataGrip |
| Operations tree with columns | Sortable tree: operation, rows, cost, actual time | P | H | M | DataGrip |
| Positional `?` | Asks a value for each `?` on run | M | H | M | DataGrip |
| Smallest subquery | Caret inside a subquery runs just the subquery | M | H | M | DataGrip |
| Attach file to source and keep it | File remembers which source and schema it belongs to across sessions | P | M | S | DataGrip |
| Auto-refresh a result | Re-run every n seconds | P | M | S | DataGrip |
| Console list / jump | Popup listing every console of a source, new or existing | M | M | S | DataGrip |
| Copy original plan | Copy JSON/XML | P | M | S | DataGrip |
| Copy query of a result | From result back to the console | P | M | S | DataGrip |
| Default console per data source | One remembered console opens for each source, kept for ever | M | M | S | DataGrip |
| Error during a script | Dialog: Retry, Skip, Skip All, Stop | P | M | S | DataGrip |
| Everything from caret | Run from here to the end | M | M | S | DataGrip |
| Execution targets | Caret inside, outside, selection; shortcut sets | P | M | S | DataGrip |
| File encodings | Open and save other encodings, BOM | M | M | S | DataGrip |
| History across connections | One search over everything | M | M | S | DataGrip |
| Hot-spot marks | Costly nodes coloured | M | M | S | DataGrip |
| New tab per run | Setting: never replace | M | M | S | DataGrip |
| Open results in new tab | New tab per run | P | M | S | DataGrip |
| Output log | Timestamped log of what ran | P | M | S | DataGrip |
| Raw plan | The server's own output | P | M | S | DataGrip |
| Reload on external change | File edited elsewhere is noticed | M | M | S | DataGrip |
| Results title from comment | Name a result by a comment | M | M | S | DataGrip |
| Scratch files | Throwaway files outside any project, any language | P | M | S | DataGrip |
| Selection as one statement | Send selection unsplit | M | M | S | DataGrip |
| Tab colour by connection | Tab/editor tinted with the source colour | P | M | S | DataGrip |
| Three run shortcuts with own rules | Execute (2), (3) with different settings | M | M | S | DataGrip |
| Flame graph | Cost flame graph, startup or total | M | M | M | DataGrip |
| Result in own window | Detach | M | M | M | DataGrip |
| Row cap | Limit page and fetch | P | M | M | DataGrip |
| Row details pane | Properties of the selected node | M | M | M | DataGrip |
| Run from gutter | Run icon and progress beside the statement | M | M | M | DataGrip |
| Run routine with a form | Dialog for arguments | P | M | M | DataGrip |
| Run to file | SELECT streams straight to CSV/JSON… without a grid | P | M | M | DataGrip |
| Scripts run from the file tree | Right-click file or folder: run on a source | P | M | M | DataGrip |
| Time in the editor | Duration shown next to the statement after it runs | M | M | M | DataGrip |
| View Parameters panel | Panel to edit values, kept between runs | M | M | M | DataGrip |
| In-editor results | Results shown under the query in the text | M | M | L | DataGrip |
| Plan diagram | Plan as a node graph | M | M | L | DataGrip |
| Show results in editor | Inline results | M | M | L | DataGrip |

### Sessions and transactions (9)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Schema switcher per console | Database chosen for this tab only | P | H | M | DataGrip |
| Per-console transaction | Each console its own | M | H | L | DataGrip |
| Session control mode | Shared, two, or dedicated per client | P | H | L | DataGrip |
| Session per console | Each console can have its own connection | M | H | L | DataGrip |
| Default mode per source | New sessions start Manual and at a level | M | M | S | DataGrip |
| Default tx mode per connection | Auto or manual set on the data source | M | M | S | DataGrip |
| USE in a script followed | Script mode: `USE` changes resolution below it | P | M | S | DataGrip |
| Sessions list | Sessions and clients under each source | M | M | M | DataGrip |
| Manual transaction in the data editor | Submit into an open tx, then commit or roll back | M | M | L | DataGrip |

### Data grid (40)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Long values cut at the server | LEFT(col,256), rest fetched on demand | M | H | M | HeidiSQL |
| Max bytes per value | Cap LOBs | M | H | L | DataGrip |
| Max bytes per value and Load Full Cell | Cap big cells, fetch whole on demand | M | H | L | DataGrip |
| Any SQL expression in a cell | Edit as expression, sent unquoted | P | M | S | DataGrip |
| Auto-detect binary | Spot UUID or text in bytes | M | M | S | DataGrip |
| Auto-refresh | Re-run on a timer; custom interval, pause | P | M | S | DataGrip |
| Change page size in a tab | Page size popup on the grid, all rows option | M | M | S | DataGrip |
| Compare cells | Diff two selected cells | M | M | S | DataGrip |
| Custom font | Grid font | M | M | S | DataGrip |
| Date and time formats | Patterns per type | P | M | S | DataGrip |
| Detect binary | Auto display | M | M | S | DataGrip |
| Export preview | See the output before writing | M | M | S | DataGrip |
| Hidden columns not fetched | Column selection trims the SELECT | P | M | S | HeidiSQL |
| Hide other columns | Keep only the selection | M | M | S | DataGrip |
| Local regex filter | Ctrl+Alt+F hides rows | P | M | S | HeidiSQL |
| ORDER BY box | Type any ORDER BY, expressions included | M | M | S | DataGrip |
| One-row, Pretty table | `a, b, c` list; ASCII table | M | M | S | DataGrip |
| Open URL | Cell value in browser | M | M | S | HeidiSQL |
| Open URL in cell | Click a URL or file path | M | M | S | DataGrip |
| Reset view | Put columns, sort and filter back to defaults | M | M | S | DataGrip |
| Rows in preview | Quick Doc's rows | M | M | S | DataGrip |
| SQL function in a cell | Ctrl+F2, any function or expression | P | M | S | HeidiSQL |
| SQL multi-row INSERT | One INSERT, many rows | M | M | S | DataGrip |
| Swapped UUID | MySQL's UUID_TO_BIN(x,1) order | M | M | S | DataGrip |
| Time zone for temporal data | Show in a chosen zone | P | M | S | DataGrip |
| View Query | Show the SELECT the tab runs | M | M | S | DataGrip |
| Back and forward | Return along the path you followed | M | M | M | DataGrip |
| Column statistics panel | Compact or detailed stats per column | P | M | M | DataGrip |
| Compare data | Table with table, or result with another | P | M | M | DataGrip |
| Custom CSV formats | Name your own separators, quoting, NULL text, prefix | M | M | M | DataGrip |
| First and last page | Jump to the table's start or end | M | M | M | DataGrip |
| Full-text search across tables | Search many tables, with mode and limits, results listed | P | M | M | DataGrip |
| Grid rows of several lines | Lines of text per row | M | M | M | HeidiSQL |
| Highlighting language | SQL, XML, HTML, JSON colouring per cell or column | M | M | M | DataGrip |
| Hover preview of the row | Quick Doc on a key cell | P | M | M | DataGrip |
| Local filter per column | Funnel on each column, on loaded rows, no query | P | M | M | DataGrip |
| Next and previous page | Step page by page, replacing the rows shown | P | M | M | DataGrip |
| Spatial values as text | WKT instead of bytes | M | M | M | DataGrip |
| Text editor popup | Wrap, line break style, load file, highlighter (SQL, JSON, XML...), format | P | M | M | HeidiSQL |
| Edit a CSV file as a table | Open a .csv in the grid, edit, save | M | M | L | DataGrip |

## Phase 4: Compare, import, users, schema (60)

### Schema tools (21)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Diagram of selected tables | Only what you pick, drag more in | M | H | M | DataGrip |
| Move boxes, keep positions | Drag, save | M | H | M | DataGrip |
| Sticky Table/Data/Query tabs | Clicking another table keeps the tab you were on | M | H | M | HeidiSQL |
| Structure one click from data | Same object, tab strip | P | H | M | HeidiSQL |
| DDL to a console | Generate into a query tab | M | M | S | DataGrip |
| Export | PNG, Mermaid, PlantUML, DOT, GraphML, drawio; web editors; print | P | M | S | DataGrip |
| Generated DDL for many objects | DDL of a selection, to clipboard | M | M | S | DataGrip |
| Index from selected columns | Create new index, add to index | M | M | S | HeidiSQL |
| Index options | Type, prefix, DESC, visibility, comment | P | M | S | DataGrip |
| Indexes tree | Name, type, algorithm, comment, direction, visibility | P | M | S | HeidiSQL |
| Reverse foreign keys | Who points here | P | M | S | HeidiSQL |
| Routine parameters grid `ok?` | #, name, type, context; move up, down | M | M | S | HeidiSQL |
| Run from editor | Button | P | M | S | HeidiSQL |
| Run or paste the change | Execute, or open in console | P | M | S | DataGrip |
| Show or hide columns | Keys only, comments, virtual keys | M | M | S | DataGrip |
| File per object | Folder layout: by schema, by kind, numbered | P | M | M | DataGrip |
| Routine form `ok?` | Name, type, returns, data access, security, comment, deterministic | M | M | M | HeidiSQL |
| SQL Generator window | Live DDL with options | M | M | M | DataGrip |
| Show neighbours | A table and what touches it | M | M | M | DataGrip |
| Layouts | Several, orientation, re-run | M | M | L | DataGrip |
| Partitions | View, add, change | M | M | L | DataGrip + HeidiSQL |

### Compare, import, export (30)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Detect layout, create table | Scan file, propose CREATE TABLE | M | H | M | HeidiSQL |
| Import into a new table | Create the table from the file, editable DDL | M | H | M | DataGrip |
| Compare two objects | Two tables or routines, select and go | P | M | S | DataGrip |
| Create and drop flags | For databases and tables separately | P | M | S | HeidiSQL |
| Data modes | None, delete+insert, insert, insert ignore, replace | P | M | S | HeidiSQL |
| Data preview | Rows before running | P | M | S | DataGrip |
| Duplicates | INSERT, IGNORE, REPLACE | M | M | S | HeidiSQL |
| Encoding choice | For the file | M | M | S | HeidiSQL |
| Encoding of the file | UTF-8 and others, BOM | M | M | S | HeidiSQL |
| Errors to a file, keep going | Skip bad rows, write them out | M | M | S | DataGrip |
| Find case sensitivity | Checkbox | M | M | S | HeidiSQL |
| Find match types | Wildcards, exact, regex | M | M | S | HeidiSQL |
| Flush | Hosts, logs, privileges, tables, read lock, status | M | M | S | HeidiSQL |
| Format options | Any delimiter, quote, row prefix, trim | P | M | S | DataGrip |
| Ignore options | Case, owner, DEFINER, order, source code, implicit objects | P | M | S | DataGrip |
| Import from clipboard | Paste rows as a new table | P | M | S | DataGrip |
| Output one file per object | Directory | M | M | S | HeidiSQL |
| Output to clipboard | Small dumps | M | M | S | HeidiSQL |
| Remove DEFINER, AUTO_INCREMENT | Export options | M | M | S | HeidiSQL |
| Separator, encloser, terminator | Free choice with presets | P | M | S | HeidiSQL |
| Source encoding | Choose a charset | P | M | S | DataGrip |
| Check for updates `ok?` | Daily, nightly builds | M | M | M | HeidiSQL |
| Copy a result into a table | Query result to an existing or new table | M | M | M | DataGrip |
| Diff viewer controls | Next difference, unified, word level, whitespace modes | P | M | M | DataGrip |
| Export tables to files | Several tables, one file each, chosen extractor | P | M | M | DataGrip |
| Include or exclude each change | Tick per change | P | M | M | DataGrip |
| Compare with a DDL file or VCS state | Against a script set | M | M | L | DataGrip |
| Excel, JSON and other files | Import xlsx, JSON… | M | M | L | DataGrip |
| DDL data source | Folder of .sql files as a source | M | M | XL | DataGrip |
| DDL mapping | Link a live source and files; push or pull | M | M | XL | DataGrip |

### Users and grants (9)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Create or alter user `ok?` | Password, host, limits, plugin | M | H | L | DataGrip |
| Modify Grants | Tick privileges for an object | M | H | L | DataGrip |
| Users in the tree | Accounts and roles under Server Objects | M | H | L | DataGrip |
| Add, clone, delete | Accounts | M | M | S | HeidiSQL |
| Change expired password | Prompt on login | P | M | S | DataGrip |
| Credentials | Name, host, password, repeat, generator | M | M | S | HeidiSQL |
| Roles | MySQL 8, MariaDB roles | M | M | M | DataGrip + HeidiSQL |
| User list | Name, host, plugin, filter | M | M | M | HeidiSQL |
| Privilege tree | Global, db, table, column, routine; read/write/admin colours | M | M | L | HeidiSQL |

## Phase 5: Editor engine (120)

### Editing and completion (120)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Caret per selected line | ⌥⇧G | M | H | S | DataGrip |
| Select all occurrences | ⌃⌘G | M | H | S | DataGrip |
| AND/OR on lines | Conditions broken | M | H | M | DataGrip |
| Alt+Enter menu | Fixes and intentions at the caret | M | H | M | DataGrip |
| Column not in GROUP BY | Would fail under ONLY_FULL_GROUP_BY | M | H | M | DataGrip |
| Column selection | ⇧⌘8 mode, ⌥-drag | P | H | M | DataGrip + HeidiSQL |
| Context-aware keywords | Only what grammar allows here | M | H | M | DataGrip |
| Extend selection | ⌥↑ grows by syntax | M | H | M | DataGrip |
| Inlay: names in INSERT values | `/* id: */ 1` hints | M | H | M | DataGrip |
| Keymaps | Rebind any command; VS Code, Sublime, Emacs sets | M | H | M | DataGrip |
| Live templates | Abbreviation plus Tab expands, with fields | M | H | M | DataGrip |
| Own templates and variables | User-defined, `$table$` fields | M | H | M | DataGrip |
| Quick documentation | F1/hover: columns, DDL, first rows | M | H | M | DataGrip |
| Rename alias in place | ⇧F6 on an alias renames its uses | M | H | M | DataGrip |
| SELECT list wrapping | One column per line, comma first or last | M | H | M | DataGrip |
| Snippets `ok?` | Saved SQL files in the panel, insert, load, rename, folder | M | H | M | HeidiSQL |
| CTE and subquery columns | Names from `WITH x` and derived tables | M | H | L | DataGrip |
| Multi-caret | ⌥⇧click, clone caret | M | H | L | DataGrip |
| Real syntax errors | Parser marks wrong SQL while typing | P | H | L | DataGrip |
| Reformat | Tidy whole file or selection | P | H | L | DataGrip |
| Select next occurrence | ⌃G adds a caret at the next match | M | H | L | DataGrip |
| Subquery indentation | Nesting indented | M | H | L | DataGrip |
| Unresolved reference | Unknown table, column, routine | P | H | L | DataGrip |
| Auto uppercase | Keywords as you type | M | M | S | HeidiSQL |
| Auto-indent on Return | Keep level | P | M | S | DataGrip |
| BEGIN/END pair highlight | Matching block words | M | M | S | DataGrip |
| Block comment | `/* */` around a selection | M | M | S | DataGrip |
| Check at run | Inspection blocks a run with a warning | P | M | S | DataGrip |
| Clipboard history | Paste from past copies | M | M | S | DataGrip |
| Compare with clipboard | Diff selection and clipboard | M | M | S | DataGrip |
| Complete statement | ⌃⇧↩ adds `)`, `;`, moves on | M | M | S | DataGrip |
| Completion matches mid-word | Option | M | M | S | HeidiSQL |
| Copy line with no selection | ⌘C copies the line | M | M | S | DataGrip |
| Custom fold regions | `-- region` | M | M | S | DataGrip |
| Delete line, case change and other editor commands | About 100 SynEdit commands, one menu | P | M | S | HeidiSQL |
| Derived table alias | Subquery in FROM needs one | M | M | S | DataGrip |
| Drop INSERT column | Remove column with its values | M | M | S | DataGrip |
| ENUM values in comparison | `status = '` offers the enum members | M | M | S | DataGrip |
| Error description | Show the problem at the caret from the keyboard | M | M | S | DataGrip |
| File encoding choice | Open and save | M | M | S | HeidiSQL |
| Find and replace dialog | Whole words, scope selection, direction, prompt, regex, history | P | M | S | HeidiSQL |
| Generate SELECT, INSERT, UPDATE, DELETE | From chosen columns | P | M | S | HeidiSQL |
| Generate in the editor | ⌘N: statements for the object at the caret | M | M | S | DataGrip |
| Helpers follow the tree | Columns of the selected table, no typing | P | M | S | HeidiSQL |
| Hint with SQL on result tab | Hover shows the query | M | M | S | HeidiSQL |
| Hippie (word) completion | Words already in the file | M | M | S | DataGrip |
| Hover hints in the editor | Function help; a table's rows, size and columns | M | M | S | HeidiSQL |
| Inspection settings | Turn each on or off, set severity | M | M | S | DataGrip |
| JOIN without ON in a write | DELETE/UPDATE join with no condition | P | M | S | DataGrip |
| Join lines | ⌃⇧J, SQL-aware | M | M | S | DataGrip |
| Keyword case | Follows code style | M | M | S | DataGrip |
| ML ranking | Sort by likelihood | P | M | S | DataGrip |
| Merge INSERTs | Many rows into one INSERT | M | M | S | DataGrip |
| Move statement | ⌃⇧↑↓, syntax-aware | M | M | S | DataGrip |
| Multi-word keywords | ORDER BY, GROUP BY, LEFT JOIN as one item | M | M | S | DataGrip |
| NULL into NOT NULL | INSERT NULL in such a column | M | M | S | DataGrip |
| Next/previous problem | F2, ⇧F2 | M | M | S | DataGrip |
| ON-clause completion | After `ON`, offer the condition | M | M | S | DataGrip |
| Paste escapes into strings | Pasted quotes escaped inside a literal | M | M | S | DataGrip |
| Presets | Default, Modern, Joe Celko, Allman, Egyptian, Whitesmiths | M | M | S | DataGrip |
| Preview of changes | Dialog before refactoring | P | M | S | DataGrip |
| Problem count widget | Errors and warnings at the top of the editor | M | M | S | DataGrip |
| Procedures after CALL | Routine names, args | M | M | S | DataGrip |
| Qualify identifier | Add table or schema | M | M | S | DataGrip |
| Query history in panel | By day, duration bars | P | M | S | HeidiSQL |
| Quick-fix: IS NULL | Rewrites `= NULL` | M | M | S | DataGrip |
| Quick-fix: add missing column | Unknown column: ALTER TABLE adds it | M | M | S | DataGrip |
| Quick-fix: qualify reference | Fix an ambiguous column | M | M | S | DataGrip |
| Quick-fix: refresh schema | Unknown name: reload | P | M | S | DataGrip |
| Quote identifier | Add backticks | M | M | S | DataGrip |
| Reload on outside change | Watches the file | M | M | S | HeidiSQL |
| Reserved word as name | `order` unquoted | M | M | S | DataGrip |
| Run SQL files directly | Several at once | P | M | S | HeidiSQL |
| Selected word marked | All occurrences tinted | M | M | S | HeidiSQL |
| Severity levels | Error red, warning yellow, weak grey | M | M | S | DataGrip |
| Sort, reverse lines | Edit menu | M | M | S | DataGrip |
| Space after function name | `COUNT (*)` fails by default | M | M | S | DataGrip |
| Spaces | Around operators, commas, brackets | M | M | S | DataGrip |
| Split INSERT | One INSERT per row | M | M | S | DataGrip |
| Stop on errors toggle | Go on past errors in a batch | P | M | S | HeidiSQL |
| Surround With | Wrap selection in a template | M | M | S | DataGrip |
| Tab size, tabs or spaces | Indent settings | M | M | S | DataGrip |
| Unqualify identifier | Remove it | M | M | S | DataGrip |
| Unquote identifier | Remove them | M | M | S | DataGrip |
| Unused CTE | WITH item never read | M | M | S | DataGrip |
| VALUES skeleton | Fills placeholders for each column | M | M | S | DataGrip |
| Variables | `@x`, `@@sql_mode`, `SET` names | M | M | S | DataGrip |
| Virtual-FK joins | Joins from user-defined keys | M | M | S | DataGrip |
| Writes on read-only connection | Marked while typing | P | M | S | DataGrip |
| Aggregate misuse | HAVING/ORDER BY columns, nested aggregates | M | M | M | DataGrip |
| Bind parameters `ok?` | `:p` values in a panel, per tab | M | M | M | HeidiSQL |
| Built-in signature | Wrong argument count or keyword | M | M | M | DataGrip |
| CASE layout | WHEN and THEN lines | M | M | M | DataGrip |
| CREATE TABLE layout | Align types, defaults | M | M | M | DataGrip |
| Colour schemes | Editable SQL colours, import themes | M | M | M | DataGrip |
| Column aliases in ORDER BY/HAVING | Offer select-list aliases | M | M | M | DataGrip |
| Compare two tabs or files | Text diff | M | M | M | DataGrip |
| Completion before FROM | Type SELECT cols first, table added after | M | M | M | DataGrip |
| Constant condition | `WHERE 'a' = 'a'` | M | M | M | DataGrip |
| Doc in popup | F1 in list shows DDL | M | M | M | DataGrip |
| Error stripe | Marks beside the scroller | M | M | M | DataGrip |
| Extract subquery as CTE | Subquery to WITH | M | M | M | DataGrip |
| Function docs | Hover a built-in | M | M | M | DataGrip |
| INSERT and VALUES layout | Rows on lines | M | M | M | DataGrip |
| Inlay: `*` columns | Shows what `*` stands for | M | M | M | DataGrip |
| Introduce table alias | Add alias and rewrite references | M | M | M | DataGrip |
| JOIN layout | Indent, ON placement | P | M | M | DataGrip |
| Join cardinality hints | `1:n` beside JOIN | M | M | M | DataGrip |
| Misleading reference | Name is both column and parameter | M | M | M | DataGrip |
| Quick definition | Popup of the object's source | M | M | M | DataGrip |
| Rename CTE, variable | Same | M | M | M | DataGrip |
| Rename object in database | Table or column, with script | P | M | M | DataGrip |
| SQL help | F1 on a word, server's HELP tables, online search | M | M | M | HeidiSQL |
| Settings with live preview | ~150 options, by dialect | M | M | M | DataGrip |
| Split editor | Two views of a file, or two tabs side by side | M | M | M | DataGrip |
| Code folding | Fold statements, subqueries, comments | M | M | L | DataGrip + HeidiSQL |
| Routine bodies | Format IF, LOOP, BEGIN | M | M | L | DataGrip |
| Full-line local AI | Greyed whole-line suggestion | M | M | XL | DataGrip |
| Type errors | Incompatible operands | M | M | XL | DataGrip |
| Vim mode | Plugin | M | M | XL | DataGrip |

## Phase 6: Workspace (29)

### Workspace (29)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| SQL log panel at the bottom | Always on, live, in the main window | P | H | M | HeidiSQL |
| Search Everywhere | One box over objects, commands, files | M | H | M | DataGrip |
| Several windows | Detach a tab, one per display | M | H | L | DataGrip |
| Split editor | Two tabs side by side | M | H | L | DataGrip |
| Text to SQL in the console | Type a request, get SQL | P | H | L | DataGrip |
| Connected time, uptime, server time | Status bar panels | M | M | S | HeidiSQL |
| Filter panel with count | "n of m shown" on any page | P | M | S | HeidiSQL |
| Fonts | UI, editor, grid | P | M | S | DataGrip |
| Line and column | Caret position panel | M | M | S | HeidiSQL |
| Log context menu | Copy line to new query tab, save, clear, log to file, open folder | P | M | S | HeidiSQL |
| Query time in status bar | Last query's duration | P | M | S | HeidiSQL |
| Tab placement and pinning | Pin a tab, tabs in rows | P | M | S | DataGrip |
| Toolbar | Everything one click: Run, Save, Find, Refresh, Export, User, Import | P | M | S | HeidiSQL |
| AI on highlighted problem | Alt+Enter: explain or fix | M | M | M | DataGrip |
| Agent writes on consent | Elicitation prompts; remembered choice | P | M | M | DataGrip |
| Attach a folder | Browse .sql files in a Files panel | M | M | M | DataGrip |
| Explain or Fix with AI on an error | Buttons on the failed query | M | M | M | DataGrip |
| Explain or refactor selection | Prompts on a selection | M | M | M | DataGrip |
| Git gutter marks | Changed lines beside the text | M | M | M | DataGrip |
| Query optimisation advice | Suggestions or rewrite | M | M | M | DataGrip |
| Scratch files, local history | Unsaved files with version history | P | M | M | DataGrip |
| Services tool window | All running queries, sessions and results in one panel | P | M | M | DataGrip |
| AI chat with @ objects | Mention tables | M | M | L | DataGrip |
| In-app AI chat | Text to SQL, explain, fix an error | M | M | L | DataGrip |
| Keymap editor | Rebind anything, presets | P | M | L | DataGrip |
| Tool windows | Dock, hide, slide, resize panels | P | M | L | DataGrip |
| Cloud completion | Multi-line suggestions | M | M | XL | DataGrip |
| Git: commit, diff, log | Version control for .sql files | M | M | XL | DataGrip |
| Projects | Separate sets of sources, consoles, settings | M | M | XL | DataGrip |

## Later, or a decision first (355)

### Editing and completion (125)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| AS rule | Add or drop AS | M | L | S | DataGrip |
| Active line tint | Colour | M | L | S | HeidiSQL |
| Add GROUP BY column to SELECT | Copies it across | M | L | S | DataGrip |
| Add NOT NULL without default | ALTER on existing rows | M | L | S | DataGrip |
| BETWEEN to comparison | Expand | M | L | S | DataGrip |
| Blank lines | Keep or set between statements | P | L | S | DataGrip |
| Bookmarks | Ctrl+Shift+0-9 | M | L | S | HeidiSQL |
| CASE vs COALESCE | Swap the two | M | L | S | DataGrip |
| CASE vs IF | Swap the two | M | L | S | DataGrip |
| Charset, collation, engine values | Values after keyword | M | L | S | DataGrip |
| Close block on Enter | BEGIN adds END | M | L | S | DataGrip |
| Close tabs to the right | Tab menu | M | L | S | HeidiSQL |
| Column name to number | ORDER BY by position | M | L | S | DataGrip |
| Comparison to BETWEEN | Collapse | M | L | S | DataGrip |
| Completion in find/filter fields | SQL completion in filters | P | L | S | DataGrip |
| Completion of server variables | `@@` and values | M | L | S | HeidiSQL |
| Concat on Enter in a string | Splits a string | M | L | S | DataGrip |
| Convert to subquery | Wrap as `SELECT … FROM (…)` | M | L | S | DataGrip |
| Copy reference | Copy file and line | M | L | S | DataGrip |
| Custom alias list | Your own alias per table | M | L | S | DataGrip |
| DISTINCT to GROUP BY | Rewrite | M | L | S | DataGrip |
| Date/time literal errors | Bad `DATE '…'` | M | L | S | DataGrip |
| Disable per range | `@formatter:off` | M | L | S | DataGrip |
| Duplicate alias | Same alias twice in SELECT | M | L | S | DataGrip |
| EditorConfig | Share style | M | L | S | DataGrip |
| Equalities to IN | `a=1 OR a=2` to `IN` | M | L | S | DataGrip |
| Flip expression | Swap operands | M | L | S | DataGrip |
| Fold selection | ⌃. | M | L | S | DataGrip |
| GROUP BY to DISTINCT | Rewrite | M | L | S | DataGrip |
| Grey-out unused code | Redundant text dimmed | M | L | S | DataGrip |
| Hide line numbers | Toggle | M | L | S | DataGrip |
| History retention | Days to keep; on or off | P | L | S | HeidiSQL |
| IN to equalities | Reverse | M | L | S | DataGrip |
| Identifier case and quoting | Follows code style | P | L | S | DataGrip |
| Indent guides | Vertical guides | M | L | S | DataGrip |
| Insert function menu | All functions by category | P | L | S | HeidiSQL |
| Insert into generated column | Values for a generated column | M | L | S | DataGrip |
| Invalid UNION | MySQL before 8.0 | M | L | S | DataGrip |
| Line spacing, ligatures | Font options | M | L | S | DataGrip |
| Max result sets | Cap of 10 | M | L | S | HeidiSQL |
| Missing RETURN | Function that returns nothing (error) | M | L | S | DataGrip |
| Missing column alias | Off | M | L | S | DataGrip |
| Move element left/right | Swap list items | M | L | S | DataGrip |
| NATURAL to ON | Rewrite join | M | L | S | DataGrip |
| NATURAL to USING | Rewrite join | M | L | S | DataGrip |
| NEW/OLD misuse | Wrong one in a trigger | M | L | S | DataGrip |
| New line before/after | Without splitting | M | L | S | DataGrip |
| New tab in background | No focus change | M | L | S | HeidiSQL |
| Not introspected schema | Current database has no details | P | L | S | DataGrip |
| Number to column name | Reverse | M | L | S | DataGrip |
| Numeric underscores | Shows `1_000_000` in big literals | M | L | S | DataGrip |
| ON to NATURAL | Rewrite join | M | L | S | DataGrip |
| ON to USING | Rewrite join | M | L | S | DataGrip |
| Post-format popup | Offer settings after formatting | M | L | S | DataGrip |
| Postfix `.afrom` | All columns, aliased | M | L | S | DataGrip |
| Postfix `.cast` | Wrap in CAST | M | L | S | DataGrip |
| Postfix `.cfrom` | All columns | M | L | S | DataGrip |
| Postfix `.from` | `orders.from` becomes `SELECT … FROM orders` | M | L | S | DataGrip |
| Postfix `.join` | Add FROM and the only JOIN | M | L | S | DataGrip |
| Qualify rule | When to prefix schema/table | M | L | S | DataGrip |
| Quick-fix: add default | For NOT NULL ALTER | M | L | S | DataGrip |
| Quick-fix: add missing table | Unknown table: create | M | L | S | DataGrip |
| Quick-fix: choose schema | Pick a database | M | L | S | DataGrip |
| Quick-fix: declare variable | In routines | M | L | S | DataGrip |
| Quick-fix: delete element | Remove unused | M | L | S | DataGrip |
| Quick-fix: first argument | Simplifies COALESCE | M | L | S | DataGrip |
| Quick-fix: increase type length | For overflowing strings | M | L | S | DataGrip |
| Quick-fix: introduce alias | For derived tables | M | L | S | DataGrip |
| Quick-fix: remove alias | For redundant ones | M | L | S | DataGrip |
| Quick-fix: replace with IF/COALESCE/CASE | Swaps forms | M | L | S | DataGrip |
| Quotation rules | Add or remove backticks | M | L | S | DataGrip |
| Reader, presentation, distraction-free | Clean views | M | L | S | DataGrip |
| Redundant ASC | ASC is the default | M | L | S | DataGrip |
| Redundant COALESCE args | After the first non-null | M | L | S | DataGrip |
| Redundant ELSE NULL | Can go | M | L | S | DataGrip |
| Redundant LIMIT | Limit that does nothing | M | L | S | DataGrip |
| Redundant alias | Alias equals the column | M | L | S | DataGrip |
| Refactor This menu | One menu of refactorings | M | L | S | DataGrip |
| Reformat on save or paste | Automatic | M | L | S | DataGrip |
| Replace vs insert | ⇥ replaces rest of word, ↩ inserts | P | L | S | DataGrip |
| Right margin | Column line | M | L | S | DataGrip |
| Rows, found, warnings, time | Log line, split query and network time | P | L | S | HeidiSQL |
| Save selection to file | Menu | M | L | S | HeidiSQL |
| Scope setting | Current schema or all | M | L | S | DataGrip |
| Send batch in one go `design` | One round trip | M | L | S | HeidiSQL |
| Set delimiter button | No DELIMITER line needed | P | L | S | HeidiSQL |
| Shadowing alias | Alias equals another column | M | L | S | DataGrip |
| Show whitespace | Dots for spaces | M | L | S | DataGrip |
| Spell check `design` | Typos in comments and strings | M | L | S | DataGrip |
| Split string literal | Break a long string | M | L | S | DataGrip |
| Store relation | Save a join as a virtual FK | M | L | S | DataGrip |
| Suppress | `-- noinspection X` per statement or file | M | L | S | DataGrip |
| TODO comments | `TODO` listed | M | L | S | DataGrip |
| Tab close by double or middle click | Options | P | L | S | HeidiSQL |
| Tilde path in LOAD | `~` in `LOAD DATA` | M | L | S | DataGrip |
| Too many JOINs | Off | M | L | S | DataGrip |
| Touch Bar | Actions | M | L | S | DataGrip |
| Transaction in trigger | COMMIT in a trigger body | M | L | S | DataGrip |
| Two AUTO_INCREMENT | CREATE TABLE with two | M | L | S | DataGrip |
| USING column missing | Column not in both tables | M | L | S | DataGrip |
| USING to NATURAL | Rewrite join | M | L | S | DataGrip |
| USING to ON | Rewrite join | M | L | S | DataGrip |
| ALTER layout | Wrap and align | M | L | M | DataGrip |
| Asterisk highlight | Caret on a column marks the `*` it comes from | M | L | M | DataGrip |
| Constant expression | Always true, false or null | M | L | M | DataGrip |
| Cursor state | FETCH on a closed cursor | M | L | M | DataGrip |
| Exit points in routines | RETURN highlighted | M | L | M | DataGrip |
| Extract variable | Expression to variable | M | L | M | DataGrip |
| Inlay: names in SELECT | Hints on `SELECT` items in unions, subqueries | M | L | M | DataGrip |
| Inlay: set operations | UNION column pairs | M | L | M | DataGrip |
| Inline | Inline variable or CTE | M | L | M | DataGrip |
| Inline CTE | WITH back to subquery | M | L | M | DataGrip |
| Inline table alias | Remove alias, rewrite | M | L | M | DataGrip |
| Problems list | All problems of a file | M | L | M | DataGrip |
| Recursive-call gutter | Marks recursion in routines | M | L | M | DataGrip |
| Source changed on server | Object differs from the local copy | M | L | M | DataGrip |
| Sticky lines | Keeps statement head visible | M | L | M | DataGrip |
| String length exceeded | Value too long for variable | M | L | M | DataGrip |
| Unreachable code | After LEAVE or RETURN | M | L | M | DataGrip |
| Unused subquery item | Columns nobody reads | M | L | M | DataGrip |
| Unused variable | Routine variable or parameter | M | L | M | DataGrip |
| Unwrap | Remove a surrounding subquery or block | M | L | M | DataGrip |
| Extract routine | Query to a function | M | L | L | DataGrip |
| Suggested refactoring | After edit, offers to update uses | M | L | L | DataGrip |
| Type of expression | Show type | M | L | L | DataGrip |

### Running and results (26)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Statement picker `design` | Popup: pick which statement or the whole script | M | M | S | DataGrip |
| Cancel escalation | Second Cancel offers to terminate; warns after 10 s | P | L | S | DataGrip |
| Caret-outside rule | Choose what runs when caret is between statements | P | L | S | DataGrip |
| Context templates target | New console or append | P | L | S | DataGrip |
| Dialect per file | Set the SQL dialect of a file | P | L | S | DataGrip |
| Inside strings too | Substitute inside SQL strings | M | L | S | DataGrip |
| Internal sessions | Show them | M | L | S | DataGrip |
| Large file handling | Over 20 MB shows the first 2.5 MB, suggests run configuration | P | L | S | DataGrip |
| Line separators | See and change CRLF/LF | M | L | S | DataGrip |
| Log presets | Choose what goes in | P | L | S | DataGrip |
| Query files folder | New query files go to a chosen directory | M | L | S | DataGrip |
| Read-only lock on a file | Toggle file read-only | M | L | S | DataGrip |
| Review before run | Always show values first | M | L | S | DataGrip |
| Review parameters | Prompt before running | M | L | S | DataGrip |
| Run from Structure | Pick statements in the outline, Execute | M | L | S | DataGrip |
| Scope switches | Enable in consoles, in injected strings | M | L | S | DataGrip |
| Show Services when | When the output pane pops up | M | L | S | DataGrip |
| Show time in editor | Inline duration | P | L | S | DataGrip |
| Show/hide output place | Results in window or tool tab | M | L | S | DataGrip |
| Smart expand selection | Partly selected statements grow to whole ones | M | L | S | DataGrip |
| Tab title templates | Tab name built from source/schema variables | M | L | S | DataGrip |
| Timestamps on output | Time per line | P | L | S | DataGrip |
| Title marker setting | Only after chosen text | M | L | S | DataGrip |
| Floating toolbar on selection | Run, Explain, Format, Comment appear over a selection | M | L | M | DataGrip |
| Recent changes | List of recent edits across files | M | L | M | DataGrip |
| Run configurations | Saved "run these files on these targets" | M | L | M | DataGrip |

### Sessions and transactions (9)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Commit shortcut `design` | Assignable | P | M | S | DataGrip |
| Back to database default | Clear the chosen level | M | L | S | DataGrip |
| Close sessions | One or all, with confirm | P | L | S | DataGrip |
| Isolation in the data editor | Choose the level for the tab | M | L | S | DataGrip |
| Rename session | Label it | M | L | S | DataGrip |
| Submit immediately `design` | Write when you leave a row | M | L | S | DataGrip |
| SQL resolution scopes | Map folders to sources for resolving | M | L | M | DataGrip |
| Savepoints UI | Mark and roll back to | M | L | M | DataGrip |
| Switch session | Move a console to another session | P | L | M | DataGrip |

### Data grid (49)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Auto-post on leaving a row `design` | No Apply step | M | H | S | HeidiSQL |
| Add row header, transpose, DDL, query sheet | Export Data dialog options | M | L | S | DataGrip |
| Alternate row colours | Stripes on or off | P | L | S | DataGrip |
| Array as text | Edit arrays | M | L | S | DataGrip |
| Auto-transpose | Never, one row, always | P | L | S | DataGrip |
| Booleans as | Text or checkbox | P | L | S | DataGrip |
| Cell encoding | Read bytes in another charset | M | L | S | DataGrip |
| Colours of the grid | NULL, image, error, stripe colours | M | L | S | DataGrip |
| Compare tolerance | Ignore N column differences; detect column insertion | M | L | S | DataGrip |
| Convert to literal | Turn an expression back to a value | M | L | S | DataGrip |
| Copy as formats `ok?` | 16 formats, in a menu | P | L | S | HeidiSQL |
| Date picker in cell | Calendar for dates | P | L | S | DataGrip |
| Duplicate row | With or without keys | P | L | S | HeidiSQL |
| Edit without lookup | Bypass the pull-down | P | L | S | HeidiSQL |
| Filter history size | How many filters kept | P | L | S | DataGrip |
| Geometry as hex | Toggle | M | L | S | DataGrip |
| Heat colouring | Sequential or diverging, per column or whole table, booleans | P | L | S | DataGrip |
| Hex and ASCII, in the cell | Bytes shown both ways | P | L | S | DataGrip |
| Hex editor | Popup, load binary | P | L | S | HeidiSQL |
| Invert selection | Ctrl+I | M | L | S | HeidiSQL |
| Local filter by default | Funnels on open | M | L | S | DataGrip |
| Navigate and select, or filter | Choose how the jump behaves | P | L | S | DataGrip |
| Number format | Separators, pattern, NaN | P | L | S | DataGrip |
| Pagination control position | Move or float the pager | M | L | S | DataGrip |
| Pagination position | Where the pager sits | M | L | S | DataGrip |
| Paging in in-editor results | Per view | M | L | S | DataGrip |
| Panel position | Move to right or bottom | M | L | S | DataGrip |
| Pipe-separated | DSV preset | M | L | S | DataGrip |
| Prefill date with now `design` | Option | M | L | S | HeidiSQL |
| Resize from keyboard | Widen, narrow, reset columns | P | L | S | DataGrip |
| Same-value highlight | Tints cells like the focused one, always on | P | L | S | HeidiSQL |
| Select occurrences | Multi-select equal cells, step through them | M | L | S | DataGrip |
| Select row or column | Keyboard selection of a row or column | P | L | S | DataGrip |
| Settings shortcuts | Open them from the grid | M | L | S | DataGrip |
| Source table hint | Result header says which table | M | L | S | HeidiSQL |
| Submit immediately | Auto-write | M | L | S | DataGrip |
| Table sampling | SELECT a sample | M | L | S | DataGrip |
| Timestamp in microseconds | Unix µs as a date | M | L | S | DataGrip |
| Two-column record layout | Wider forms | M | L | S | DataGrip |
| Type to search in grid `design` | Incremental search | M | L | S | HeidiSQL |
| URL click rules | Which links open | M | L | S | DataGrip |
| ↓ on last row adds a row | Keeps typing | M | L | S | HeidiSQL |
| Completion in cells | Suggest values while typing | M | L | M | DataGrip |
| Immediate completion in cells | Suggestions as you type | M | L | M | DataGrip |
| Quick actions toolbar | Popup on a cell | M | L | M | DataGrip |
| Virtual columns, views | Local computed objects | M | L | M | DataGrip |
| Geo viewer | Map of spatial values | M | L | L | DataGrip |
| Scripted aggregators | Your own Groovy or JS aggregates | M | L | L | DataGrip |
| Scripted extractors | Your own Groovy or JS | M | L | L | DataGrip |

### Tree and navigation (19)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Auto expand on click | Opens as you click | M | L | S | HeidiSQL |
| Code block ends | Jump to BEGIN/END, bracket | M | L | S | DataGrip |
| Double-click inserts name | Into the query tab | M | L | S | HeidiSQL |
| Drag a data source | Drop files to create one | M | L | S | DataGrip |
| Empty groups, intermediate nodes | Tree layout toggles | M | L | S | DataGrip |
| Filters toggled in the menu | Hide filter boxes | M | L | S | HeidiSQL |
| Find history | Recent searches | M | L | S | DataGrip |
| Group by Server and Database objects | Alternate top level | M | L | S | DataGrip |
| Last edit place | Jump to it | M | L | S | DataGrip |
| Natural sort order | table2 before table10 | P | L | S | DataGrip |
| Navigation bar | Breadcrumb of source, schema, table | M | L | S | DataGrip |
| Virtual objects shown in tree | Virtual keys under the table | M | L | S | DataGrip |
| Breadcrumbs | Clause path at the top | M | L | M | DataGrip |
| Read/write usage marks | Reads versus writes in usages | M | L | M | DataGrip |
| Recent locations | Popup of recent edit places | M | L | M | DataGrip |
| Configure layout | Scripted tree layout | M | L | L | DataGrip |
| Dataflow slice | Where a value flows | M | L | L | DataGrip |
| Scripted extensions | Run your scripts on objects | M | L | L | DataGrip |
| Structural search | Search by SQL structure | M | L | XL | DataGrip |

### Server home and disk use (6)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Clear data filter from tree | Reset a table's filter and sort | P | L | S | HeidiSQL |
| Connection properties | Host, OS, version, TLS, max_allowed_packet | P | L | S | HeidiSQL |
| Copy list as CSV | Whole list to clipboard | M | L | S | HeidiSQL |
| Fetch database items | Load sizes for chosen databases | M | L | S | HeidiSQL |
| Inline rename | Edit the name in the list | P | L | S | HeidiSQL |
| Type to jump | Incremental search | P | L | S | HeidiSQL |

### Schema tools (20)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Allow recreate if ALTER can't | Regenerate object | M | L | S | DataGrip |
| Definer picker | From server's users | P | L | S | HeidiSQL |
| Disable constraints, triggers | Toggle from the tree | M | L | S | DataGrip |
| Filter columns in a wide table | Filter panel on listColumns | M | L | S | HeidiSQL |
| Help button | Opens docs | M | L | S | HeidiSQL |
| Include auto-generated objects | Show what the server made by itself | M | L | S | DataGrip |
| Index size column | Bytes per index (12.21) | M | L | S | HeidiSQL |
| Invisible column | Checkbox | P | L | S | HeidiSQL |
| Invisible columns, indexes | MySQL 8, MariaDB flags | P | L | S | DataGrip |
| More options | Avg row, max rows, checksum, union, insert method, convert data | M | L | S | HeidiSQL |
| No-privilege notice | Says why it can't open | P | L | S | HeidiSQL |
| SRID, compressed | Spatial and MariaDB column compression | M | L | S | HeidiSQL |
| Trigger form `ok?` | Name, table, timing, event, definer | M | L | S | HeidiSQL |
| View form | Algorithm, definer, security, check option | M | L | S | HeidiSQL |
| Zerofill | Checkbox | P | L | S | HeidiSQL |
| Colours, notes | Decorate a diagram | M | L | M | DataGrip |
| Event form `ok?` | Once or every, starts, ends, state, drop after | M | L | M | HeidiSQL |
| Graph analysis | Paths between tables, centrality | M | L | M | DataGrip |
| Sequences, system versioning | MariaDB objects | P | L | M | DataGrip |
| Routine, trigger, event forms `ok?` | Fields for parameters, timing, schedule | M | L | L | DataGrip |

### Compare, import, export (26)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Bulk reset auto increment | Checkbox | M | L | S | HeidiSQL |
| Disable indexes, lock table | Faster load | M | L | S | DataGrip |
| Encloser and escaper | Choose them | M | L | S | HeidiSQL |
| Find by column type | Text, numbers, dates… | P | L | S | HeidiSQL |
| Find with custom SQL | WHERE per table | M | L | S | HeidiSQL |
| First column as header | Transposed files | M | L | S | DataGrip |
| Ignore first lines | Count | P | L | S | HeidiSQL |
| Include query, remove line breaks, focused column only, auto-inc | Export options | M | L | S | HeidiSQL |
| Keep dialog open | For several files | P | L | S | HeidiSQL |
| LOAD DATA method `design` | Server parses: much faster | M | L | S | HeidiSQL |
| Local number format | Comma decimals | M | L | S | HeidiSQL |
| Maintenance options | Quick, fast, medium, extended, changed, use frm, for upgrade | M | L | S | HeidiSQL |
| Max INSERT size | KB per INSERT | P | L | S | HeidiSQL |
| Object tree in tools | Tick tables with size sum, check by type, invert | P | L | S | HeidiSQL |
| Open file after export | Checkbox | M | L | S | HeidiSQL |
| Print | List or grid | M | L | S | HeidiSQL |
| Save clipboard defaults | Separate settings for Copy | P | L | S | HeidiSQL |
| Truncate before import | Checkbox | M | L | S | HeidiSQL |
| Wrap in transactions, add comments | Export options | M | L | S | HeidiSQL |
| mysqldump option set | Disable keys, lock, multi-insert, complete insert… | P | L | S | DataGrip |
| AI SQL suggest | Prompt to SQL, sequal.dev | P | L | M | HeidiSQL |
| Data source from model | Make a source from cached model | M | L | M | DataGrip |
| Generate data | Fill a table with test rows, % of NULLs | M | L | M | HeidiSQL |
| Insert files `ok?` | Files into BLOB/TEXT with %filename% etc | M | L | M | HeidiSQL |
| Run in Docker | Tools in a container | M | L | M | DataGrip |
| Linked data sources | Map to other sources | M | L | L | DataGrip |

### Users and grants (3)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Limitations | Queries, updates, connections per hour, simultaneous | M | L | S | HeidiSQL |
| Plugin choice | Authentication plugin (12.18) | M | L | S | HeidiSQL |
| SSL requirements | REQUIRE SSL, X509, cipher, issuer, subject | M | L | S | HeidiSQL |

### Connections and settings (52)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| Reconnect last sessions on start `design` | Reopens what you had | M | H | S | HeidiSQL |
| Advanced: Related Rows behaviour | Filter or select | M | L | S | DataGrip |
| Client key password | Encrypted key file | M | L | S | DataGrip |
| Completion delay, on or off | Interval, enable | M | L | S | HeidiSQL |
| Connect by link or command line | Open a connection from outside | M | L | S | DataGrip |
| Connection URL | See, edit, paste a URL | P | L | S | DataGrip |
| Copy SSL settings from another | Link | M | L | S | DataGrip |
| Ctrl+F2 function, Shift+Ctrl+N NULL | Cell keys | P | L | S | HeidiSQL |
| Ctrl+Q clear log, Ctrl+W clear editor | Clear | P | L | S | HeidiSQL |
| Ctrl+wheel zoom | Option | P | L | S | HeidiSQL |
| Diagnostics | Report material for support | P | L | S | DataGrip |
| Float trailing zeros | Trim | M | L | S | HeidiSQL |
| Get full table status | Off for huge servers | P | L | S | HeidiSQL |
| Grid colours by type | Choose each | M | L | S | HeidiSQL |
| Hide database pattern | Regex of databases to hide | P | L | S | HeidiSQL |
| Import and export settings | Whole app config in one file | P | L | S | HeidiSQL |
| Import or sync settings | Move your setup | P | L | S | DataGrip |
| Keep-alive interval | Set the query and time | P | L | S | DataGrip |
| Last refreshed | When the tree was read | M | L | S | DataGrip |
| Load sources for | Skip routine bodies | P | L | S | DataGrip |
| Log lines, snip length | SQL log size | P | L | S | HeidiSQL |
| Log to file per session | DDL and/or DML only | P | L | S | HeidiSQL |
| Lowercase hex | Option | M | L | S | HeidiSQL |
| Maximum column width | Cap for auto width | M | L | S | HeidiSQL |
| NULL background | Colour | P | L | S | HeidiSQL |
| Pending-cancel message | A statement won't die | P | L | S | DataGrip |
| Ping interval | Keep-alive seconds, per session | P | L | S | HeidiSQL |
| Pop-up editors on or off | Per type | M | L | S | HeidiSQL |
| Portable mode | Settings file beside the app | P | L | S | HeidiSQL |
| Query files folder | Where new queries go | P | L | S | DataGrip |
| Read-only per table | Mark one table | M | L | S | DataGrip |
| Remember filter | Keep the tree's filter | M | L | S | DataGrip |
| Restore defaults | Button | P | L | S | HeidiSQL |
| SSH timeout, local port, ssh program `design` | Tunnel fine-tuning | P | L | S | HeidiSQL |
| Save password policy | Never, session, forever | P | L | S | DataGrip |
| Session statistics | Created, last connect, success and failure counts | M | L | S | HeidiSQL |
| Settings search | Find a setting by word | M | L | S | DataGrip |
| Single database mode | Only the named database | P | L | S | DataGrip |
| Style themes | Dozens of Delphi styles; icon packs | P | L | S | HeidiSQL |
| Switch schema | Auto, manual, off | P | L | S | DataGrip |
| TLS cipher list | Limit ciphers | M | L | S | HeidiSQL |
| Tab icon greyscale | Cosmetic | M | L | S | HeidiSQL |
| Track new databases | Schema list follows | P | L | S | DataGrip |
| UI font | Choose | M | L | S | HeidiSQL |
| Use client time zone | SET time_zone to this machine | P | L | S | HeidiSQL |
| Web search base URL | Search an error online | M | L | S | HeidiSQL |
| Before connection tasks | Run something first | M | L | M | DataGrip |
| ProxySQL admin mode | Experimental network type | M | L | M | HeidiSQL |
| Session templates | Override settings per session | M | L | M | DataGrip |
| Shared via VCS | Connections in a project folder | P | L | M | DataGrip |
| Language `ok?` | About 30 translations | M | L | L | HeidiSQL |
| Cloud explorer | Find AWS, GCP, Azure databases | M | L | XL | DataGrip |

### Workspace (20)

| Feature | What it does | State | Value | Size | From |
|---|---|---|---|---|---|
| More themes, custom colours `design` | Plugins, editor schemes | M | M | M | DataGrip |
| Cancel an agent's query | cancel_sql_query | P | L | S | DataGrip |
| Copyright comments | Insert headers | M | L | S | DataGrip |
| Create, edit, test connection | create_database_connection, edit_database_connection, test_database_connection | M | L | S | DataGrip |
| Per-tool switches | Turn each tool off | P | L | S | DataGrip |
| Print | Print a grid or diagram | M | L | S | DataGrip |
| Recent queries | list_recent_sql_queries | P | L | S | DataGrip |
| Reset panel sizes | Fix layout | M | L | S | HeidiSQL |
| SQL injected in other languages | SQL inside Java strings etc. | M | L | S | DataGrip |
| Settings sync | Across machines | P | L | S | DataGrip |
| Tabs in several lines | Option | M | L | S | HeidiSQL |
| Terminal | Built-in terminal | P | L | S | DataGrip |
| Tip of the day | Tips at startup | M | L | S | DataGrip |
| Touch Bar | Bar actions | M | L | S | DataGrip |
| Blame | Who wrote a line | M | L | M | DataGrip |
| Feature trainer | Interactive lessons | M | L | M | DataGrip |
| JSON/regex in SQL strings | Inject into string literals | M | L | M | DataGrip |
| Table-level AI | Describe, generate data | M | L | M | DataGrip |
| DDL mapping | Link files and a live database | M | L | L | DataGrip |
| DDL data source | Schema read from .sql files, no server | M | L | XL | DataGrip |
