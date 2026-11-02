# Research notes (2 November 2026)

Two research passes fed the scope (`docs/dev/scope.html`) and the grid spec (`docs/dev/grid-spec.md`).
This file keeps what the build lanes need: the lessons, the complaints to avoid, and the sources.

## DataGrip 2026.2: how it looks and is used

- **Layout:** Database Explorer on the left (⌘1), editor tabs in the middle, results at the bottom (Services, ⌘8) or
  under the statement (in-editor results). The console toolbar holds Run (⌘↩), Explain, History (⌥⌘E), a Tx menu
  (Auto/Manual + isolation, Commit/Rollback), Cancel (⌘F2) and a schema switcher.
- **Daily loop:** open a console on a source, type with completion, ⌘↩ runs the statement at the caret, edit the
  result in the grid, ⌘↩ submits edits.
- **Data sources dialog:** General, Options (read-only, tx control, keep-alive, startup script, introspection
  level), SSH/SSL (reusable SSH configs, one jump per config; chains need `~/.ssh/config`), Schemas, Advanced. Colour
  per source tints tree, tabs and toolbar.
- **Schema tools:** diagrams (export Mermaid/PlantUML/PNG), SQL generator (DDL, optional DEFINER strip), Compare
  Structure (Origin vs Target, checkbox per change, script preview, Execute), Modify Table with live SQL preview.
- **AI:** schema-aware chat; generated SQL shown as an in-editor diff with per-chunk revert; Explain/Fix with AI on
  errors. Built-in MCP server (2025.2+) with consent per scope: read schema, read data, change schema, change data.
  Agent queries go into normal history; docs recommend a read-only DB user.
- **What users like:** power, a fast table view. **What they dislike:** 2–3 GB memory, crashes after sleep, slow
  introspection of large schemas (150 MB XML per database), too many concepts (consoles, sessions, scratches, query
  files; JetBrains merged and then un-merged consoles in 2025.3), the "what to execute?" popup on ⌘↩, result tabs
  that multiply, schemas hidden until ticked, price, the AI sidebar.

### Lessons applied to AirSQL

1. ⌘↩ runs the statement at the caret with no chooser and briefly highlights what ran; Run All has its own key (⇧⌘↩).
2. One kind of query tab: a document bound to one connection, saved to a .sql file or kept as an unsaved tab that
   comes back after relaunch.
3. Pending-changes model in the grid: highlighted, Preview SQL, Apply, Revert; preview compulsory on production.
4. Transactions visible: Tx mode and isolation in the toolbar, a badge while a transaction is open, a warning on
   closing a tab with uncommitted work.
5. Production mode enforced by AirSQL itself (statement check + `SET SESSION TRANSACTION READ ONLY`), not by trusting
   the driver.
6. All filter kinds in the grid; ⌥-click stacks sorts.
7. Transpose, Record view and value panel share the editing model; auto-transpose single-row results.
8. Status-bar aggregates; copy formats with the last one as ⌘C's default.
9. Related rows both ways and virtual foreign keys (many MySQL schemas have none).
10. Typed editors that never block typing (DataGrip's date picker did, DBE-4964).
11. Result tabs reused unless pinned, named from the comment above the query, restored after relaunch.
12. Navigator shows every schema by default, metadata cached from information_schema, refreshed only for what DDL
    changed.
13. Speed and memory are published targets (launch under 1 s, idle under 150 MB, grid targets in grid-spec.md).
14. Table editor never blocks the window and shows live DDL; jump-host chains and proxies are real fields, importable
    from `~/.ssh/config`.
15. MCP: consent scopes, exact SQL shown before any write, agent queries in the shared history, proposed SQL goes to a
    console.

## HeidiSQL data grid (master 48aaabb)

Full inventory is merged into `grid-spec.md`. Complaints AirSQL fixes by design:

- Edits post automatically when focus leaves the row; no way to turn it off (forum t=45206).
- No cell-range selection; copy and paste take one cell (t=26779, issue #35).
- Date editor prefills NOW() into NULL cells you only pass through (t=9771).
- Down on the last row starts an INSERT, erroring on read-only results (#2596).
- One Data tab only; no record/form view (#155, #116).
- Deleting many rows sends one DELETE per row and hangs (#281).
- Query results forget column widths on re-run (#434).
- Foreign key text only in the drop-down, never in the grid; no lookup search (#177, #762).
- Tables without a primary key are edited by matching every column + LIMIT 1, which can hit the wrong row (t=358).
- BIT wider than 8 bits shows only 8 (#56).

## Sources

- DataGrip help: https://www.jetbrains.com/help/datagrip/ (data-editor-and-viewer, tables-filter, tables-sort, rows,
  cells, columns, submitting-and-reverting-changes, data-extractors, compare-data, virtual-foreign-keys,
  run-a-query, query-consoles, data-sources-and-drivers-dialog, configuring-ssh-and-ssl, introspection-levels,
  schema-comparison-and-migration, mcp-server, settings-database-ai-tools)
- DataGrip blog: https://blog.jetbrains.com/datagrip/2025/09/16/a-farewell-to-consoles/,
  https://blog.jetbrains.com/datagrip/2025/12/18/query-consoles-are-coming-back/,
  https://blog.jetbrains.com/datagrip/2026/07/16/datagrip-2026-2-ai-agent-skills-mcp-tools-and-cli-commands-for-data-source-management-bundled-jdbc-drivers-and-improved-session-control/
- Hacker News threads: https://news.ycombinator.com/item?id=44074985, https://news.ycombinator.com/item?id=48185188,
  https://news.ycombinator.com/item?id=42322087
- HeidiSQL source: https://github.com/HeidiSQL/HeidiSQL/blob/48aaabb/source/main.pas, main.dfm, grideditlinks.pas,
  exportgrid.pas, searchreplace.pas, data_sorting.pas, column_selection.dfm, dbconnection.pas
- HeidiSQL issues and forum: https://github.com/HeidiSQL/HeidiSQL/issues (35, 56, 116, 155, 177, 281, 434, 762,
  2596), https://www.heidisql.com/forum.php (t=358, 9771, 26779, 45206)
