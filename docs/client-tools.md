---
title: Export, restore, copy and import
nav_order: 15
---

# Export, restore, copy and import

AirSQL backs up and moves data with your own `mysqldump` and `mysql` (or MariaDB's `mariadb-dump` and `mariadb`)
when you have them, and with its own code when you don't. Every command here is in the **Tools** and **File** menus
and in a connection's right-click menu in the sidebar.

## Which programs AirSQL uses

**Settings ▸ Client Tools** shows the programs AirSQL found and their versions. It looks in Homebrew's folders
(`/opt/homebrew/opt/mysql-client/bin` and the like, on Apple silicon and Intel), `/usr/local/mysql/bin` (MySQL's
installer), MAMP and your `PATH`. Leave the fields empty and AirSQL picks, for each server, the tools of its family
(MariaDB's for MariaDB, MySQL's for MySQL) closest to its version. Choose a program to always use that one.

A `.csv`, `.tsv`, `.xlsx` or `.json` dropped on the window (or a `.csv` or `.xlsx` on the Dock icon) opens Import File with the file chosen, and a `.sql.gz` opens Run SQL
File the same way; nothing runs until you press the sheet's button.

Export, Restore, Run SQL File, Copy to Another Server and Import File each open in a window of their own, which you can
move aside to keep working. Closing it while it runs asks first; disconnecting the connection it uses, or quitting, says
it is running and stops it.

Each window says how well its tool suits the server: **✓ suits the server**, a warning (another family's tool, or an
older version than the server), or why it can't be used (not there, too old: AirSQL needs MySQL 5.7 or MariaDB 10.3
tools or newer). The tool you pick in one is remembered for that connection: it shows, and can be changed, in the
connection editor's Options tab.

No tools at all? Install MySQL's or MariaDB's client tools (for example `brew install mysql-client`), then choose
**Find Again**. Until then, Export and Run SQL File use AirSQL's own code.

## Export a database

**Tools ▸ Export…** (or right-click a connection ▸ Export…).

1. Tick the databases or tables to export. Space ticks the selected rows; right-click for Include All, Include None and
   Include Only These. The filter above the list shows only the tables with that text, each on its own line, so ticks
   reach only what you see; what's ticked stays ticked when you clear it. One database exports without `CREATE DATABASE`, so you can restore it under any name; several
   databases export whole, each with its own name.
2. Choose the content (structure and data, structure only, data only) and the options: one consistent snapshot
   (`--single-transaction`), binary as hex, gzip, `DROP TABLE` before each table, and views, routines, triggers and
   events.
3. Pick the tool (**Choose…** beside it finds a `mysqldump` or `mariadb-dump` anywhere on this Mac, and Restore and Run
   SQL File take a `mysql` or `mariadb` the same way), where to save the file, and any extra options of your own (`--skip-comments`, `--where=…`).
4. The box under the form shows the exact command line of the tool you picked, and **Copy Command** copies it. AirSQL's
   built-in export runs no command, so the box says what it does and the button isn't there.
5. **Output** says where it goes: **One file**, **The clipboard** (small dumps, up to 32 MB) or **A folder, a file per
   object**. In a folder each table, view, routine, trigger and event gets its own `.sql` that restores on its own, read
   in the same snapshot. Choose CSV, TSV, JSON, JSON Lines or Excel in the menu beside it for a data file per ticked
   table instead: column names first, every row, and the SQL options turn off.
6. **Export**. The window shows the table being written, the bytes so far and the time left. **Stop** ends it.

The dump goes into a hidden file next to the one you chose and takes its name only when it is complete, so a stopped
or failed export never leaves half a file. When it is done, **Show in Finder** shows you the file.

**AirSQL (built in)** in the Tool menu writes the SQL itself, through a connection of its own: the tables' `CREATE`
statements, their rows as `INSERT`s (binary as hex), then views, routines, triggers and events, all read in one
consistent snapshot. Its files restore with `mysql` or with Run SQL File.

### What goes in the SQL

- **Rows as** writes `INSERT`, `INSERT IGNORE`, `REPLACE`, or `DELETE` then `INSERT` for each table, and **at most … KB
  each** caps the size of one statement, for a server with a small `max_allowed_packet`.
- **Add CREATE DATABASE and USE** makes one database restore under its own name; several always do.
- **Add DROP DATABASE first** deletes the whole database of that name when the file is restored. It is off while only
  some tables are ticked, so a file can't take the other tables with it.
- **Remove DEFINER** leaves the account out of views, routines, triggers and events, so a server without that account
  takes them; **Remove AUTO_INCREMENT values** leaves out each table's next value; **A transaction per table** speeds up
  restoring InnoDB tables.

Those last three, `DELETE` before the rows, a folder and the clipboard are AirSQL's own export's: with a dump tool chosen,
the note says so and **Use AirSQL's Built-in** switches.

## Restore a dump, or run a .sql file

**Tools ▸ Restore…** runs a `.sql` or `.sql.gz` file with your `mysql` or `mariadb`; **File ▸ Run SQL File…** opens the
same sheet with AirSQL's own runner, which splits the file into statements as `mysql` does (`DELIMITER` included) and
runs them one at a time. Compressed files are read through `/usr/bin/gzip`.

1. Choose the file and the database it runs in.
2. Choose what happens on an error: stop at the first one (what ran before it stays), or go on and count them
   (`--force`).
3. **Restore** (or **Run**).

Before anything runs, AirSQL reads the whole file for the statements that decide where it writes: `USE`,
`CREATE DATABASE`, `DROP DATABASE`, and `SET GTID_PURGED`. When the file switches to another database than the one you
chose, drops a database, or sets GTID_PURGED, or when the database it writes to has tables already, the SQL preview
sheet says so and asks first (Settings ▸ Safety ▸ *Ask before Restore…*). On a production connection it always asks.
Progress is the share of the file read, so it is real for compressed files too.

## Copy to another server

**Tools ▸ Copy to Another Server…** copies databases or tables straight from one connection to another, through a
session on each: no file in between.

- **To** and **Database**: the connection and the database the copy goes into (made if it isn't there). One database
  can take another name; views and routines follow the new name.
- **Replace tables that are there** drops the other server's tables of the same name first. It is off unless you tick
  it, and the SQL preview asks before it runs. Copies to a production connection always ask.
- If a statement fails, the copy stops; what was copied before it stays.

## Import a file

**File ▸ Import File…**, or **Import from Clipboard…** for rows copied from a spreadsheet or a text file.

1. Choose the file, or **Paste** the clipboard. CSV and other delimited text, Excel workbooks (`.xlsx`, the first sheet)
   and JSON (an array of objects, or one object a line) all work. AirSQL guesses the separator and shows the first
   rows as they'll be read, at the bottom of the window.
2. Choose the table. Each column takes a field of the file, matched by name when the first row names the columns, by
   position when it doesn't, or **Leave out** to take its default.
   Or choose **New Table…** at the end of the menu: AirSQL reads every value and proposes a `CREATE TABLE` you can edit.
   Only what the server stores unchanged becomes a number or a date: `007`, `+44` and `01/02/2026` stay text. Every
   column allows NULL, and no key is guessed: add one in the box if you want it.
3. **Import**. The rows go in one transaction: if one fails (a duplicate key, a value the column refuses), none of the
   file stays, and the message says which records. A new table stays, empty.

For text files, **Format** chooses the separator (or **Other**, any one character), the quotes and the encoding;
**Automatic** reads UTF-8, UTF-16 with a BOM, and Windows-1252 for what isn't UTF-8. **Skip rows** drops a title above the
table, **Trim spaces** tidies fields without quotes, and **Backslash escapes** reads MySQL's own `\"` inside quotes.

Empty fields and a `NULL` without quotes become NULL unless you untick it (AirSQL's own CSV writes the text NULL in
quotes, so the two come back apart), and a whole `0x…` field in a BLOB or BINARY column becomes its bytes. **Numbers use a
decimal comma** reads `1.234,56` as `1234.56` in number columns. In JSON, `null` is always NULL, `true` and `false` are 1
and 0, and nested values go in as their JSON.

**Rows** says what happens when things go wrong:

- **Stop at a duplicate** undoes the import; **Skip duplicates** keeps the row already there (`INSERT IGNORE`, which also
  lets the server adjust values that don't fit, so check its warnings); **Replace duplicates** puts the file's row in its
  place (`REPLACE`).
- **Delete the table's rows first** deletes them in the same transaction, after a warning, so a failed import brings them
  back (not on MyISAM and other tables without transactions).
- **Skip rows the server refuses** keeps the good rows and writes the others, each with the reason, to a CSV in
  Downloads; **Show Skipped Rows** finds it. A lost connection or a deadlock still stops the import and undoes it.

### Copy a result into a table

Right-click a result ▸ **Copy Result to Table…** (or **Query ▸ Copy Result to Table…**) opens the same window with the
selected rows, or all of them, into a table of this connection or a new one. NULLs, empty text and bytes stay apart.

AirSQL sends the rows as `INSERT`s: `LOAD DATA LOCAL INFILE` stays off.

## Open the mysql command line in Terminal

**Tools ▸ Open in Terminal** opens Terminal running `mysql` (or `mariadb`) on the connection, in its database. On a
[read-only connection](connections.md#add-or-edit-a-connection) it starts with `SET SESSION TRANSACTION READ ONLY`, as
AirSQL's own sessions do, so a slip can't change anything there. Exports get it too, where the dump tool knows how
(MySQL 8.4's and later); restores, Run SQL File, imports and copies into a read-only connection are refused.

## Your password stays private

The client tools get the login from a temporary option file that only you can read (file mode 0600, in a private
folder in AirSQL's Application Support folder), passed as `--defaults-file`, so `~/.my.cnf` and `/etc/my.cnf` don't
change where they connect. The password is never on the command line, in the environment, or in the command shown.
AirSQL removes the file as soon as the tool has read it: once a dump has started writing, once a restore is reading
its input, ten seconds after Terminal starts `mysql`; and anything left behind at the next launch.

Over TCP the tools check TLS the way the connection asks: MySQL's with `--ssl-mode`, MariaDB's with `--ssl` and
`--ssl-verify-server-cert`. A tool never runs without its certificate check. A certificate you trusted (pinned) is
checked by MariaDB tools that take `--ssl-fp`, which get its fingerprint; AirSQL asks the tool's `--help` whether it
does. Other tools run on such a connection only if it has a CA file and checks the authority, against that file.
MySQL's tools check certificates only against a CA file. When the tool can't check the server, the window says what
to do and **Use AirSQL's Built-in** switches to AirSQL's own export or runner, which check it as AirSQL does; such a
tool is never picked for you.

With a certificate you trusted and no CA file, Export, Restore and Run SQL File also offer MySQL's tools an unticked
box, **Run without checking the certificate**. The connection is encrypted but can't prove it's this server, so the
login and the dump could be exposed, and a restore's data goes to a server that isn't proved. The tool then runs with
`--ssl-mode=REQUIRED`, never without TLS; the tick lasts one run, is never saved, clears when you change the tool, and
the run is noted in the SQL log. MariaDB's older tools don't get the box, as without a check they can't insist on TLS.
Open in Terminal follows the same rules with an alert each time instead of a box: **Cancel** is the default, and **Open
Without Checking** goes on with TLS required, saving nothing. Copy to Another Server needs neither: it uses no client
tool, and AirSQL's own sessions check the certificate on both sides.

Client tools reach SSH and proxy routes through the connection's private socket once AirSQL is connected through them.
