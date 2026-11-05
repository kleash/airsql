---
title: Browse a server
nav_order: 11
---

# Browse a server

Once a connection is connected, the sidebar shows its databases under it. Each database groups its objects by kind:
tables, views, sequences (MariaDB), procedures, functions, triggers and events, with how many there are.

## Find your way

- **Click** a connected connection to see its [host page](#the-host-page). Connecting shows it too.
- **Click** a database to see everything in it in the database view: for its tables, rows, a bar and the size of each,
  engine, collation, when they last changed and their comment. Click a column's title to sort by it; AirSQL keeps the order and the widths.
  Right-click a title to show or hide columns: **Data**, **Indexes**, **Free**, **Average Row**, **Auto Increment**,
  **Created**, **Row Format** and **Options** are there too. **Filter by name** at its top keeps the tables with those
  letters. Right-click below the rows, or an empty database, for **Create Table…**.
- **Click** a table or view to see its rows; **double-click** it (or press Return) to open it in a tab of its own.
- **Click** a routine, trigger or event to see its definition; **double-click** (or **Open**) to open it in its editor.
- **Click the arrow** beside a table or view (or press →) to see what it holds without opening it: **Columns** with
  their types (the primary key's are marked **PK**), and for a table **Indexes**, **Foreign Keys**, **Checks** and
  **Triggers**. Hold the pointer over a row for all of it: a column's default, an index's columns, where a key points.
  **Double-click** a row to open the table's structure (a trigger, its editor); right-click a column for **Copy Name**,
  or drag it into the SQL editor. All of this comes from what AirSQL already read, so it asks the server nothing.
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
  filter, a connected connection whose name doesn't match shows the objects that do, opened. Between slashes the filter is
  a regular expression (`/^wp_/`), and what you opened with Return comes back under its magnifying glass.
- **Quick Open…** (⌘P) goes to anything by letters of its name, in order: `fica` finds `film_category`. It lists your tabs,
  connections, databases, tables, routines, triggers and events, recent files and every menu command.
- **Select in Tree** (⇧⌘L) finds the tab's table or object in the tree; in a query tab, the name at the cursor.
- **F1** on a tree row shows what the editor's Quick Documentation shows for that name, and a table's first rows, cut
  short. **Quick Definition** (⌥F1) peeks at its CREATE statement. Both work in a query tab too, for the name at the
  cursor; there F4 opens the table's rows and ⌥⌘B goes to its DDL. **F4** on a Tables or Views group lists them.
- **Find Where Used…** lists the views, routines, triggers, events and foreign keys that name the selected object or
  column, from their definitions on the server, as far as your login can read them.
- **Back** and **Forward** (⌃⌘← and ⌃⌘→) walk the tabs you've shown; **Recent Tabs…** (⌃⌘E) lists them, the last seen
  first, with recent files. In a query tab, **Go to Statement…** (⌃⌘O) lists its statements.
- Drag a table, column or database into the SQL editor to insert its name, quoted for SQL; hold ⇧ as you start to add its
  database. Drag a table onto a database in the tree to copy it there, through **Copy Table…**'s questions.
- **Move Up** and **Move Down** in a connection's menu put its list in your own order.
- F2 renames the selected table or view (or folder), as **Database ▸ Rename…** does.
- **Refresh** (⌘R) reads the selected database or objects again from the server; with the connection selected, all of it.

On a server with more than 3,000 tables, AirSQL reads only the names when it connects; a database's columns, indexes and
keys load when you open it (a spinner shows on its row meanwhile). Change the number in Settings ▸ Connections.

## Choose what the tree shows

The button beside the filter, and **View ▸ Tree**, hold these choices. They last until you change them.

- **Flat List** leaves out the groups: a database's objects come straight under it.
- Point at an object and click its **star** to make it a favourite (or use **Add to Favourites** in its menu). The star
  beside the filter, **Favourites Only**, shows only those. Each connection keeps its own.
- **Sizes** shows each table's size with a bar behind its row, and each database's total, once the sizes are read:
  click the database to read them. Off, the row shows the estimated rows instead.
- **Comments** shows tables' and routines' comments beside their names.
- **Group by Prefix** folds three or more objects that share a first part, such as `wp_`, into a group.
- **Follow Tab** selects in the tree what the tab you switch to is about.
- **Database Filter** adds a second box that filters the databases, with the same rules as the first.
- **Object Kinds** shows or hides tables, views and the rest; **Hide Names…** leaves names or patterns such as `tmp_*` out
  of every tree.
- **Databases Shown…** ticks the databases of this server to show; the connection shows "3 of 12" when some are left out.
  It writes the connection's database filter, so a database left out when you connected returns after you connect again.

## Change databases and tables

Every change shows its SQL first ([Check SQL before it runs](sql-preview.md)); nothing runs until you choose to.

- **New Database…** asks for a name, a character set and a collation (the server's own are chosen at first).
- **Drop…** deletes the selected databases or objects. Dropping a database always asks you to type its name; on a
  Production connection, so does dropping or emptying a table.
- **Truncate…** deletes every row of the selected tables. It can't be rolled back.
- **Drop…** on an index, foreign key or check under a table takes it off the table; the rows stay.
- **Edit Comment…** changes a table's or routine's comment. **New Column…**, **New Index…** and **New Foreign Key…** open the
  table's structure with a new row to fill in; nothing changes until Apply there.
- **Rename…** gives a table or view a new name. Views and routines that use the old name aren't changed.
- **Copy Table…** copies a table into the same or another database, with its rows or without, or only the rows where a
  condition you type holds (for example `created_at >= '2026-01-01'`). Untick columns to leave them out; the primary key always comes along, the other indexes unless you untick them, and foreign keys if you tick them.
- **Bulk Table Editor…** moves the selected tables to another database, or changes their engine, or converts them and
  their text columns to another character set and collation.
- **Maintenance** ▸ Analyze, Check, Optimize, Repair or Checksum runs on the selected tables and shows what the server
  said in a tab. Analyze, Optimize and Repair show their SQL first: Optimize rebuilds a table and locks it meanwhile.

A read-only connection offers none of these.

## Write SQL from the tree

These open a query tab with the SQL in it, built from the names AirSQL read; nothing runs until you press Run.

- **Generate SELECT**, **Generate INSERT** and **Generate UPDATE** on a table's or view's menu (in the sidebar or the
  database view) write a statement with its columns. A `?` marks each value for you to fill in: INSERT leaves out the
  columns the server fills itself (auto-increment and generated ones), and UPDATE finds the row by its primary key (or a
  unique key whose columns can't be NULL; without one, you write the condition).
- **Select Top 1000 Rows** on a table's menu writes a `SELECT` of its first 1,000 rows.
- **Run…** on a procedure's menu writes its `CALL`, with a `?` and the name and type of each value it takes (Run then asks for each by name); OUT and
  INOUT parameters go in variables that a `SELECT` after the call shows. On a function's menu it writes a `SELECT` of it.
- **New Query**, **Export…** and **Restore…** on a database's menu start in that database.

## Find text in tabs and files

**Find in Tabs and Files…** (⌃⌥F) searches the text of every query tab and, once you choose a folder, its .sql files.
Double-click a match to go there. **Replace in Tabs** changes the tabs only, with Undo there, and saves nothing.

## Find text on the server

**Find Text on Server…** looks for a text in every text column of every table (or of one database), and lists the
tables that hold it with how many rows. It reads each table in full, so it can take a while on a big server: choose **Stop at 1,000** or **Stop at 100,000** to
stop counting a table early. The status bar shows how far it is, and **Stop** or Cancel ends it. Double-click a table in the list, or press Return, to see its
matching rows; right-click it to open all its rows or copy its name. A column's header sorts the list.
Upper and lower case match as the column's collation says (most ignore case). The menu beside it chooses **Contains**, **Is exactly**, **Wildcards** (`%` and `_`) or a **Regular expression**, and
**Match case** tells capitals from small letters whatever the column's collation.

## See what the server is running

**Process List** (⌥⌘P, or **Processes** under the sidebar) lists every connection to the server and the statement it is
running, refreshed every 5 seconds (choose another interval, or Off). Click a column's title to sort by it (Time starts
with the longest running); type in **Filter** to keep the rows with those words, and tick **Hide Sleeping** to leave out
idle connections. The selected process's whole statement shows under the list; double-click a row (or press Return) to
read it in a window. Delete offers to kill it.

- **Kill Query…** stops a statement; its connection stays.
- **Kill Connection…** ends a connection, rolling back its open transaction.

Both ask first. Right before it stops anything, AirSQL checks that the process is still running what the list showed
(on MariaDB, that exact statement); if it has moved on, nothing is stopped and AirSQL says so. Both work on a
read-only connection too: they change no data.

## The host page

Click a connected connection, or choose **Database ▸ Server Home**, for a page on the server. Its top line says what the
server is, how you reach it and how long it has been up. A click on a row selects it; right-click for its menu.

- **Databases**: each with its size, how many tables, views, routines, triggers and events it has, when it last changed
  and its collation. Double-click one to open its tables; **Edit Database…** changes the collation new tables take. On a server of up to 3,000 tables (**Settings ▸ Connections**
  sets this) the sizes are read by themselves; on a bigger one press **Read Sizes**, which reads the databases you've
  selected, or all of them.
- **Variables**: each variable's session and global values side by side, with **≠** where they differ. Session shows what
  a new session starts with. Double-click one, or press **Edit…**, to change it: **Whole server** runs `SET GLOBAL` after
  showing you the SQL; **In a new query tab** puts `SET SESSION` in a new tab for you to run, as each tab has a session of
  its own. Type a number, a word, or `DEFAULT`. Read-only and Production connections can't change variables.
- **Status**: every status counter, with its average per hour and per second since the server started.
- **Processes**: the [process list](#see-what-the-server-is-running).
- **Command Statistics**: how many statements of each kind the server has run, with their rates and share.

Every list has a **Filter** that takes a word or, between slashes, a regular expression (`/^wp_/`), and says how many rows it kept. Click a column's
title to sort; right-click a title to show or hide columns. **⌘C** copies the selected rows. **Copy List** and **Export
List…** take the whole list as CSV. **⌘R** reads it again.

## See where the space went

**Disk Usage** (⌥⌘U, in the **Tools** menu, or right-click a connection, database or table) lists every database with its
data, indexes, free space, rows and share, largest first, each with a bar: blue for data, teal for indexes, grey for free
space.

- **Double-click** a database to see its tables, and a table to see its indexes and partitions. **Back** goes up.
- Select several rows to see what they come to. **Compare Selected** keeps only those, their bars against each other.
- **Filter**, sorting, **Copy List** and **Export List…** work as on the host page.
- **Free** is space a table keeps but doesn't use. Select tables and press **Optimize…** to give it back: it shows the SQL
  first, and locks the tables while it runs. Tables in a shared tablespace all show that tablespace's free space, so a
  database's total counts it more than once.

Reading a table's size makes the server open that table, so AirSQL reads one database at a time, on a session of its own.
The status bar shows how far it is, and **Stop** or Cancel there ends it; what was read stays. The sizes then also show in
the database view and the host page.

InnoDB's sizes and row counts are estimates, and you see only what your login can see, and the databases the connection
lists. An index's own size comes from `mysql.innodb_index_stats`, which not every login may read; AirSQL says so when it
can't.

## Getting back to your tabs

When you open AirSQL again, your tabs come back in their old order with the old one showing, and so does the sidebar's
selection. Query tabs are as you left them. Table, structure and process-list tabs come back as placeholders: AirSQL doesn't
connect to anything by itself, also not to a Production connection.

- A placeholder says what the tab was and where. **Connect and Open** connects the usual way, with its prompts, then
  loads the tab in the same place; on a connection that's connected already the button is **Open**, which just loads.
- If the connect fails, the tab stays and says why, with **Try Again**, **Edit Connection…** and **Troubleshooting**.
- A placeholder closes without a question, and Quit doesn't ask about it.
- Only names are kept: the connection, database, object and kind. Rows and filters aren't. Pending changes aren't part of
  the tab: they stay with the table and show when you [open it](table-data.md).
- A tab whose connection you deleted doesn't come back.
