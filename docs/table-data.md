---
title: A table's rows
---

# A table's rows

A table tab shows a table's or view's rows in the data grid. They load a page at a time from the connection's data
session, a session of their own, so a long query in a console never holds them up. Edits wait until you apply them.

## Load rows

- The first page loads when the tab opens: **Settings ▸ Grid ▸ Rows per page** rows (1,000 at first), in the table's
  key order, so pages follow one another.
- The status bar says how many rows are loaded and of how many: `1,000 of about 52,000 rows`. The total is the server's
  estimate until you click **Count Exactly** (**Data ▸ Count Rows Exactly**), which runs `COUNT(*)` with the filter.
- **Load More** (⌥⌘↓) loads the next page; **Load All** (⇧⌥⌘↓) loads every row that's left, in batches as they arrive.
  Above **Settings ▸ Grid ▸ Load All asks above** rows (100,000 at first) it asks first: every row is held in memory
  while the tab is open. Cancel it in the status bar's activity.
- **View ▸ Refresh** (⌘R) loads the rows shown again; **View ▸ Refresh Every** does it by itself every 5 to 60 seconds,
  until you choose **Off**. Pending changes stay.

## Filter, search and sort

The chip at the left of the grid bar always says where filtering runs: **On server** (every row of the table, loaded or
not) or **Local** (only the rows loaded so far, at once, with no query).

- **WHERE**: type a condition, for example `status = 'paid' AND total > 100`, and press Return. A leading `WHERE` is
  fine. ⌥⎋ completes column names. The clock (or ⌥↓ in the field) lists the table's last 20 filters; the ⓧ, or
  **Data ▸ Clear Filter**, shows every row again. The filter and the sort are kept for the next time the table opens.
- **Search all columns** (⇧⌘E) finds rows with the text in any column, as HeidiSQL does: text and JSON columns with
  `LIKE`, numbers and dates as text, binary columns by a whole `0x…` value. Tick **Loaded rows only** to search just the
  loaded rows instead.
- **Quick Filter**: right-click a cell for `=`, `<>`, `<`, `>`, `LIKE` (starts with, ends with, contains), `IS NULL` and
  `IS NOT NULL` with its value, and `IN` / `NOT IN` with every value selected in its column. Each item shows its SQL.
  Hold ⌥ to add the condition to the current filter with `AND`. The clipboard's text is offered too. ⌃⌘1 and ⌃⌘2
  filter by the focused cell's value, equal and not equal.
- **Filter by Values…** (a column header's menu): the column's values with how many rows have each, counted on the
  server within the current filter (the 1,000 most frequent). Tick the ones to show. In **Column Summary…**, a click on
  one of a column's most frequent values adds it to the filter.
- **Sort**: the arrow at a header's right sorts by that column, ascending, then descending, then not at all; ⌥-click it
  to add the column to the sort. Rows sort on the server. On a table of over a million rows, sorting by a column without
  an index asks first (**Settings ▸ Safety**, on at first). With **Loaded rows only** ticked, the loaded rows sort here instead.
- **Find** (⌘F) and **Find and Replace** (⌥⌘F) work on the loaded rows: ⌘G and ⇧⌘G go to the next and previous match,
  the bar says `3 of 12`, and every match is tinted, as are the cells Search All Columns found. **Options** has Match Case, Regular Expression (`$1` in the replacement), Whole Words and
  Filter Rows, which hides the loaded rows without a match. Replacements are pending edits, like any other.

## Edit rows

Nothing is written until you apply. Leaving a row writes nothing.

- **Edit a cell**: type over it, double-click it or press Return. Return keeps the edit, Esc cancels, Tab moves to
  the next cell. Select several cells and type: they all get the value. Record View and Transpose edit the same way.
- **Data ▸ Add Row** (⌘I) adds a new row after the loaded ones; columns you leave alone get their default or
  AUTO_INCREMENT value, which the new row shows as `(auto)` or the default. **Duplicate Row** (⌘D) copies the selected
  rows, keys included; **Duplicate Row Without Keys** (⇧⌘D) leaves the key and AUTO_INCREMENT columns to the server.
  **Delete Rows…** (⌘⌫) marks the selected rows for deletion. **Set NULL** (⌥⌘N) and **Set DEFAULT** set the selected
  cells.
- Pending changes have their colours: an edited cell amber, a new row green, a row to delete struck through in red.
  The bar under the grid bar counts them.
- **Undo** (⌘Z) and **Redo** (⇧⌘Z) step through the pending changes; **Revert** (⌥⌘Z) throws away the selected rows'
  changes, **Revert All** every one.
- Pending changes are kept on disk as you make them. If AirSQL quits or the Mac restarts, they come back the next time
  you open the table, marked "Kept from before".
- Closing the tab with pending changes asks whether to keep them for later or throw them away.

### Which tables can be edited

AirSQL addresses each row by its primary key, or, without one, by the first unique key whose columns can't be NULL. Key
values are never shortened, so a change always reaches exactly its row. A table with neither is read-only, and the bar
says why; so are views. Generated columns can't be edited.

## Apply changes

- **Data ▸ Apply Changes** (⌘S) writes every pending change in one transaction on the data session: deletes first (in
  batches of 500), then edits, then new rows. Each statement must change exactly its rows. If one changes another
  number (someone else changed or deleted the row since it was loaded) or the server refuses one, everything is rolled
  back, nothing is applied, and the grid selects the row. Reload it, then apply again.
- **Preview SQL…** shows the statements first, in the [SQL preview](sql-preview.md). The preview also comes first on
  connections where **Settings ▸ Safety ▸ Show the SQL before the grid's Apply** is on (every Production connection),
  and whenever there is a warning: a table on MyISAM, Aria, MEMORY or another engine that can't roll back, or deletes
  that also change other tables through `ON DELETE CASCADE` or `SET NULL`.
- After Apply the rows load again, so new rows show their real ids.

## Copy and export

These work in a console's results too.

- **Edit ▸ Copy** (⌘C) copies the selected cells in the format last chosen in **Copy As** (TSV at first); in a console
  result with nothing selected, every row. **Copy with Headers** (⌥⌘C) puts the column names first. Values are copied
  whole, as stored, whatever **Display As** shows. **View ▸ View As ▸ Text** shows the rows in the same format.
- **Edit ▸ Copy As** ▸ TSV, CSV, JSON, JSON Lines, Markdown, HTML Table, XML, SQL INSERT, INSERT IGNORE, REPLACE,
  UPDATE, DELETE or WHERE Clause. The SQL formats address rows by the key columns copied, or by every column. The one
  you choose becomes ⌘C's format.
- **Data ▸ Export Rows…** (and a result tab's **Export Result…**) saves the selected rows, the loaded rows (with their
  pending changes) or every row of the table with its filter and sort, streamed from the server on a session of its own, as CSV, TSV, JSON, JSON Lines, SQL,
  Markdown, HTML, XML or an Excel workbook (.xlsx). Choose whether the column names come first, how NULL is written
  (`NULL`, `\N` or nothing) and Windows line endings, then **Export…** to a file or **Copy** to the clipboard.
