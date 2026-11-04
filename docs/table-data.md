---
title: A table's rows
nav_order: 12
---

# A table's rows

A table tab shows a table's or view's rows in the data grid. They load a page at a time from the connection's data
session, a session of their own, so a long query in a console never holds them up. Edits wait until you apply them.

## Load rows

- The first page loads when the tab opens: **Settings ▸ Grid ▸ Rows per page** rows (1,000 at first), in the table's
  key order, so pages follow one another.
- The status bar says how many rows are loaded and of how many: `1,000 of about 52,000 rows`. The total is the server's
  estimate until you click **Count Exactly** (**Data ▸ Count Rows Exactly**), which runs `COUNT(*)` with the filter.
  An estimate below what has already loaded is left out (InnoDB's can say 0 of a million rows), and with no figure to go
  by, Load All and an unindexed sort ask first. After the count comes the time the rows were read: `· read 14:32`.
- **Load More** (⌥⌘↓) loads the next page; **Load All** (⌥⇧⌘↓) loads every row that's left, in batches as they arrive.
  Above **Settings ▸ Grid ▸ Load All asks above** rows (100,000 at first) it asks first: every row is held in memory
  while the tab is open. Cancel it in the status bar's activity: what arrived stays, and Load More and Load All carry
  on from there.
- Anything slow here (a page, a filter, a sort, Load All, Count Exactly, Column Summary) can be stopped with **⌘.**, the
  toolbar's Cancel or the status bar's activity. A cancelled page leaves the rows as they were; Refresh (⌘R) loads them.
- Pages are read by offset. If someone adds or deletes rows between pages, a row can repeat or be missing: a notice says
  so when it happens, and Refresh reads the rows again.
- **View ▸ Refresh** (⌘R) reads the table's columns and loads the rows shown again; **View ▸ Refresh Every** does it by itself every 5 to 60 seconds,
  until you choose **Off**. Pending changes stay.

## Filter, search and sort

The chip at the left of the grid bar always says where filtering runs: **On server** (every row of the table, loaded or
not) or **Local** (only the rows loaded so far, at once, with no query).

- **WHERE**: type a condition, for example `status = 'paid' AND total > 100`, and press Return. A leading `WHERE` is
  fine. It is coloured as SQL, as in the console, and the field grows as the condition wraps, up to eight lines (then
  it scrolls); ⌥↩ starts a new line. Suggestions show as you type: columns, then operators,
  then the column's values (read from its first 10,000 rows), then AND and OR. ↑ and ↓ choose, Tab inserts, ⎋ closes, and
  ⌥⎋ brings them up anywhere. The clock (or ⌥↓ in the field) lists the table's last
  20 filters; the ⓧ, or **Data ▸ Clear Filter**, shows every row again. The filter and the sort are kept for the next
  time the table opens. On a read-only connection, the whole SELECT must pass the
  [read-only check](read-only-queries.md): a condition that calls a function such as `SLEEP` or `GET_LOCK` isn't sent,
  and the bar under it says why. The **?** at the bar's end opens [Read the data in a grid](data-grid.md).
- **Search all columns** (⇧⌘E) finds rows with the text in any column, as HeidiSQL does: text and JSON columns with
  `LIKE`, numbers and dates as text, binary columns by a whole `0x…` value. Tick **Loaded rows only** to search just the
  loaded rows instead.
- **Quick Filter**: right-click a cell for `=`, `<>`, `<`, `>`, `LIKE` (starts with, ends with, contains), `IS NULL` and
  `IS NOT NULL` with its value, and `IN` / `NOT IN` with every value selected in its column. Each item shows its SQL.
  Hold ⌥ to add the condition to the current filter with `AND`. The clipboard's text is offered too. **Data ▸ Quick
  Filter** has the same conditions by name (Less Than Selection, Contains Selection, In Selected Values…); ⌃⌘1 and ⌃⌘2
  filter by the focused cell's value, equal and not equal.
- **Type a Value…** (in both Quick Filter menus) asks for the value: choose how to compare (`=`, `<>`, `<`, `>`, starts
  with, contains, ends with), type the value, and press **Filter**. Tick **Add to the current filter** to keep the
  filter there is and add the condition with `AND`.
- **Filter by Values…** (the funnel on a column's header, shown on hover and on a filtered column; **Data ▸ Filter by
  Values…**; or a header's menu): the column's values with how many rows have each, counted on the server within the
  current filter (the 1,000 most frequent). Tick the ones to show, or type part of a value and press **Contains**. The
  funnel opens over the rows and replaces its own earlier choice, so you can widen it again. In
  **Column Summary…**, a click on one of a column's most frequent values adds it to the filter.
- **Sort**: the arrow at a header's right sorts by that column, ascending, then descending, then not at all; ⌥-click it
  to add the column to the sort. **Data ▸ Sort by Columns…** (or a header's menu) sets several at once: a line per
  column, each **Ascending** or **Descending**; the arrows move a column up or down the order, **Add Column** adds one
  and the minus takes it away. Rows sort on the server, and rows the sort leaves equal go in key order, so pages never
  repeat or miss a row (a view or a table without a key has no such order). On a table of over a million rows, sorting
  by a column without an index asks first (**Settings ▸ Safety**, on at first). With **Loaded rows only** ticked, the
  loaded rows sort here instead.
- **Find** (⌘F) and **Find and Replace** (⌥⌘F) work on the loaded rows: ⌘G and ⇧⌘G go to the next and previous match,
  the bar says `3 of 12`, and every match is tinted, as are the cells Search All Columns found. **Options** has Match
  Case, Regular Expression (`$1` in the replacement), Whole Words and Filter Rows, which hides the loaded rows without a
  match. Replacements are pending edits, like any other.

## Edit rows

Nothing is written until you apply. Leaving a row writes nothing.

- **Edit a cell**: type over it, double-click it, or press Return or F2 (as in HeidiSQL). Return keeps the edit, Esc
  cancels, Tab moves to the next cell. Select several cells and type: each gets the value its column takes. Record View and Transpose edit
  the same way.
- **Values are checked as you keep them**, by the column's type and the server's sql_mode, as Apply will write them: a
  number too big for its column, a third decimal in `DECIMAL(10,2)`, a day the month doesn't have, a word that isn't
  one of an ENUM's. The editor then stays open and says why under the cell: fix the value or press Esc. Typing is never
  blocked, and numbers and DECIMAL travel as the text you typed, so nothing is rounded on the way.
- **Each type has its editor**:
  - BOOLEAN, TINYINT(1) and BIT(1) show a checkbox. Space, Return or a double click ticks or clears it; typing `t`,
    `f` or `n` sets true, false or NULL.
  - An ENUM shows its values in a list over the cell; a SET a checklist, where **Set** keeps the ticked ones. Typing
    still works: `read,write`.
  - Dates and times are typed as `YYYY-MM-DD hh:mm:ss`, with fractional seconds when the column keeps them; ↑ and ↓
    step the part under the cursor (the day, the hour…). Zero dates are kept where sql_mode allows them, TIMESTAMP
    values are in the session's time zone, and a NULL cell starts empty: it never fills in today's date.
  - Bytes (BINARY, BLOB, shapes) are typed as hex: `0x00FF`. BIT shows and takes every bit: `b'1010'` or `1010`.
  - A value of more than 256 characters, or of several lines, opens in the value panel (below).
  - A foreign key shows the rows of the table it refers to, each as "label (key)", the label being that table's
    first text column, or the one you chose with **Use as Label** (below). They are searched on the server as you
    type, by label or by key, 100 at a time, so a big table is never listed whole. Return or a double click puts the
    key in the cell. **Data ▸ Choose Referenced Row…** opens the same list.
- **The value panel** (⇧↩) edits the selected cell too: ⌘↩ or clicking elsewhere keeps the text as a pending edit,
  Esc puts the cell's value back. A value the column refuses stays there, and the panel says why. Its **⋯** menu has
  **Format JSON** and **Compact JSON**, **Load from File…** (a file's bytes in a binary column, else its UTF-8 text)
  and **Save to File…**.
- **Data ▸ Insert Value** (and a cell's right-click menu) puts in a value the server works out when Apply runs:
  `NULL`, `DEFAULT`, `NOW()`, `UTC_TIMESTAMP()`, `CURDATE()`, `CURTIME()`, `UNIX_TIMESTAMP()`, `UUID()`, `UUID_SHORT()`
  or a random value, whichever fit the column. Until then the cell shows it in grey: `ƒ NOW()`.
- **Data ▸ Add Row** (⌘I) adds a new row after the loaded ones. Where the server fills a value in, the new row says so
  in grey: *auto* (AUTO_INCREMENT), *default*, *generated*. **Duplicate Row** (⌘D) copies the selected rows, and
  their AUTO_INCREMENT columns show *auto* for the server to number; **Duplicate Row Without Keys** (⇧⌘D) leaves every
  key column to the server too.
  **Delete Rows…** (⌘⌫) marks the selected rows for deletion. **Set NULL** (⌥⌘N) and **Set DEFAULT** set the selected
  cells.
- **Edit ▸ Paste** (⌘V) puts cells copied from Excel, Numbers or a grid (tab-separated, or CSV) into the cells from the
  selected one on, as pending edits: numbers with a comma for decimals and dates such as `31.12.2026` or `12/31/2026`
  are read the way the column's values are written. Rows past the last loaded one become new rows, and one value pasted
  over several selected cells fills them all. Cells that can't go in their column are listed first, so you can paste
  the others or nothing. **Data ▸ Paste as New Rows** adds every copied row as a new one. A cell reading `NULL` (the
  grid's NULL text) is NULL.
- When the copied cells could be read two ways, the **Paste Format** sheet asks first, starting from AirSQL's guess:
  what separates the cells (lines of commas or semicolons without tabs may be CSV), the decimal mark (numbers such as
  `1,234`), and the order of day, month and year (dates such as `03/04/2026`). **Data ▸ Paste with Format…** always
  asks.
- **Data ▸ Related Rows** (⌃⌘↓) lists the row a foreign key cell points to and the rows of other tables that point to
  the selected row; choosing one opens that table filtered to them.

### Foreign key labels and virtual foreign keys

- A one-column foreign key's cell shows the row it refers to in grey after its value (before it, for a number): the
  referenced table's label, read from the server for the rows on screen only. Right-click a column header of the
  referenced table and choose **Use as Label** (also in the Data menu) to show that column instead of its first text
  column; choose it again to go back.
- Many schemas have no real foreign keys. Right-click a column header and choose **Add Virtual Foreign Key…** to say
  which table's key the column holds (AirSQL guesses from the name: `customer_id` → `customers`). AirSQL keeps it on
  this Mac with the table's view settings, never in the database. The drop-down, Related Rows (both ways), the labels
  and the [ER diagram](editors.md#the-er-diagram) then follow it as a real foreign key. **Remove Virtual Foreign Key**
  forgets it.
- Pending changes have their colours: an edited cell amber, a new row green, a row to delete struck through in red.
  The bar under the grid bar counts them.
- **Undo** (⌘Z) and **Redo** (⇧⌘Z) step through the pending changes (a paste or a multi-cell edit is one step);
  **Revert** (⌥⌘Z) throws away the selected rows' changes, **Revert All** every one.
- Pending changes are kept on disk as you make them. If AirSQL quits or the Mac restarts, they come back the next time
  you open the table, marked "Kept from before".
- Closing the tab with pending changes asks whether to keep them for later or throw them away. Quitting AirSQL lists,
  in one sheet, the tables with pending changes and any console transaction still open (which is rolled back).

### Which tables can be edited

AirSQL addresses each row by its primary key, or, without one, by the first unique key whose columns can't be NULL. Key
values are never shortened, so a change always reaches exactly its row. A table with neither is read-only, and the bar
says why; so are views. Generated columns can't be edited.

## Apply changes

- A table a single click shows, in the preview tab, keeps its pending changes when you click another table: the tab
  stays open with its dot, and the next table gets a preview of its own.
- **Data ▸ Apply Changes** (⌘S) writes every pending change in one transaction on the data session: deletes first (in
  batches of 500), then edits, then new rows. Each edit's `UPDATE` names the row by its key and the edited cells by the
  values you loaded (`` `price` <=> 10 ``), and each statement must change exactly its rows. If one changes another
  number (someone else changed a cell you edited, or deleted the row, since it was loaded) or the server refuses one,
  everything is rolled back, nothing is applied, and the grid selects the row; when the server's error names a column
  ("Data too long for column 'note'", "Column 'name' cannot be null", a duplicate value of a unique key), it selects
  that cell. Fix the value and apply again; if someone else got there first, revert the change, reload the rows and
  make it again. Changes kept over a restart are checked the same way.
- What Apply can't check: FLOAT, TIMESTAMP, JSON, spatial and vector values, dates with a zero month or day and values
  over 64 KB don't compare exactly, so edits to those go by the key alone and overwrite what is there; the preview
  names them. A change that only differs in case or trailing spaces can pass on a column whose collation ignores
  those. Rows to delete go by their key: someone else's change to a row doesn't stop its delete, and neither does a
  change to a column you didn't edit stop your edit.
- **Preview SQL…** shows the statements first, in the [SQL preview](sql-preview.md). The preview also comes first on
  connections where **Settings ▸ Safety ▸ Show the SQL before the grid's Apply** is on (every Production connection),
  and whenever there is a warning: a table on MyISAM, Aria, MEMORY or another engine that can't roll back, or deletes
  that also change other tables through `ON DELETE CASCADE` or `SET NULL`.
- Values are checked again as Apply writes them; one that no longer fits (sql_mode changed, or it came from a find
  and replace) stops Apply before anything runs, and the grid selects its cell.
- After Apply, new rows stay where they were and show what the server filled in, their AUTO_INCREMENT key (the insert
  ID) and defaults included: each is read back by its key. When every row of the table (or of the filter) is loaded,
  the edited rows are read back by their keys and the deleted ones go, so nothing else loads again; otherwise the
  loaded rows load again. A new row's untouched cell shows **auto**, **default** or **generated**, in the value panel
  too, until Apply.

## Copy and export

These work in a console's results too.

- **Edit ▸ Copy** (⌘C) copies the selected cells in the format last chosen in **Copy As** (TSV at first); in a console
  result with nothing selected, every row. **Copy with Headers** (⌥⌘C) puts the column names first. Values are copied
  whole, as stored, whatever **Display As** shows. **View ▸ View As ▸ Text** shows the rows in the same format.
- **Edit ▸ Copy As** ▸ TSV, CSV, JSON, JSON Lines, Markdown, HTML Table, XML, SQL INSERT, INSERT IGNORE, REPLACE,
  UPDATE, DELETE or WHERE Clause. The SQL formats address rows by the key, and UPDATE and DELETE add any of it you
  didn't copy; without a key, by every column copied. The one you choose becomes ⌘C's format.
- **Data ▸ Export Rows…** (and a result tab's **Export Result…**) saves the selected rows, the loaded rows (with their
  pending changes) or every row of the table with its filter and sort, streamed from the server on a session of its own, as CSV, TSV, JSON, JSON Lines, SQL,
  Markdown, HTML, XML or an Excel workbook (.xlsx). Choose whether the column names come first, how NULL is written
  (`NULL`, `\N` or nothing) and Windows line endings, then **Export…** to a file or **Copy** to the clipboard.
  In a workbook, exact numbers over 15 digits (a 20-digit id, a long DECIMAL) go as text, as Excel would round them,
  and a value over Excel's 32,767 characters a cell is cut: AirSQL says how many were, and CSV keeps them whole.
