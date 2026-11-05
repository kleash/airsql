---
title: The SQL console
nav_order: 9
---

# The SQL console

A query tab (the SQL console) is where you write and run SQL on one connection. Its statements run one at a time, on a
session of its own, so a long query in one tab leaves the others free.

## Open a query tab

- **File ▸ New Query** (⌘T), the **+** at the end of the tabs, or **New Query** on a connection's menu opens an empty query tab on the selected connection. **New Query** on a database's menu (or ⌘T while a database is selected in the
  sidebar) makes that database the current one first.
- **File ▸ Open…** (⌘O) opens .sql files, each in a query tab of its own. You can also drop .sql files anywhere on the
  window or on AirSQL's Dock icon, or open them with AirSQL from Finder: they open on the connection shown.
- **File ▸ Save** (⌘S) saves the tab's text to its file; **Save As…** to a new one. A tab with unsaved text shows a
  dot instead of its close button.
- Drag a result's tab to put the results in another order.
- Drag a tab along the strip to move it. Past ⌘9, the **Window** menu lists every tab.
- Double-click a query tab's tab (or press F2 while its editor has the focus) to give it a name of your own.
- When you quit, the open query tabs are kept, unsaved text included, and come back the next time you open AirSQL. The
  other tabs come back too: see [Getting back to your tabs](navigator.md#getting-back-to-your-tabs).
- **File ▸ Open Recent** lists the .sql files you had open lately. A file opens on the connection you last used it with.
- A file that isn't UTF-8 opens by its byte-order mark, else as Windows Latin 1, and Save keeps its encoding. If the text
  no longer fits that encoding, Save offers UTF-8.
- If a file changes on disk, its tab follows, and ⌘Z brings back what it showed; with unsaved edits, Messages warns instead.
- **Query ▸ Change Connection…** runs the tab's statements on another connection. A tab with no connection, such as a
  file opened with nothing selected, takes the one the toolbar shows.

## Write SQL

- Keywords, names, strings, numbers and comments have their own colours; the brackets around the cursor are marked.
- A quote, comment or bracket left open is underlined in red a moment after you stop typing, and hovering over it says
  what's missing. No server is asked.
- AirSQL reads what you write a moment after you stop typing, and underlines what it finds: see
  [Checks while you type](#checks-while-you-type).
- **Completion** opens as you type, with what fits there: only `BY` after `ORDER`, only joins after `LEFT`, the
  statement's columns in its clauses. ↑ and ↓ choose, Return inserts, Tab inserts and replaces the rest of the word too,
  Escape closes; ⌥⎋ opens it anywhere. Below the list you see more about what's selected: a table's columns, a template's
  SQL. What you've chosen before comes first. It all comes from what AirSQL already read of the schema: nothing is sent to
  the server while you type.
  - A name matches by its start, a word in it (`cust` finds `old_customers`), an abbreviation of its words (`fica` finds
    `film_category`, `ob` finds `ORDER BY`) or its middle. Keywords of several words come as one, in the case Settings ▸
    Format sets, and words already in the text come last.
  - After FROM or JOIN: tables, views and the statement's CTEs. A table comes with an alias (`orders o`) unless you turn
    that off in Settings ▸ Editor. After JOIN the joins come first: those of foreign keys, real or defined by you, then
    those names suggest (`customer_id` to `customers.id`). After ON, the condition.
  - Columns come from tables, CTEs and subqueries alike, with the table's name when two have the same one; `alias.` lists
    that table's. ORDER BY, GROUP BY and HAVING offer the aliases of the select list too.
  - `SELECT nam` with no FROM yet offers every table's columns: choosing one adds its FROM.
  - Just after `*` or `t.*` in a select list, the list offers all the columns in its place.
  - `INSERT INTO t (` offers the whole column list, then each column left. `VALUES (` offers a field for each column.
  - After `status = ` or inside `status = '` an ENUM or SET column offers its values. `ENGINE=`, `CHARSET` and `COLLATE`
    offer theirs, CALL the procedures, `@` the variables of the text, `@@` and SET the common server variables.
- **Templates.** Type an abbreviation at the start of a statement and press Tab: `sel`, `selw`, `selc`, `lim`, `ins`, `upd`,
  `del`, `tab`, `view` and `col` turn into the statement, with its first field selected. Type over a field; Tab or Return
  goes to the next and on to the end, ⇧Tab goes back, Escape stops. A field used twice takes a caret in each place.
- **Postfix.** Type a table's name and a dot at the start of a statement: `orders.from` turns into `SELECT * FROM orders`,
  `.cfrom` lists its columns, `.afrom` lists them by an alias, and `.join` adds the table its foreign key points at.
  `total.cast` puts CAST around a column, anywhere.
- **Snippets** keep SQL to use again. **Query ▸ Save as Snippet…** saves the selection or the statement, with a name, a
  folder and an abbreviation of your own. In the SQL, `$name$` is a field, `$END$` is where the cursor ends, `$SELECTION$`
  the selected text and `$$` a dollar. They're kept in AirSQL's settings on this Mac. A snippet with `$SELECTION$` is also in
  **Edit ▸ Surround With**.
- **View ▸ Query Helpers** shows beside the editor the columns of the tables the statement at the cursor names (or of the
  table selected in the tree, when it names none), the server's functions by kind, the keywords, your **Snippets** and the
  built-in ones, and the connection's **History** by day, each with a bar as long as it took. Double-click one to put it
  in at the cursor, or drag it into the editor (a column's name comes quoted where it needs to be, as completion puts it
  in). Right-click a snippet to edit or delete it; editing a built-in one makes a copy of your own.
- **Edit ▸ Find** (⌘F) and **Find and Replace** (⌥⌘F) find in the editor, with **Regular Expression**, **Match
  Case**, **Whole Words** and **In Selection** (the text selected when you tick it). With a regular expression, `$1`, `$2`… in the replacement put in its groups. **Replace All** is one change
  that **Undo** takes back.
- Typing `(`, `[` or a quote adds its partner, or wraps the selection; typing the partner steps over it, and Delete
  between an empty pair takes both.
- **Paste into `IN ()`**: with the cursor or a selection between the brackets of an `IN`, several values on the clipboard
  (a column or row of a grid, cells from Excel, lines of a text file, or a line split by commas) go in as `'a', 'b', 'c'`,
  with a comma added if the brackets hold values already. Every value is quoted, so a text column compares as text and a number
  column still uses its index; numbers stay bare when the column on the left is a number in the schema AirSQL has read.
  Blank lines drop out, spaces around values go, `NULL` stays text, and a list that's already quoted stays as it is. When
  there are lines or tabs, a comma inside a value is the value's own. One value, or a subquery, pastes as usual, and one
  **Undo** takes the paste back. **Edit ▸ Paste Without Formatting** (⌥⇧⌘V) always pastes the text just as it was copied.
- Text pasted inside a `'string'` is escaped so its quotes don't end the string; **Paste Without Formatting** keeps it as copied.
- Return after `(` indents one level, and between `(` and `)` puts the `)` on a line of its own.
- The `BEGIN` or `CASE` and `END` of a block are marked when the cursor is on one of them.
- **Edit ▸ Surround With** wraps the selection or the word at the cursor in brackets, a subquery, `CASE`, `COALESCE` or backticks.
- **Edit ▸ Paste from History** lists the last ten texts you copied or cut in an editor. They're kept in memory only, until you quit.
- **Edit ▸ Go to Line…** (⌃G) goes to the line a message names. Long lines wrap at the editor's edge; **View ▸ Word Wrap**
  (also in Settings ▸ Editor) turns that off, for sideways scrolling.
- **Edit ▸ Comment Lines** (⌘/) comments the selected lines out with `--`, or takes the comment away. **Shift Right**
  (⌘]) and **Shift Left** (⌘[) indent; so do Tab and ⇧Tab on several lines.
- **Edit ▸ Lines** works on the selected lines, or the cursor's: **Duplicate Line** (⌃D), **Delete Line** (⌃⇧K), **Move Line Up** and
  **Down** (⌥⇧↑, ⌥⇧↓), **Join Lines** (⌃⇧J; a line ending in a `--` comment, or a line break inside a string, stays), **Sort Lines** and
  **Reverse Lines**. ⌘C with nothing selected copies the line.
- **Edit ▸ Statements** has **Next Statement** and **Previous Statement** (⌃⌥↓, ⌃⌥↑), **Select Statement** (⌃⌘A) and **Move Statement
  Up** and **Down** (⌃⇧↑, ⌃⇧↓). **Extend Selection** (⌥↑) grows the selection by syntax: the word, the list item or condition, the
  clause, the brackets, the statement, then everything; **Shrink Selection** (⌥↓) takes those steps back.
- **Edit ▸ Comment Selection** (⌥⌘/) puts `/* */` around the selection, or takes it away. **Toggle Case** (⌃⇧U) puts the selection or
  the word at the cursor in capitals, or in small letters. **Complete Statement** (⌃⇧↩) closes its brackets, adds its `;` and starts a
  new line.
- **Edit ▸ Carets** lets you type in several places at once. **Select Next Occurrence** (⌥⌘G) selects the word at the cursor, then
  adds a caret at each next place its text appears; **Select All Occurrences** (⌃⌘G) does them all. **Add Caret to Each Line** (⌃⇧G)
  puts one at the end of each selected line, **Add Caret Above** and **Below** (⌃⌥⇧↑, ⌃⌥⇧↓) one on the next line, and ⌥⇧-click one
  where you click. ⌥-drag selects a block, as does a plain drag in **Column Selection Mode** (⌘*), where ⇧↑ and ⇧↓ add carets too.
  Typing, deleting and moving happen at every caret. Copy takes a line from each, and Paste gives each caret its line when the
  counts match. Escape, or a click, goes back to one caret.
- **Folding**: a triangle in the margin marks what can fold: a statement, brackets or a comment of several lines, or the lines between
  `-- region` and `-- endregion`. Click it, or use **Edit ▸ Folding**: **Fold** and **Unfold** (⌃⌥←, ⌃⌥→), **Fold All** and **Unfold All**
  (⌃⌥⇧←, ⌃⌥⇧→). The text stays whole: Run, Copy, Find and Save see all of it, and a click on **…**, moving the cursor into a fold, or an
  edit touching it opens it.
- The cursor's line has a band and, when the text has several statements, the statement it's in has a light shade: that's what ⌘↩
  runs. Other uses of the name at the cursor are marked, and its line and column show in the editor's corner.
- Settings ▸ Editor sets the font, the text size, the width of a tab and whether Tab puts in a tab character or spaces.
- **Query ▸ Format SQL** (⌥⇧⌘F) tidies the selection or the whole text: each clause on a line, subqueries indented, AND
  and OR on lines, CASE, VALUES rows, CREATE TABLE's columns and routine bodies laid out, by the rules of **Settings ▸
  Format**. It changes only spaces and the case the rules ask for: values, comments and `/*! … */` code stay exactly as
  they are. If it couldn't prove that, it leaves the SQL as it was and says so. Nothing changes between `-- @formatter:off`
  and `-- @formatter:on`.
- Settings ▸ Editor can also give reserved words their case as you type.
- **View ▸ Bigger** (⌘+), **Smaller** (⌘−) and **Actual Size** change the text size for a moment; Settings ▸ Editor
  sets it for good.

### Bookmarks

**Edit ▸ Bookmarks ▸ Toggle Bookmark** (F3) marks the line at the cursor with a dot beside its number, and the mark stays on
that line as you edit around it. **Next Bookmark** (⌥F3) and **Previous Bookmark** (⌥⇧F3) go from one to the next. Marks
last until the tab closes.

## Checks while you type

AirSQL parses your SQL as you type and compares it with the schema it has read. Nothing is sent to the server, and it's
only advice: **Run** still runs. Red marks what the server will refuse, yellow what will run but probably not as you
meant, and dotted grey what could be tidier. Hovering over an underline says why, marks beside the scroller show where
the problems are, and **Query ▸ Code ▸ Next Problem** (⌥F2) and **Previous Problem** (⌥⇧F2) go through them.

It looks for:

- Syntax errors, such as a missing table after FROM or WHERE after ORDER BY.
- Tables, columns and procedures that aren't in the schema, inside subqueries, WITH queries and derived tables too; a
  column in two joined tables; an alias used twice; a subquery in FROM with no alias.
- `= NULL`, which is never true; `COUNT (*)` with a space, which MySQL refuses; the wrong number of arguments to common
  functions; aggregates in WHERE, ON or GROUP BY, or inside each other; columns that aren't in GROUP BY.
- INSERT rows that don't match the columns; NULL into a NOT NULL column; a value for a generated column.
- UPDATE and DELETE without WHERE, or joined without ON; writes on a read-only connection, which AirSQL will refuse.
- WITH queries nothing reads, conditions that are always the same, and a redundant ASC, ELSE NULL or alias.

When AirSQL isn't sure it says nothing: a database whose details aren't loaded yet, temporary tables and tables made or
altered in the same text or session, code in `/*! … */` comments, and routine bodies. Turn any check off in
**Settings ▸ Editor**. If a table is new, **Refresh** the schema and the underline goes.

Small grey notes in the text say which column each INSERT value goes to, what a `*` stands for, and whether a JOIN meets
one row or many (`1:n`, from the foreign keys). They aren't part of the text: they're never copied, saved or run.

## Work with the code

Everything here is in **Query ▸ Code**, and none of it changes anything on the server.

- **Fixes and Actions…** (⌥↩) lists what can be done at the cursor: the fixes for what's underlined there (the closest
  name for a typo, `IS NULL`, qualifying an ambiguous column, refreshing the schema, writing the ALTER TABLE for a
  missing column), and changes such as quoting or qualifying a name, adding a table alias, expanding `*` to its columns,
  moving a subquery to WITH, and splitting or merging INSERTs or removing one of their columns. Each is one step of Undo.
- **Go to Declaration** (⌘B) jumps to where an alias or WITH query is declared, and opens a table or routine.
- **Find Usages…** (⌥F7) lists every place in the text that means the name at the cursor. The other places are also
  tinted when you stop on a name, and BEGIN, CASE and IF are tinted with their END.
- **Rename Name…** (⇧F6) changes an alias, WITH query, column alias or `@variable` everywhere it's used. On a table or
  column it changes the text and writes the `RENAME TABLE` or `ALTER TABLE … RENAME COLUMN` above the statement, for you
  to read and run.
- **Quick Documentation** (F1) shows a table's columns and keys, a column's type and default, or a function's signature.
  Pausing the mouse over a name shows the same.
- **Parameter Info** (⌥⌘I) shows what each argument of a call is for, or which column each value of an INSERT row goes
  to, with the one at the cursor in bold.
- **Preview Rows to Change** (⌥⌘↩) shows, as a result, the rows the UPDATE or DELETE at the cursor would touch, with an
  UPDATE's new values first, up to 1,000 of them. Only a SELECT runs.

## Run it

| To run | Press |
|---|---|
| The statement at the cursor, or the selected text | ⌘↩ (or ⌃F9) |
| Only the selected text | Query ▸ Run Selection |
| The selected text as it stands, not split on `;` | Query ▸ Run Selection as One Statement |
| The smallest query in brackets around the cursor | Query ▸ Run Subquery |
| The statement at the cursor and every one after it | Query ▸ Run from Cursor |
| The rows of a SELECT, straight to a .csv, .tsv or .json file | Query ▸ Run to File… |
| Every statement | ⇧⌘↩ (or F9) |
| Stop the statement that is running | ⌘. (Query ▸ Cancel) |

The ▶ beside the line numbers, at the start of the statement at the cursor, runs it too.

The statement that ran is highlighted for a moment, so there is no "which statement?" question. Statements are split
on `;`, or on the delimiter a `DELIMITER` line sets, and sent one after another. If one fails with others to come, a
sheet asks whether to **Stop**, **Retry** it, **Skip** it, or **Skip All** that fail from there on. Each
statement that ran then shows a tick, or a cross if it failed, and its time at the end of its line, until you change it
or run again.

While a statement runs, the bar above the results shows which one and for how long, with **Cancel**; the status bar
lists it too. Cancel stops only that statement: AirSQL checks the server is still running it before it stops it. A
connection can have a query timeout: a statement that runs longer is stopped the same way, and Messages says so.
The time shown covers the whole run: waiting its turn, the server's work and fetching every row. After an `UPDATE`,
Messages counts the rows changed; the server's note beside it says how many matched.

If you've gone to another app and a run of 10 seconds or more ends, AirSQL's Dock icon bounces once and a notification
says which tab finished. It never shows the SQL. Turn the notification off in System Settings ▸ Notifications.

### Parameters

A statement with `?`, `:name` or `${name}` in its code, not in a string or comment, asks for their values before it runs.
The same name takes one value. A number or `NULL` goes in as it is; anything else goes in as quoted text, so a value can't
become code. The tab remembers the values for the next run. AirSQL fills them in before sending, so Messages, the SQL
log and the history show the final SQL, and the read-only and safety checks see it too.

### Sessions

Each query tab opens its own session the first time it runs something, and closes it when the tab closes. So each tab
has its own transaction and current database, and several tabs can run at once; Cancel stops only the tab's own
statement. A temporary table belongs to one session, so another tab can't see it.

To see temporary tables across tabs, turn on **Query tabs share one session** on the connection's Options tab. The
connection's query tabs then use one session, with one transaction and one database, and while one runs a statement the
others wait.

If the server is within five connections of its `max_connections`, or refuses another, a tab shares the connection's
main session instead of opening its own, and Messages says so.

If a tab's session ends without you closing it (the connection drops, or Disconnect takes an open transaction or Manual Commit with it),
the tab says so in Messages and the status bar, with how many rows the server rolled back. Nothing runs in that tab until
you press **Open New Session** in the sheet Run shows. A tab that was in Manual Commit stays in it.

### The current database

Statements run in the tab's current database, which the toolbar's database pop-up shows and the sidebar shows in bold
while the tab is on show. Choose another in the pop-up, double-click one in the sidebar, or type `USE`: all three change
it for the tab on show, and the other tabs keep theirs. A new tab starts in the database shown. A database chosen in the
pop-up or the sidebar is made current with `USE` just before the next statement runs (Messages shows it), so a run under
way is never switched midway; if that `USE` fails, nothing runs. On a connection whose tabs share one session, they
share the current database too.

## Results and Messages

- Each result set gets a **result tab** under the editor, named after the comment just above its query (`-- Top
  customers` names it "Top customers"), else "Result 1", with its rows and columns. The next run replaces the result
  tabs, unless you **pin** one (right-click it, or Query ▸ Pin Result); a result with edits not yet applied stays too.
  A tab's ✕ closes it. **Query ▸ Show Next Result** (⌥⌘]) and **Show Previous Result** (⌥⌘[) move along the tabs,
  Messages included.
- **Query ▸ Run Result Again** (⇧⌘R) runs the shown result's statement once more and puts the new rows in its tab,
  which keeps its name and pin. **Copy Result's Query** copies the statement. **View ▸ Refresh Every** does it every few
  seconds, for a statement that only reads, until it fails or you choose Off.
- **Open Result in Window** moves a result to a window of its own, to keep beside the query. Closing it with edits not
  applied asks first.
- **Query ▸ Keep Results of Each Run** leaves the tab's earlier results in place at each run.
- Double-click a result tab to rename it; right-click it to run it again, pin, rename or close it, export its rows, or compare it
  with another result or a table (**Compare With…**, see [Compare](compare.md#compare-two-results-or-a-result-with-a-table)).
  When more tabs are open than fit, scroll the tabs sideways.
- **Messages** lists when and what each statement did: its rows or the rows it changed, how long it took, the server's
  warnings, or its error and the line it points to (that line is marked red beside the editor, the place the server
  names is underlined in red, and hovering over it shows the message, until you change the text). Double-click a message
  to select its statement.
- A result keeps at most its first 100,000 rows (**Settings ▸ Grid ▸ Most rows in a result**); the tab then says it is cut short.
- **Edit ▸ Find** (⌘F) with a result's rows focused finds values in them, as in a [table tab](table-data.md): ⌘G and ⇧⌘G
  move between matches, and Options has Match Case, Regular Expression, Whole Words and Filter Rows. Replace is for
  table tabs.
- **Filter, search and sort a result** on its rows, at once, without running the query again: right-click a cell for
  **Quick Filter** (the same conditions as in a [table tab](table-data.md#filter-search-and-sort), Type a Value…
  included), a header for **Filter by Values…** (the values in the rows shown, with their counts) or **Add to Sort**
  and **Sort by Columns…** (⇧-click a header's arrow adds to the sort too), or click a value in **Column Summary…**. **Data ▸ Search All Columns** (⇧⌘E) keeps the rows with the text
  in any column and tints it. A bar over the rows shows while a filter or a search is on: **Local · 12 of 200 rows**,
  the conditions as SQL, and the search; its ⓧ or **Data ▸ Clear Filter** shows every row again. Copy and Export Rows…
  take the rows shown. The **?** at the right of the result tabs opens [Read the data in a grid](data-grid.md).

### Edit a result

The rows of a `SELECT` from one table can be edited when the result includes the table's key (its primary key, or a
unique key whose columns can't be NULL); so can an inner join's when every table's key is in it. The status bar says
**Editable** or **Read-only**, with the reason in its tooltip; double-click a read-only cell to see why (an outer join,
`GROUP BY`, `DISTINCT`, `UNION`, a subquery in `FROM`, a self-join, a column worked out by the query, or a row of the
"one" side of a join that shows in several result rows).

- Double-click a cell (or start typing) to change it. As in a table tab, a boolean toggles, ENUM and SET pick from their
  members, ↑ and ↓ step a date, and a foreign key has its drop-down. **Cut** (⌘X), **Paste** (⌘V), **Set NULL** (⌥⌘N),
  **Set DEFAULT**, **Insert Value** and, in a one-table result, **Delete Rows** (⌘⌫) work too. Paste fills the rows the
  result has, and pastes nothing if a value doesn't fit its column. Values are checked by their column's type as you type. Changes wait, marked in colour,
  with a bar over the rows counting them; **Undo**, **Redo**, **Revert** and **Revert All** take them back.
- **Apply** (⌘S while the rows have the keyboard, or the bar's button) writes them in one transaction on the
  connection's data session, each statement checked to change exactly its row. A join's changes always show the SQL
  first; so do changes on connections whose **Settings ▸ Safety** asks for the preview, and deletes that cascade. If the query tab has a transaction open, Apply asks you to commit or roll it back first, so it doesn't wait for its locks.
- After Apply, the edited rows are read back from the server, so the result shows what was stored; deleted rows go.
  New rows and pasting are for a table tab: open the table to add rows.
- Edits not applied are never discarded unasked: the next run keeps their result tab, and disconnecting asks first;
  so do closing the result, closing the query tab and quitting, unless the connection's Safety settings don't warn on
  close.
- On a read-only connection nothing can be edited.

### Edit INSERT statements as a table

Select one or more `INSERT … VALUES` statements of one table (or put the cursor in one) and choose **Query ▸ Edit as
Table** (also in the editor's right-click menu). The table opens in its tab with each row as a new row, a pending
change: strings and numbers as their values, `NULL`, `DEFAULT`, and anything else (such as `NOW()`) as SQL the server
works out. Change them as you like, then **Apply**: it always shows the SQL first. Nothing runs from the query tab.

## Transactions

- **Auto-commit** (the toolbar's transaction pop-up, or Query ▸ Transaction Mode) commits each statement by itself. In
  **Manual**, your changes wait in a transaction until you press **Commit**, or **Roll Back** to undo them. Leaving
  Manual with changes waiting asks first whether to commit them or roll them back.
- The **isolation level** (in the transaction pop-up, or Query ▸ Isolation Level) sets how the tab's transactions see
  others' changes: Read Uncommitted, Read Committed, Repeatable Read or Serializable, set on the tab's session with
  `SET SESSION TRANSACTION ISOLATION LEVEL`. Until you choose one, the server's own applies (usually Repeatable Read).
- The toolbar's Run, Commit, Roll Back and Cancel are on only when the query tab can do them now; when one is off, its
  tooltip says why (not connected, no transaction open, nothing running).
- While a transaction is open, the status bar says so, with the number of rows changed, and how long it has been open
  once that passes the time set in Settings ▸ Safety.
- Closing a query tab with a transaction open asks first: **Commit**, **Roll Back** or keep the tab. On a connection
  whose tabs share one session, only its last tab asks.
- New sessions start in Auto-commit at the server's isolation level, unless the connection's Options tab says **Start
  query tabs in Manual Commit** or chooses an **Isolation level**.
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

- **Query ▸ Query History** (⌘Y) lists the statements run on the tab's connection, newest first. Type to search;
  Return or a double-click puts one in the editor at the cursor, and a click shows it whole below the list. Click a
  header to sort, ⌘-click to select several; a right-click also opens them in a new tab or deletes them from the
  history. Passwords in statements are masked before they are kept, as in the SQL log. **All connections** searches
  every connection's statements, with a column saying which.
- **File ▸ Local History…** lists the states a .sql file was saved in (the last 50, kept on this Mac only). Click one to read
  it, with the lines that differ from the editor tinted; **Restore** puts it in the editor, ⌘Z takes it back, and nothing is written until you save.
- **Query ▸ Sessions…** lists every session AirSQL has open on the connection: what uses it, its thread on the server, its
  database, and whether it is running or holds a transaction.
- **View ▸ SQL Log** (⌥⌘L) shows or hides every statement AirSQL sent, as they come, under the tabs. See [the SQL log](sql-log.md).
- **Query ▸ Explain** (⌥⌘E) shows how the server would run the statement at the cursor, without running it. **Operations**
  lists the steps as a tree with the server's rows and cost; click a header to sort the steps of each level, and the
  steps that take a large share are marked in orange; select a step to read all the server says about it. **Diagram** draws
  the steps as boxes, and **Flame** as bars as wide as their time, or their cost before Explain Analyze. **Table** is the server's EXPLAIN, **Tree** the steps as text and
  **Raw** the server's own answer, to copy.
- **Query ▸ Explain Analyze** (⌥⇧⌘E) runs the statement and adds what really happened: rows read, time and loops. It uses
  `ANALYZE FORMAT=JSON` on MariaDB and `EXPLAIN ANALYZE` on MySQL 8.0.18 or later. As it really runs the statement, a
  read-only connection refuses it, and a statement that may write always asks first.
- **Query ▸ Profile** runs the statement and shows where the server spent its time. On MySQL 8 and later it reads
  performance_schema: the statement's stages where the server records them, else its own figures (time, lock time,
  rows examined and sent, temporary tables, sorts and full scans). Elsewhere it shows SHOW PROFILE's steps, as it does
  on MySQL 8 when performance_schema is off or your login can't read it, with a note saying so.
- **Query ▸ Save as Changeset…** saves the selected statements (or the one at the cursor) as a Liquibase changeset in a
  changelog you choose. See [Liquibase changelogs](liquibase.md).
