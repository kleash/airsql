# Browse a server

Once a connection is connected, the sidebar shows its databases under it. Each database groups its objects by kind:
tables, views, sequences (MariaDB), procedures, functions, triggers and events, with how many there are.

## Find your way

- **Click** a database to see its tables in the database view: rows, the space their data and indexes take, engine,
  collation, when they last changed and their comment. Click a column's title to sort by it.
- **Click** a table or view to see its rows; **double-click** it (or press Return) to open it in a tab of its own.
- **Click** a routine, trigger or event to see its definition; **double-click** to open it.
- **Double-click** a database to make it the current one (it shows in bold) and open it.
- **Right-click** anything for everything you can do with it. Every command is also in the **Database** menu.
- Hold ⌘ or ⇧ to select several tables, then drop, empty, check or change them all at once.
- Type a few letters of a name to jump to it, or type in the sidebar's filter (⌥⌘J) to show only what matches. While you
  filter, a connected connection whose name doesn't match shows the objects that do, opened.
- Drag a table or database into the SQL editor to insert its name, quoted for SQL.
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

## Find text on the server

**Find Text on Server…** looks for a text in every text column of every table (or of one database), and lists the
tables that hold it with how many rows. It reads each table in full, so it can take a while on a big server: the status
bar shows how far it is, and **Stop** or Cancel ends it. Double-click a table in the list to see its matching rows.
Upper and lower case match as the column's collation says (most ignore case).

## See what the server is running

**Process List** (⌥⌘P, or **Processes** under the sidebar) lists every connection to the server and the statement it is
running, refreshed every 5 seconds (choose another interval, or Off). Double-click a row to read its whole statement.

- **Kill Query…** stops a statement; its connection stays.
- **Kill Connection…** ends a connection, rolling back its open transaction.

Both ask first. Right before it stops anything, AirSQL checks that the process is still running what the list showed
(on MariaDB, that exact statement); if it has moved on, nothing is stopped and AirSQL says so.
