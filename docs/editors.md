---
title: Change tables, views and routines
nav_order: 14
---

# Change tables, views and routines

AirSQL edits a table's structure in a form, and views, procedures, functions, triggers and events as the CREATE
statement that makes them. Nothing changes on the server until you apply, and the SQL that will run is always shown
first.

## The table editor

Open it from a table's **Open Structure**, or make a new table with **Database ▸ Create Table…**. A table editor has seven
parts, chosen at the top:

- **Columns**: name, type (the types your server has), length or ENUM values, unsigned, NULL, default, extra (counts up
  by itself, follows updates, or is generated from an expression), collation and comment. Drag rows to reorder the
  columns.
- **Indexes**: primary key, unique, plain, full-text and spatial indexes. Write their columns separated by commas:
  `email(10)` indexes the first 10 characters, `created_at DESC` sorts down. **Using** chooses BTREE or HASH, and **Visible** off
  keeps an index up to date while queries leave it alone (INVISIBLE on MySQL, IGNORED on MariaDB). In the Columns list, right-click
  selected columns for **New Index from Columns**, **New Unique Index from Columns** and **Add to Index**.
- **Foreign keys**: this table's columns, the table they point at and its columns, and what happens on update and on
  delete.
- **Used by**: the foreign keys of other tables that point at this one, from the databases read so far. Double-click one to open
  that table.
- **Checks**: conditions every row must satisfy. On MariaDB, a check written with a column belongs to that column and
  stays with it when the column changes.
- **Partitions**: the partitions the server has, with their rows and sizes, and the PARTITION BY clause. Edit the clause to add or change
  partitions; empty it to remove them and keep the rows. Changing them copies the table, and rows that fit no partition stop the change.
- **Options**: the table's name, engine, default collation, row format, next AUTO_INCREMENT number and comment.

**+** adds a row, **−** removes the selected rows (or press Delete), and a right-click offers the same. New rows show in
green and changed ones in amber until you apply. **Edit ▸ Undo** takes back a change; **Revert** takes back all of them.
Drag columns to put them in another order, or press ⇧⌘↑ and ⇧⌘↓. ⌘C copies the selected rows as the lines of a CREATE TABLE; ⌘V in this list, here or in another table's editor, adds them
as new rows.

Under the lists, the SQL that Apply would run updates as you type. When something can't work yet (a VARCHAR without a
length, two columns of one name, an emoji in a name, which the server would keep as `?`), it says what to fix instead.

## Apply

**Apply** (⌘S) shows the statements in the [SQL preview](sql-preview.md) first; **Open in Query Tab** there puts them in a query tab
instead of running them. Then they run one at a time on a
connection of their own, and the editor reads the table back from the server.

- MySQL and MariaDB can't roll table changes back: each statement takes effect as it runs. When there are several, the
  preview says so; if one fails, the ones before it stay done, and the editor shows what is left to do.
- A changed foreign key is dropped in a statement of its own first: neither server takes a drop and an add of the same
  key in one statement.
- Dropping a column deletes its values, and changing a column's type converts them: the preview warns about both.
- A large table may be copied while it changes, and writes to it wait until that is done.

## Views, procedures, functions, triggers and events

Open one from the tree, or start a new one from **Database ▸ New Object**. The editor shows its CREATE statement, as the
server keeps it, to edit as text.

- **Runs as** chooses its DEFINER: the account it was created with, or you. Keeping another account's DEFINER needs the
  SET_USER_ID privilege on MySQL, or SET USER on MariaDB.
- Apply runs it in its database, under the sql_mode it was created with (and an event under its time zone), so it
  behaves as before. The footer shows those settings.
- MariaDB replaces it in one statement (CREATE OR REPLACE). MySQL replaces a view the same way, but drops a procedure,
  function, trigger or event first: if the new code fails, the old one is gone. Your code stays in the editor to fix and
  apply again, and **Revert** puts the old code back.
- **Run…** on a procedure or function opens a CALL or SELECT of it in a query tab, for the code the server has: apply your changes first.
- The code has the tab's editor: line numbers, completion, Comment Lines (⌘/), Format SQL and the matching bracket.
- When the server refuses the code, the place it points to is underlined in red, with the message on hover, until you
  change the text.
- Renaming it in the code makes the new one and then drops the old one.

## The ER diagram

**Database ▸ ER Diagram** draws a database's tables with their keys. Tables that point at nothing come first on the left,
and each table sits right of the tables its foreign keys point at; lines go from a key's column to the table it points
at, virtual foreign keys you added in a table's rows included ([Virtual foreign keys](table-data.md#foreign-key-labels-and-virtual-foreign-keys)).
Tables with no keys come last.

Click a table to select it (⌘ or ⇧ click adds more; the arrow keys move between tables), double-click it to open it in the
table editor, and right-click it for **Open Structure**, **Open Data**, **Copy Name** and the diagram's own commands (⌘C copies
the selected table's name too), or the empty space to export. Pinch, ⌘+ and ⌘− zoom, ⌘0 goes back to actual size and **Fit** shows
the whole diagram; ⌘F goes to the find field, where typing part of a name selects that table and Return goes to the next. ⌘R
reads the schema again.

### Boxes and saved diagrams

Drag a box to move it, with any others selected; ⌥ and the arrow keys do the same from the keyboard. ⌘Z takes a move back. A
diagram remembers where its boxes are: it is kept on this Mac, never on the server.

A database can have several diagrams, chosen in **Diagram**. The first always shows every table.

- **Diagram of Selected Tables** in a table's right-click menu in the tree makes a diagram of only those tables, and **Diagram
  of Neighbours** adds every table that touches them by a foreign key.
- **Add Table** adds one more, or drag tables onto the diagram from the tree. **Add Neighbours** adds what touches the selected
  boxes (on the whole database's diagram it makes a new diagram of them), and **Remove from Diagram** takes boxes off; the tables
  themselves aren't touched.
- **New Diagram from Selection…** keeps the selected boxes, or all of them, under a name. **Database ▸ Diagram** also has Rename and
  Delete.
- **Arrange** lays the boxes out again, **Left to Right**, **Top to Bottom** or as a **Grid**, and forgets where you moved them.
- **Show** chooses **All Columns**, **Keys Only** or **Names Only**, and turns **Comments** and **Virtual Keys** on or off.

**Export** saves the diagram as a PNG, or as text for other tools: Mermaid, which many docs sites and wikis draw, PlantUML, Graphviz
DOT, GraphML and draw.io (the last two keep where your boxes are). **Print Diagram…** fits it on one page.

## CREATE statements of several objects

**Copy CREATE** works on several selected objects, as one script. **Open CREATE in Query Tab** puts that script in a new query tab;
nothing runs until you run it.

**SQL Generator…**, on a database or on selected objects, shows the statements that recreate them and keeps them up to date as you
change its options: IF NOT EXISTS and OR REPLACE where your server takes them, Skip DEFINER, database names, and whether to keep
indexes, foreign keys, the AUTO_INCREMENT number and the tables' triggers. Tables come first, then views, routines, triggers and events,
with foreign key checks off around several tables so that their order doesn't matter, and DELIMITER lines round routines.

**Copy** and **Open in Query Tab** take the whole script. **Save to Folder…** writes a `.sql` file per object: in one folder, a folder
per kind, a folder per database and kind, or numbered in the order they run. Files of the same name are replaced.
