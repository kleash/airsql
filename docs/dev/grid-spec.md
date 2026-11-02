# AirSQL data grid: merged spec (HeidiSQL + DataGrip)

The grid is one custom AppKit view (`DataGridView`) used for table data, query results, Transpose and recon diffs. This
spec merges every HeidiSQL Data-tab feature (read from HeidiSQL `master` 48aaabb, 2026-11-01) with DataGrip 2026.2's
data editor, and fixes what users complain about in both. Sources: the two research reports summarised in
`docs/dev/research.md`. Plan v2 (`docs/dev/plan.md`) wins where the two differ.

Legend: **H** from HeidiSQL, **D** from DataGrip, **A** AirSQL's own or a fix of a known complaint.

## 1. Principles

1. **Nothing is lost by accident.** Edits are pending until Apply (⌘S); leaving a row never writes (fixes HeidiSQL
   auto-post, forum t=45206). Closing a tab, switching table or disconnecting with pending edits asks.
2. **One editing model everywhere.** Grid cells, Transpose, Record view and the value panel edit the same pending
   change set.
3. **Always say where an operation runs.** Filter, sort and search show "on server (all rows)" or "local (N loaded
   rows)" in the grid's bar.
4. **Fast at any size.** Draw only visible cells; fetch in pages off the main thread; shorten long values for display
   and fetch the full value on demand (H: `LEFT(col,256)` + "[…]"). **Key columns are never shortened**, so edits
   always address the exact row.
5. **Every action is in a menu, a right-click menu and has a tooltip;** shortcuts are shown in both.
6. **Typing edits** (spreadsheet behaviour, D). Jump-to-value is ⌘J (column list) and ⌘F (find), not type-ahead.

## 2. Selection and navigation

| Feature | Src | Mac keys | Notes |
|---|---|---|---|
| Cell, cell range, whole rows, whole columns, ⌘-click to add, ⇧-click to extend | D+A | click, ⇧/⌘-click; ⌘A all | Cell ranges fix HeidiSQL's rows-only selection (#35) |
| Arrow moves; ⌘↑/⌘↓ first/last row; ⌘←/⌘→ first/last column; Page Up/Down | H | | |
| Tab / ⇧Tab next/previous cell, wrapping rows | H | | Commits the cell edit (still pending, not applied) |
| Extend / shrink selection: cell → column → row → grid | D | ⌥↑ / ⌥↓ | |
| Go to row (number, or `column:row`) | D | ⌘L | |
| Jump to column: searchable column list | D | ⌘J | Space toggles visibility inside the list |
| Status bar: `r12 : c3`, selection size, loaded / total rows | H | | |
| Tooltip with the full value (first 1 KB) | H | hover | |
| ⌥-scroll moves by row; ⇧-scroll horizontal; ⌘+/⌘− zoom grid font | H | | |
| Down on the last row does nothing on read-only grids; on editable ones it does **not** insert (⌘I does) | A | | Fixes HeidiSQL #2596 |

## 3. Understanding the data

| Feature | Src | Notes |
|---|---|---|
| Headers: name, type, key icons (PK bold, FK, unique, index), auto-increment / default / generated marks, comment as tooltip, sort arrows with position ¹²³ | H+D | |
| Row-number gutter; frozen key column (optional) | H+A | |
| Colours by type group; NULL as `NULL` in a pale tint with optional background; numbers right-aligned | H | Light/dark from system colours |
| Highlight cells equal to the focused cell's value | H | Off by default |
| Heatmap colouring for a column or table (sequential, diverging, boolean) | D | |
| Status-bar aggregator for the selection: count, sum, avg, min, max, median, distinct; click to switch; ⇧⌘C copies it | D | Aggregate side panel shows all at once |
| Column summary: distinct, NULLs, min, max, top 50 values with counts, within the current filter, worked out on the server; click a value to filter | H+A | HeidiSQL "More values" plus counts; above 2 GB tables warn first |
| Value panel (⇧↩): text with wrap, JSON/XML pretty + tree, hex, image preview, line-break style, highlighting language per column, length and cursor position | H+D | Same pending-change model |
| Record view (⇧⌘↩): one record as a form, one or two columns | D | Fixes HeidiSQL #116 |
| Transpose (⌥⌘T); auto-transpose single-row results (setting: never / one row / always) | D | |
| View as Table / Text (in the current copy format) / Tree (JSON) | D | |
| Chart of the results: bar, line, area, pie, scatter, histogram; save as PNG | D | Native drawing (Swift Charts on 13+) |
| Unix-timestamp column: show as local date/time, copy the raw number; binary(16) as UUID; binary as hex or text | H+D | Per-column display type, remembered per table |
| Number display: grouping, max decimal zeros, lowercase hex; dates in a chosen format and time zone | H+D | |
| Compare two result grids (or a grid with a table): changed, added, removed rows | D | Shares the recon diff engine |

## 4. Filter, sort and search

| Feature | Src | Mac keys | Notes |
|---|---|---|---|
| WHERE bar: SQL highlighting, completion, grows 1–8 lines, strips a leading `WHERE`; Apply ↩; Clear | H+D | ⇧⌘F focus | Server side: all rows |
| Recent filters: last 20 per table; filter, sort, hidden columns and widths remembered per table | H | ⌥↓ in the bar | Fixes "widths forgotten" (#434) for results too |
| Search all columns box: builds `col LIKE '%x%' OR …` over every column (exact `=` where LIKE makes no sense); option "loaded rows only"; highlights matches | H | ⇧⌘E | |
| Quick filter from a cell or selection: = , ≠, <, >, LIKE x%, LIKE %x, LIKE %x%, IN/NOT IN (selected values), IS NULL, IS NOT NULL; = / ≠ / LIKE from a prompt or the clipboard; captions show the SQL; ⌥-click ANDs onto the current filter | H+D | ⌃⌘1 =, ⌃⌘2 ≠ | |
| Local column filter: tick values in the header's funnel menu (values from the server with counts for table data, from loaded rows for results) | D | | |
| Local find: ⌘F highlights matches in loaded rows; "Filter rows" hides the rest; regex, case, whole word; "X of Y matching" | H+D | ⌘F, ⌘G / ⇧⌘G | |
| Find and replace in loaded rows, in the selection or everywhere; replacements become pending edits | H | ⌥⌘F | |
| Sort: a header click selects the column; the sort control at the header's right (on hover and when sorted) steps ASC → DESC → off; ⌥-click on it adds a secondary sort; table data sorts on the server (asks first on a table over 1 M rows when the column has no index), results locally (asks above 100,000 rows); sort dialog for many columns | H+D | | |
| Paging: `LIMIT … OFFSET` pages (default 1,000), Next page, Load all (asks above a size you set); estimated total, "Count exactly" | H+D | ⌥⌘↓ next, ⇧⌥⌘↓ all | |
| Refresh; auto-refresh every N seconds | H+D | ⌘R | |

## 5. Editing

| Feature | Src | Mac keys | Notes |
|---|---|---|---|
| Edit in place: type to replace, ↩ / double-click / F2 to edit; ⌥↩ newline; Esc cancels the cell | H+D | | |
| Multi-cell edit: with several cells selected, type a value and ↩ sets them all | D | | |
| Pending changes: changed cells, new rows and deleted rows highlighted; Apply (⌘S) runs them **in one transaction** on the data session, checking every statement's affected rows exactly (any mismatch rolls back and points at the row); Preview SQL; Revert selection (⌥⌘Z); undo/redo (⌘Z/⇧⌘Z) | D+A | ⌘S, ⌥⌘Z | Production connections always show the preview first |
| Add row (⌘I), Duplicate row with keys / without keys (⌘D / ⇧⌘D), Delete rows (⌘⌫) | H+D | | Deletes run as one `DELETE … WHERE pk IN (…)` per batch of 500 (fixes #281) |
| Auto-generated values: new rows show *auto* / *default*; AUTO_INCREMENT, DEFAULT and generated columns are left out of the INSERT; the row is read back after Apply (`LAST_INSERT_ID()` and a re-select by key) | H+A | | Generated columns are read-only |
| Set NULL (⌥⌘N), Set DEFAULT (menu only: ⌥⌘D belongs to the Dock), Insert value menu: NOW() / CURRENT_TIMESTAMP(6) / CURDATE() / CURTIME() / UTC variants / UNIX_TIMESTAMP(), UUID() / UUID without dashes / lowercase, an SQL expression (sent unquoted, shown as `ƒ NOW()` until applied) | H+D | | |
| Date/time editor: masked text you can type straight into; ↑/↓ steps the part under the cursor; calendar popover on demand only; fractional seconds; TIME ±838:59:59; YEAR; zero dates kept as typed; TIMESTAMP shows the session time zone | H+A | | Never prefills NOW() into an untouched NULL (fixes t=9771) |
| ENUM pick-list; SET checklist; BOOLEAN / TINYINT(1) / BIT(1) checkbox (Space toggles; t/f/n keys); wider BIT shown and edited in full as `b'…'` | H+D | | Fixes BIT > 8 bits (#56) |
| Long text: the value panel, or a popup editor for 256+ characters or multi-line; find/replace; format JSON/SQL/XML once or always; load a text file | H | | |
| BLOB: hex editor, load from file, save to file, image preview | H+D | | |
| JSON: checked before Apply, pretty or compact on save, tree view | D+A | | MariaDB JSON = LONGTEXT with `JSON_VALID` |
| Numbers and DECIMAL kept as text end to end; checked against type, sign and range while typing | A | | |
| Foreign keys: drop-down with search showing "label (id)", label column chosen per table (default: first text column); label also shown in the grid cell as a grey suffix; Related rows (⌘↓) both directions, filter or select; virtual foreign keys you define | H+D | ⌘↓ | Fixes #177, #762; large tables use a searched lookup, not a full list |
| Edit results of a single-table SELECT that includes its key; edit inner-JOIN results when every table's key is present (preview required); outer joins, self-joins and duplicated rows are read-only with a reason | H+D | | |
| Tables without a primary key: use the first UNIQUE key whose columns are all NOT NULL; with none the grid is read-only and says why | H+A | | Safer than HeidiSQL's match-all-columns + LIMIT 1 (t=358) |
| Non-transactional tables (MyISAM, Aria, MEMORY): the preview warns that Apply can't be rolled back; deletes list tables touched by ON DELETE CASCADE | A | | |
| Paste: TSV/CSV from Excel or Numbers fills cells and adds rows as pending changes, converting types; Paste Format to override detection | D | ⌘V | Fixes HeidiSQL single-cell paste (t=26779) |
| Edit as Table: selected INSERT statements in the console open as a grid | D | | |

## 6. Copy and export

| Feature | Src | Notes |
|---|---|---|
| ⌘C copies the selection in the current format (default TSV with no headers); ⌥⌘C Copy with headers; Copy As ▸ TSV, CSV, Markdown, JSON, JSON Lines, HTML table, XML, SQL INSERT / INSERT IGNORE / REPLACE / UPDATE / DELETE, WHERE clause; the last one chosen becomes ⌘C's format | H+D | |
| Options: skip generated and auto-increment columns, NULL as text (`NULL`, `\N`, empty), separators, quoting, line endings | H+D | |
| Copy column names | H | |
| Export rows: selection, loaded rows, or **all rows of the query** (streamed, not held in memory) to CSV, TSV, JSON, JSON Lines, SQL, Markdown, HTML, XML, Excel (.xlsx); to a file or the clipboard | H+D | |
| Copy rows into another table or connection | D | Uses the built-in SQL export path |

## 7. Skipped from both

LaTeX, Textile and PHP array export (H), Print (H), Open URL (H), custom Groovy/JS extractors (D), the Geo viewer (D,
PostgreSQL only).

## 8. Performance and acceptance targets

Measured on the development Mac (M1 Pro, 120 Hz ProMotion) before each merge:
- 1,000,000 rows × 50 columns and a 300-column table scroll at 120 Hz with no dropped frames.
- First page of a 10-million-row table on screen within 300 ms of the query returning.
- Typing in a cell or the WHERE bar never waits on the network.

Gated in CI with deterministic numbers (no timing on shared runners):
- cells drawn per scroll step stay proportional to the visible area;
- page build time within 5× of the reference;
- bytes held in `ResultStore` for a 1,000,000 × 10 fixture of short values under 150 MB; full values fetched only for
  edit, copy, export.

Accessibility: the grid is an accessibility table (total counts, lazily created cells, focus notifications,
editing), so VoiceOver and the agent snapshot can read and act on it.
