---
title: The SQL console
nav_order: 9
---

# The SQL console

A console tab is where you write and run SQL on one connection. Its statements run one at a time, on the connection's
own session, which every console tab of that connection shares.

## Open a console

- **File ▸ New Query** (⌘T), the **+** at the end of the tabs, or **New Query** on a connection's menu opens an empty
  console on the selected connection. **New Query** on a database's menu (or ⌘T while a database is selected in the
  sidebar) makes that database the current one first.
- **File ▸ Open…** (⌘O) opens .sql files, each in a console of its own. You can also drop .sql files anywhere on the
  window or on AirSQL's Dock icon, or open them with AirSQL from Finder: they open on the connection shown.
- **File ▸ Save** (⌘S) saves the console's text to its file; **Save As…** to a new one. A tab with unsaved text shows a
  dot instead of its close button.
- Drag a result's tab to put the results in another order.
- Double-click a console's tab (or press F2 while its editor has the focus) to give it a name of your own.
- When you quit, the open consoles are kept, unsaved text included, and come back the next time you open AirSQL.
- **File ▸ Open Recent** lists the .sql files you had open lately.
- **Query ▸ Change Connection…** runs the console's statements on another connection.

## Write SQL

- Keywords, names, strings, numbers and comments have their own colours; the brackets around the cursor are marked.
- A quote, comment or bracket left open is underlined in red a moment after you stop typing, and hovering over it says
  what's missing. No server is asked.
- A table or column that isn't in the schema AirSQL has read is underlined in red the same way, and hovering over it
  says what wasn't found. It's only advice: **Run** still runs, and nothing is sent to the server to check. When
  AirSQL isn't sure it says nothing: a database whose details aren't loaded yet, temporary tables and tables made or
  altered in the same text or session, CTEs, derived tables, and any statement other than a plain SELECT, INSERT,
  REPLACE, UPDATE or DELETE. Columns are checked only when every table in the statement is known. If a table is new,
  **Refresh** the schema and the underline goes.
- **Completion** opens as you type: after FROM or JOIN the tables and views, after JOIN first the joins that foreign
  keys give (`orders o ON o.customer_id = c.id`), after `alias.` that table's columns, after USE the databases, and
  elsewhere the statement's columns, functions and keywords. ↑ and ↓ choose, Return or Tab inserts, Escape closes;
  ⌥⎋ opens it anywhere. It comes from what AirSQL already read of the schema: nothing is sent to the server while you
  type.
- **View ▸ Query Helpers** shows beside the editor the columns of the tables the statement at the cursor names, the
  server's functions by kind, and the keywords. Double-click one to put it in at the cursor, or drag it into the editor
  (a column's name comes quoted where it needs to be, as completion puts it in).
- **Edit ▸ Find** (⌘F) and **Find and Replace** (⌥⌘F) find in the editor, with **Regular Expression** and **Match
  Case**. With a regular expression, `$1`, `$2`… in the replacement put in its groups. **Replace All** is one change
  that **Undo** takes back.
- Typing `(`, `[` or a quote adds its partner, or wraps the selection; typing the partner steps over it, and Delete
  between an empty pair takes both.
- **Edit ▸ Go to Line…** (⌃G) goes to the line a message names. **View ▸ Word Wrap** (also in Settings ▸ Editor) wraps
  long lines at the editor's edge.
- **Edit ▸ Comment Lines** (⌘/) comments the selected lines out with `--`, or takes the comment away. **Shift Right**
  (⌘]) and **Shift Left** (⌘[) indent; so do Tab and ⇧Tab on several lines.
- **Query ▸ Format SQL** (⌥⇧⌘F) puts each main clause on a line of its own and reserved words in capitals. It changes
  nothing else: names, values, comments and `/*! … */` code stay exactly as they are, and statements inside a
  `DELIMITER` block are left alone. If it couldn't do that, it leaves the SQL as it was and says so.
- **View ▸ Bigger** (⌘+), **Smaller** (⌘−) and **Actual Size** change the text size for a moment; Settings ▸ Editor
  sets it for good.

## Run it

| To run | Press |
|---|---|
| The statement at the cursor, or the selected text | ⌘↩ (or ⌃F9) |
| Only the selected text | Query ▸ Run Selection |
| Every statement | ⇧⌘↩ (or F9) |
| Stop the statement that is running | ⌘. (Query ▸ Cancel) |

The statement that ran is highlighted for a moment, so there is no "which statement?" question. Statements are split
on `;`, or on the delimiter a `DELIMITER` line sets, and sent one after another; a run stops at the first error.

While a statement runs, the bar above the results shows which one and for how long, with **Cancel**; the status bar
lists it too. Cancel stops only that statement: AirSQL checks the server is still running it before it stops it. A
connection can have a query timeout: a statement that runs longer is stopped the same way, and Messages says so.

Console tabs of one connection share its session, so while one runs a statement the others wait.

### The current database

Statements run in the connection's current database, which the toolbar's database pop-up shows and the sidebar shows in
bold. Choose another in the pop-up, double-click one in the sidebar, or type `USE`: all three change the same one, for
every console tab of the connection. A database chosen in the pop-up or the sidebar is made current with `USE` just
before the next statement runs (Messages shows it), so a run under way is never switched midway; if that `USE` fails,
nothing runs.

## Results and Messages

- Each result set gets a **result tab** under the editor, named after the comment just above its query (`-- Top
  customers` names it "Top customers"), else "Result 1", with its rows and columns. The next run replaces the result
  tabs, unless you **pin** one (right-click it, or Query ▸ Pin Result); a result with edits not yet applied stays too.
  A tab's ✕ closes it. **Query ▸ Show Next Result** (⌥⌘]) and **Show Previous Result** (⌥⌘[) move along the tabs,
  Messages included.
- Double-click a result tab to rename it; right-click it to pin, rename or close it, export its rows, or compare it
  with another result or a table (**Compare With…**, see [Compare](compare.md#compare-two-results-or-a-result-with-a-table)).
  When more tabs are open than fit, scroll the tabs sideways.
- **Messages** lists what each statement did: its rows or the rows it changed, how long it took, the server's
  warnings, or its error and the line it points to (that line is marked red beside the editor, the place the server
  names is underlined in red, and hovering over it shows the message, until you change the text). Double-click a message
  to select its statement.
- A result keeps at most its first 100,000 rows; the tab then says it is cut short.
- **Edit ▸ Find** (⌘F) with a result's rows focused finds values in them, as in a [table tab](table-data.md): ⌘G and ⇧⌘G
  move between matches, and Options has Match Case, Regular Expression, Whole Words and Filter Rows. Replace is for
  table tabs.
- **Filter, search and sort a result** on its rows, at once, without running the query again: right-click a cell for
  **Quick Filter** (the same conditions as in a [table tab](table-data.md#filter-search-and-sort), Type a Value…
  included), a header for **Filter by Values…** (the values in the rows shown, with their counts) or **Sort by
  Columns…**, or click a value in **Column Summary…**. **Data ▸ Search All Columns** (⇧⌘E) keeps the rows with the text
  in any column and tints it. A bar over the rows shows while a filter or a search is on: **Local · 12 of 200 rows**,
  the conditions as SQL, and the search; its ⓧ or **Data ▸ Clear Filter** shows every row again. Copy and Export Rows…
  take the rows shown. The **?** at the right of the result tabs opens [Read the data in a grid](data-grid.md).

### Edit a result

The rows of a `SELECT` from one table can be edited when the result includes the table's key (its primary key, or a
unique key whose columns can't be NULL); so can an inner join's when every table's key is in it. The status bar says
**Editable** or **Read-only**, with the reason in its tooltip; double-click a read-only cell to see why (an outer join,
`GROUP BY`, `DISTINCT`, `UNION`, a subquery in `FROM`, a self-join, a column worked out by the query, or a row of the
"one" side of a join that shows in several result rows).

- Double-click a cell (or start typing) to change it; **Set NULL** (⌥⌘N) and, in a one-table result, **Delete Rows…**
  (⌘⌫) work as in a table tab. Values are checked by their column's type as you type. Changes wait, marked in colour,
  with a bar over the rows counting them; **Undo**, **Redo**, **Revert** and **Revert All** take them back.
- **Apply** (⌘S while the rows have the keyboard, or the bar's button) writes them in one transaction on the
  connection's data session, each statement checked to change exactly its row. A join's changes always show the SQL
  first; so do changes on connections whose **Settings ▸ Safety** asks for the preview, and deletes that cascade. If the
  console has a transaction open, Apply asks you to commit or roll it back first, so it doesn't wait for its locks.
- After Apply, the edited rows are read back from the server, so the result shows what was stored; deleted rows go.
  New rows and pasting are for a table tab: open the table to add rows.
- Edits not applied are never thrown away unasked: the next run keeps their result tab, and disconnecting asks first;
  so do closing the result, closing the console and quitting, unless the connection's Safety settings don't warn on
  close.
- On a read-only connection nothing can be edited.

### Edit INSERT statements as a table

Select one or more `INSERT … VALUES` statements of one table (or put the cursor in one) and choose **Query ▸ Edit as
Table** (also in the editor's right-click menu). The table opens in its tab with each row as a new row, a pending
change: strings and numbers as their values, `NULL`, `DEFAULT`, and anything else (such as `NOW()`) as SQL the server
works out. Change them as you like, then **Apply**: it always shows the SQL first. Nothing runs from the console.

## Transactions

- **Tx: Auto-commit** (the toolbar's Tx pop-up, or Query ▸ Transaction Mode) commits each statement by itself. In
  **Manual**, your changes wait in a transaction until you press **Commit**, or **Rollback** to undo them. Leaving
  Manual with changes waiting asks first whether to commit them or roll them back.
- The **isolation level** (in the Tx pop-up, or Query ▸ Isolation Level) sets how the console's transactions see
  others' changes: Read Uncommitted, Read Committed, Repeatable Read or Serializable, set on the console's session with
  `SET SESSION TRANSACTION ISOLATION LEVEL`. Until you choose one, the server's own applies (usually Repeatable Read).
- The toolbar's Run, Commit, Rollback and Cancel are on only when the console can do them now; when one is off, its
  tooltip says why (not connected, no transaction open, nothing running).
- While a transaction is open, the status bar says so, with the number of rows changed, and how long it has been open
  once that passes the time set in Settings ▸ Safety.
- Closing the connection's last console with a transaction open asks first: **Commit**, **Roll Back** or keep the tab.
- Quitting AirSQL with a transaction open asks first too, in one sheet with any table changes and result edits not yet
  applied.

On a [read-only connection](connections.md#add-or-edit-a-connection), Run, Explain and Profile refuse any statement
AirSQL can't prove only reads (SELECT, WITH … SELECT, SHOW, DESCRIBE, EXPLAIN and USE pass), and Messages says why.

## What asks first

The safety settings (Settings ▸ Safety, or a connection's own) decide which statements ask before they run. The SQL
shows in a sheet, with what it will do:

- an UPDATE or DELETE without WHERE, which changes every row of its table;
- DROP and TRUNCATE; dropping a database needs its name typed, and so does dropping or emptying a table where the
  connection says so (the Production preset does);
- on a connection where every write asks (the Production preset), any statement that may change data.

## History, the SQL log, plans and profiles

- **Query ▸ Query History** (⌘Y) lists the statements run on the console's connection, newest first. Type to search;
  Return or a double-click puts one in the editor at the cursor, and a click shows it whole below the list. Click a
  header to sort, ⌘-click to select several; a right-click also opens them in a new tab or deletes them from the
  history. Passwords in statements are masked before they are kept, as in the SQL log.
- **View ▸ SQL Log** (⌥⌘L) shows every statement AirSQL sent, as they come. See [the SQL log](sql-log.md).
- **Query ▸ Explain** (⌥⌘E) shows how the server would run the statement at the cursor, without running it: as the
  server's table, or as a tree (MySQL's own tree; MariaDB's plan made into one).
- **Query ▸ Profile** runs the statement and shows where the server spent its time. On MySQL 8 and later it reads
  performance_schema: the statement's stages where the server records them, else its own figures (time, lock time,
  rows examined and sent, temporary tables, sorts and full scans). Elsewhere it shows SHOW PROFILE's steps, as it does
  on MySQL 8 when performance_schema is off or your login can't read it, with a note saying so.
- **Query ▸ Save as Changeset…** saves the selected statements (or the one at the cursor) as a Liquibase changeset in a
  changelog you choose. See [Liquibase changelogs](liquibase.md).
