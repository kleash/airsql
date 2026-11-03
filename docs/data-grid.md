---
title: Read the data in a grid
nav_order: 13
---

# Read the data in a grid

A table's rows and a console's results show in the same grid. These parts of it help you read what is there: the
status bar's figures, the value panel, Record View, Transpose, other ways to show a column, colours, text, charts, and
a column's summary. Loading, filtering, editing, copying and exporting a table's rows are on
[A table's rows](table-data.md).

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
up. In a narrow window the figure, then the focused cell, make way for the rest; a table's row count and its **Count
Exactly**, **Load More** and **Load All** stay. Right-click them to copy what they say, or to count or load rows.

## Move around

- **Data ▸ Go to Row…** (⌘L) goes to a row by its number, or to `column:row`, the column by its name or number:
  `email:120`.
- **View ▸ Column List…** (⌘J) lists every column. Type to find one; Return (or a double-click) jumps to it; its box,
  or Space, shows or hides it; **Show All** brings back hidden columns.
- **Edit ▸ Extend Selection** (⌥↑) grows the selection from the focused cell to its column, then its row, then
  everything; **Shrink Selection** (⌥↓) goes back the same way.
- Hold ⇧ to scroll a mouse wheel across, and ⌥ to scroll five times as far.
- **Data ▸ Hide Column** hides the selected columns. A column comes back where it was.
- **Data ▸ Freeze** keeps the columns up to the focused one (the key column, say) at the left while you scroll across.
  Choose it on the last frozen column to unfreeze them. AirSQL remembers it for each table.
- Drag a header to move its column, drag its right edge to resize it, and double-click the edge, or the header, to fit
  its values.
  AirSQL remembers the columns' order, widths, hidden and frozen columns and display types for each table, and for
  each query in the console, so they open as you left them.
- **View ▸ Bigger** (⌘+) and **Smaller** (⌘−) change the grid's text size while it has the focus; **Actual Size** (⌘0)
  goes back to the size in Settings ▸ Grid.

## See a whole value

- **View ▸ Value Panel** (⇧↩) opens the focused cell's whole value beside the grid, never shortened: as wrapped text,
  as a JSON tree, as hex, or as a picture when the bytes are an image. It follows the cell you select. A double-click
  on a cell you can't edit opens it too.
- **View ▸ Record View** (⌥⌘R) shows the focused row as a form, a line per column. **Previous** and **Next** above it
  (or **View ▸ Previous Record** and **Next Record**) move between rows; **Back to the Grid** returns. A double-click
  on a row's number opens it. In a table, its values can be edited there as in the grid. A filter or a sort on a
  console result shows the grid again, as does an Apply that deletes the row.
- **View ▸ Transpose** (⌥⌘T) turns rows into columns, with the column names down the left: handy for comparing a few
  wide rows. A console result with one row opens this way; **Settings ▸ Grid ▸ Transpose results with one row** turns
  that off. Transpose shows the first 1,000 rows.

## Show a column another way

**Data ▸ Display As** (also on a cell's right-click menu) changes how the selected columns look, not what they hold:
copying and editing use the stored value.

- Numbers: **Number with Grouping**; **Decimal Places ▸** rounds them (half up) to none, 1, 2, 3 or 4 decimal places,
  grouped by thousands as your Mac groups them; or **Date from Unix Time** (seconds or milliseconds), in your time zone.
- Dates: **Short**, **Medium** or **Long Date and Time**, as your Mac writes dates (System Settings ▸ General ▸ Language
  & Region). A DATE column shows the date only. Zero dates, TIME and YEAR stay as stored.
- **Time Zone ▸** (DATETIME and TIMESTAMP columns) moves the values: **From UTC to This Mac's** takes them as UTC and
  shows them in your time zone; **From This Mac's to UTC** does the reverse. A TIMESTAMP arrives in the session's time
  zone, so choose the first one when that is UTC. The header says so (`datetime as medium date, UTC → this Mac's`).
- Bytes: **UUID** (for `binary(16)`), **Hex**, or **Text (UTF-8)**.
- **As Stored** shows the value as the server sent it again. AirSQL remembers each column's choice for each table.

## Colours

- **View ▸ Heatmap** colours the selected number columns by value, pale for the smallest and strong for the largest.
  A column with negative and positive numbers is red below zero and green above; one of only 0 and 1 marks the 1s.
  With everything selected (⌘A), every number column gets one. Choose it again to take it away.
- **View ▸ Highlight Equal Values** tints every cell holding the focused cell's value.
- What a colour marks is said too: with VoiceOver, a cell says **changed**, **added** or **removed** after its column's
  name, for pending changes and for a comparison's rows, and a compared cell's help gives the other side's value.

## Text, tree and charts

- **View ▸ View As ▸ Text** shows the rows as text in the copy format (**Edit ▸ Copy As**: TSV at first, or CSV, JSON,
  Markdown, SQL INSERT…), with the column names; **Tree** shows them as JSON, a row per item, with JSON columns opened
  up. **Table** goes back. Both show the first 10,000 rows. In a tree (here or in the value panel), double-click an
  object or array to open or close it; right-click to copy a value or to open or close every one.
- **View ▸ Chart** draws the rows as a bar, line, area, pie, scatter or histogram chart of a number column, by another
  column. Choose the kind and columns above the chart; point at it to read a value. Bars add up the values of each
  label and show the first 30 labels; a pie shows eight slices and puts the rest in **Other**. **Save as PNG…** saves
  a picture of it. Pie charts need macOS 14 or later.

## Column Summary

**Data ▸ Column Summary…** (also on a header's right-click menu) counts the focused column's distinct values and NULLs,
finds its smallest and largest values, and lists its 50 most frequent values with how often each appears. For a table
the server works this out over all its rows within the filter; it asks first when the table is larger than 2 GB.
Click a value to show only the rows that hold it (it is added to the filter). For a console result it counts the rows
you have.
