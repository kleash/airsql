---
title: Change tables, views and routines
nav_order: 14
---

# Change tables, views and routines

AirSQL edits a table's structure in a form, and views, procedures, functions, triggers and events as the CREATE
statement that makes them. Nothing changes on the server until you apply, and the SQL that will run is always shown
first.

## The table editor

Open it from a table's **Open Structure**, or make a new table with **Database ▸ Create Table…**. A table editor has five
parts, chosen at the top:

- **Columns**: name, type (the types your server has), length or ENUM values, unsigned, NULL, default, extra (counts up
  by itself, follows updates, or is generated from an expression), collation and comment. Drag rows to reorder the
  columns.
- **Indexes**: primary key, unique, plain, full-text and spatial indexes. Write their columns separated by commas:
  `email(10)` indexes the first 10 characters, `created_at DESC` sorts down.
- **Foreign keys**: this table's columns, the table they point at and its columns, and what happens on update and on
  delete.
- **Checks**: conditions every row must satisfy. On MariaDB, a check written with a column belongs to that column and
  stays with it when the column changes.
- **Options**: the table's name, engine, default collation, row format, next AUTO_INCREMENT number and comment.

**+** adds a row, **−** removes the selected rows (or press Delete), and a right-click offers the same. New rows show in
green and changed ones in amber until you apply. **Edit ▸ Undo** takes back a change; **Discard** takes back all of them.

Under the lists, the SQL that Apply would run updates as you type. When something can't work yet (a VARCHAR without a
length, two columns of one name, an emoji in a name, which the server would keep as `?`), it says what to fix instead.

## Apply

**Apply** (⌘S) shows the statements in the [SQL preview](sql-preview.md) first. Then they run one at a time on a
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
- Renaming it in the code makes the new one and then drops the old one.

## The ER diagram

**Database ▸ ER Diagram** draws a database's tables with their keys. Tables that point at nothing come first on the left,
and each table sits right of the tables its foreign keys point at; lines go from a key's column to the table it points
at. Tables with no keys come last.

Click a table to select it (the arrow keys move between tables), double-click it to open it in the table editor, and
right-click it for **Open Structure** and **Copy Name**. **Export Image…** saves the diagram as a PNG, and **Export
Mermaid…** as Mermaid text, which many docs sites and wikis draw.
