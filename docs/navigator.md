---
title: Browse a server
nav_order: 11
---

# Browse a server

Once a connection is connected, the sidebar shows its databases under it. Each database groups its objects by kind:
tables, views, sequences (MariaDB), procedures, functions, triggers and events, with how many there are.

## Find your way

- **Click** a database to see its tables in the database view: rows, the space their data and indexes take, engine,
  collation, when they last changed and their comment. Click a column's title to sort by it; AirSQL keeps the order
  and the widths. **Filter by name** at its top keeps the tables with those letters. Right-click below the rows, or an
  empty database, for **Create Table…**.
- **Click** a table or view to see its rows; **double-click** it (or press Return) to open it in a tab of its own.
- **Click** a routine, trigger or event to see its definition; **double-click** (or **Open**) to open it in its editor.
- **Open Structure** in a table's menu opens the table editor ([Change tables, views and routines](editors.md));
  **Create Table…** makes a table in the database you right-clicked; **New…** on a group (Tables, Views…) makes
  another of its kind.
- **Double-click** a database to make it the current one (it shows in bold, and in the toolbar's database pop-up) and
  open it; double-click again to close it. The console's statements run in the current database ([The SQL console](console.md)).
- **Right-click** anything for everything you can do with it; the tab in front stays. Every command is also in the
  **Database** menu. **Copy Name** quotes it for SQL, **Copy Name Without Quotes** doesn't, and **Copy CREATE** copies
  the statement that makes it.
- Hold ⌘ or ⇧ to select several tables, then drop, empty, check or change them all at once.
- Type a few letters of a name to jump to it, or type in the sidebar's filter (⌥⌘J) to show only what matches. While you
  filter, a connected connection whose name doesn't match shows the objects that do, opened.
- Drag a table or database into the SQL editor to insert its name, quoted for SQL.
- F2 renames the selected table or view (or folder), as **Database ▸ Rename…** does.
- **Refresh** (⌘R) reads the selected database or objects again from the server; with the connection selected, all of it.

On a server with more than 3,000 tables, AirSQL reads only the names when it connects; a database's columns, indexes and
keys load when you open it (a spinner shows on its row meanwhile). Change the number in Settings ▸ Connections.

## Change databases and tables

Every change shows its SQL first ([Check SQL before it runs](sql-preview.md)); nothing runs until you choose to.

- **New Database…** asks for a name, a character set and a collation (the server's own are chosen at first).
- **Drop…** deletes the selected databases or objects. Dropping a database always asks you to type its name; on a
  Production connection, so does dropping or emptying a table.
- **Truncate…** deletes every row of the selected tables. It can't be rolled back.
- **Rename…** gives a table or view a new name. Views and routines that use the old name aren't changed.
- **Copy Table…** copies a table into the same or another database, with its rows or without, or only the rows where a
  condition you type holds (for example `created_at >= '2026-01-01'`). Indexes come along; foreign keys don't.
- **Bulk Table Editor…** moves the selected tables to another database, or changes their engine, or converts them and
  their text columns to another character set and collation.
- **Maintenance** ▸ Analyze, Check, Optimize, Repair or Checksum runs on the selected tables and shows what the server
  said in a tab. Analyze, Optimize and Repair show their SQL first: Optimize rebuilds a table and locks it meanwhile.

A read-only connection offers none of these.

## Write SQL from the tree

These open a console tab with the SQL in it, built from the names AirSQL read; nothing runs until you press Run.

- **Generate SELECT**, **Generate INSERT** and **Generate UPDATE** on a table's or view's menu (in the sidebar or the
  database view) write a statement with its columns. A `?` marks each value for you to fill in: INSERT leaves out the
  columns the server fills itself (auto-increment and generated ones), and UPDATE finds the row by its primary key (or a
  unique key whose columns can't be NULL; without one, you write the condition).
- **Run…** on a procedure's menu writes its `CALL`, with a `?` and the name and type of each value it takes; OUT and
  INOUT parameters go in variables that a `SELECT` after the call shows. On a function's menu it writes a `SELECT` of it.
- **New Query**, **Export…** and **Restore…** on a database's menu start in that database.

## Find text on the server

**Find Text on Server…** looks for a text in every text column of every table (or of one database), and lists the
tables that hold it with how many rows. It reads each table in full, so it can take a while on a big server: the status
bar shows how far it is, and **Stop** or Cancel ends it. Double-click a table in the list, or press Return, to see its
matching rows; right-click it to open all its rows or copy its name. A column's header sorts the list.
Upper and lower case match as the column's collation says (most ignore case).

## See what the server is running

**Process List** (⌥⌘P, or **Processes** under the sidebar) lists every connection to the server and the statement it is
running, refreshed every 5 seconds (choose another interval, or Off). Click a column's title to sort by it (Time starts
with the longest running); type in **Filter** to keep the rows with those words, and tick **Hide Sleeping** to leave out
idle connections. Double-click a row (or press Return) to read its whole statement; Delete offers to kill it.

- **Kill Query…** stops a statement; its connection stays.
- **Kill Connection…** ends a connection, rolling back its open transaction.

Both ask first. Right before it stops anything, AirSQL checks that the process is still running what the list showed
(on MariaDB, that exact statement); if it has moved on, nothing is stopped and AirSQL says so. Both work on a
read-only connection too: they change no data.
