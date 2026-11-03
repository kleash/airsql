---
title: Read the data in a grid
---

# Read the data in a grid

A table's rows and a console's results show in the same grid. These pages of it help you read what is there: the
status bar's figures, the value panel, Record View, Transpose, other ways to show a column, colours, charts, and a
column's summary. Editing, filters and sorting are on their own page.

## Open a table's rows

- **Data ▸ Open Table…** (⇧⌘O) asks for a table's name, as `table` (in the console's database) or `database.table`,
  and opens its rows in a tab of their own. Names with dots or spaces go in backticks: `` `my.db`.`order lines` ``.
- The first page of rows loads on the connection's data session, so a long query in a console doesn't hold it up.
  **Settings ▸ Grid ▸ Rows per page** sets its size (1,000 at first).
- The status bar says how many rows are loaded and how many the table has: **1,000 of ≈2,348,245 rows**. The number
  after ≈ is the server's estimate (InnoDB's can be off by a lot); **Count exactly** in the status bar, or **Data ▸
  Count Rows Exactly**, counts them with `COUNT(*)`.
- **Load more** in the status bar, or **Data ▸ Load More** (⌥⌘↓), loads the next page. When a page comes back short,
  every row is loaded and the status bar says how many there are.
- **View ▸ Refresh** (⌘R) reads the first page again. Anything slow shows in the status bar's activity, with Cancel.

## The header

Each column's header shows its name and, under it, its type. Marks before the name tell you about keys:

- a gold key: the primary key, or the unique key the grid uses to find a row when there is no primary key;
- a grey key: another unique key; an outline key: an index;
- an arrow: a foreign key.

After the type, **auto** marks an auto-increment column, **generated** a generated one, **default** a column with a
default value, and **null** a column that allows NULL. Hold the pointer over a header for all of this in words and the
column's comment.

## The status bar

With cells selected, the status bar shows the focused cell (**r3 : c5**, row and column), how many cells are
selected, and one figure for them: their sum, or their count when they aren't numbers. Click the figure to see them
all (count, sum, average, smallest, largest, median, distinct values) and choose the one shown. Sums of decimals are
exact. **Edit ▸ Copy Selection Summary** (⇧⌘C) copies every figure. Selections of more than 100,000 cells aren't added
up.

## Move around

- **Data ▸ Go to Row…** (⌘L) goes to a row by its number, or to `column:row`, the column by its name or number:
  `email:120`.
- **View ▸ Column List…** (⌘J) lists every column. Type to find one; Return (or a double-click) jumps to it; its box,
  or Space, shows or hides it; **Show All** brings back hidden columns.
- **Data ▸ Hide Column** hides the selected columns. A column comes back where it was.
- Drag a header to move its column, drag its right edge to resize it, and double-click the edge to fit its values.
  AirSQL remembers the columns' order, widths, hidden columns and display types for each table, and for each query
  in the console, so they open as you left them.
- **View ▸ Bigger** (⌘+) and **Smaller** (⌘−) change the grid's text size while it has the focus.

## See a whole value

- **View ▸ Value Panel** (⇧↩) opens the focused cell's whole value beside the grid, never shortened: as wrapped text,
  as a JSON tree, as hex, or as a picture when the bytes are an image. It follows the cell you select. A double-click
  on a cell you can't edit opens it too.
- **View ▸ Record View** (⌥⌘R) shows the focused row as a form, a line per column. **Previous** and **Next** above it
  (or **View ▸ Previous Record** and **Next Record**) move between rows; **Back to the Grid** returns. A double-click
  on a row's number opens it.
- **View ▸ Transpose** (⌥⌘T) turns rows into columns, with the column names down the left: handy for comparing a few
  wide rows. A console result with one row opens this way; **Settings ▸ Grid ▸ Transpose results with one row** turns
  that off. Transpose shows the first 1,000 rows.

## Show a column another way

**Data ▸ Display As** (also on a cell's right-click menu) changes how the selected columns look, not what they hold:
copying and editing use the stored value.

- Numbers: **Date from Unix Time** (seconds or milliseconds), in your time zone, or **Number with Grouping**.
- Bytes: **UUID** (for `binary(16)`), **Hex**, or **Text (UTF-8)**.
- **As Stored** shows the value as the server sent it again.

## Colours

- **View ▸ Heatmap** colours the selected number columns by value, pale for the smallest and strong for the largest.
  A column with negative and positive numbers is red below zero and green above; one of only 0 and 1 marks the 1s.
  With everything selected (⌘A), every number column gets one. Choose it again to take it away.
- **View ▸ Highlight Equal Values** tints every cell holding the focused cell's value.

## Text, tree and charts

- **View ▸ View As ▸ Text** shows the rows as a plain-text table, as the mysql client prints them; **Tree** shows them
  as JSON, a row per item, with JSON columns opened up. **Table** goes back. Both show the first 10,000 rows.
- **View ▸ Chart** draws the rows as a bar, line, area, pie, scatter or histogram chart of a number column, by another
  column. Choose the kind and columns above the chart; point at it to read a value. Bars add up the values of each
  label and show the first 30 labels; a pie shows eight slices and puts the rest in **Other**. **Save as PNG…** saves
  a picture of it. Pie charts need macOS 14 or later.

## Column Summary

**Data ▸ Column Summary…** (also on a header's right-click menu) counts the focused column's distinct values and NULLs,
finds its smallest and largest values, and lists its 50 most frequent values with how often each appears. For a table
the server works this out over all its rows; it asks first when the table is larger than 2 GB. For a console result
it counts the rows you have.
