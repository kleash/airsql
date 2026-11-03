---
title: Compare two databases
nav_order: 16
---

# Compare two databases

**Tools ▸ Compare…** (or **Compare…** in a connection's or a database's menu, which starts from it) opens a window
that compares two databases, on the same server or on two different connections, such as production against staging
or MySQL 8 against MariaDB. A connection that isn't connected connects when you choose it, asking for a password or
to trust a certificate on the compare window as the main window would; each side then works through its own route, on
a session of its own. The compare only reads; nothing changes until you run the sync script yourself.

## Run a compare

1. Choose the **source** on the left and the **target** on the right: a connection, then one of its databases (or
   type its name). The sync script makes the target like the source; **Swap** turns them around.
2. Choose what to compare: **Structure and Data**, **Structure** or **Data**.
3. Click **Compare** (⌘R). The bar under the setup shows the table and chunk being checked, and **Cancel** (⌘.)
   stops the compare; the statement running on each server is stopped too. The work is also listed in the main
   window's activity list.

The summary says how many tables match, differ in structure, or are only on one side, how many rows differ, and how
much of the data had to come over the network. The list shows what differs first: **only left** and **only right**
for objects on one side, **structure**, **data**, then **match**. Click an object to see it; double-click it to see
its rows when they differ.

## What is compared

- **Structure:** tables (columns, indexes, foreign keys, checks, engine, comment), views, procedures, functions,
  triggers, events and sequences. The **Structure** tab shows both definitions side by side, the lines only one
  side has marked.
- **Data:** the rows of every table both sides have, matched on the primary key, or on a unique key whose columns
  are all NOT NULL. The **Data** tab shows the rows that differ in the [data grid](data-grid.md), as a sync would
  change the target: rows only in the source in green (the script inserts them), rows only in the target in red and
  struck through (it deletes them), then rows in both whose differing cells are amber (it updates them); hold the
  pointer over an amber cell to see both values. The line above the rows counts each kind. The grid works as
  elsewhere: select cells or rows with ⌘ and ⇧, copy them in any format (⌘C, **Copy with Headers**, **Copy As**),
  sort by a header, see a long value in the value panel, or save the rows with **Export Rows…**. Tables without such a
  key are still checked as a whole, but their rows can't be matched or synced. Generated columns are left out: their
  values follow from the others.

MySQL and MariaDB write the same thing differently, and the compare reads them alike: `int(11)` and `int`, MariaDB's
JSON (a LONGTEXT with a check) and MySQL's, `CURRENT_TIMESTAMP` and `current_timestamp()`, `NO ACTION` and
`RESTRICT`, check constraints the two servers name differently. Each flavour writes a view's body its own way,
though, so the same view on MySQL and on MariaDB can still show as different.

### Ignore rules

**Ignore Rules** chooses differences the compare doesn't count. All four are on at first:

- **AUTO_INCREMENT Values**: tables' next AUTO_INCREMENT values.
- **DEFINER**: who views, routines, triggers and events run as. The script then leaves DEFINER out, so they run as
  whoever runs the script.
- **Collations and Character Sets** of tables and columns (MySQL 8 and MariaDB have different defaults).
- **Whitespace in Definitions**: spaces and line breaks in bodies, outside quoted text.

### Tables…

After a first compare, **Tables…** lists the source's tables. Untick a table to leave it out, give the target table
it should be compared with when it was renamed there, list columns whose values shouldn't count (such as
`updated_at`), or add a WHERE condition for its rows on both sides. Double-click a table to tick or untick it, or
right-click the selected tables for Compare and Leave Out. **Leave Out of Next Compare** in an object's menu unticks it
too.

## How the data compare stays fast

Each server sums up the rows of a chunk of the table (10,000 rows by key order) as a row count and a total of 64-bit
row hashes, computed from MD5. Only a chunk whose sums differ is looked at more closely: it is split into smaller
chunks, and for the small ones that still differ each row's key and hash come over, then only the rows that differ.
A million identical rows are checked without fetching any.

The hashes tell apart values that careless checksums mix up: a NULL and an empty string, values moved from one column
to another, `'a'` and `'A'` or `'a '` under a case-insensitive collation, the same text in latin1 and utf8mb4 (which
counts as the same). Both sessions use time zone `+00:00`, so TIMESTAMP values compare by the moment they stand for.
Floats, decimals written with another scale and JSON with other spacing or key order are compared as values.

## The sync script

The **Sync script** box shows the statements for the selected object; **Copy Sync Script** copies them. **Sync
Script…** opens the whole script in a [console](console.md) tab of the target named “Sync script”, to read (it can't
be edited there; **Save As…** keeps a copy). It never runs on its own: **Run** in that tab brings the compare window
back with the script in the [SQL preview](sql-preview.md), where you can copy it, run it on the target, or cancel. It
runs:

1. `USE` the target database and `SET time_zone = '+00:00'`;
2. the structure changes, in order: foreign keys and objects that go or change are dropped first, then new tables,
   `ALTER TABLE`, views (after the views they use), foreign keys, routines, triggers and events. MySQL and MariaDB
   commit each structure change on its own: they can't be rolled back;
3. the row changes in one transaction: DELETE (children before parents), then UPDATE and INSERT (parents first). Each
   statement must change exactly the rows it names; if one doesn't, because the target changed since the compare,
   everything in the transaction is rolled back. Tables on MyISAM, Aria or MEMORY can't roll back, and the preview
   warns about them.

**Destructive steps are left out** unless you tick **Include destructive steps**: dropping tables, columns, indexes,
checks, foreign keys and other objects only the target has, deleting rows only the target has, and column changes
that could cut or refuse values (a shorter type, NOT NULL). Each destructive statement is marked with a
`-- Destructive:` comment, and the preview's button turns red.

Rows of tables only in the source come with their `CREATE TABLE`. New columns of existing tables get their default
values: after running the script, compare again to copy their values. After a sync, AirSQL offers to compare again.

**Save as Changeset…** saves the script as [Liquibase](liquibase.md) changesets in a changelog you choose; so does
**Query ▸ Save as Changeset…** in the “Sync script” tab.

## Compare two results, or a result with a table

In a [console](console.md), **Compare With…** (a result tab's right-click menu, or **Query ▸ Compare With…**) compares
the result shown with another one, row by row:

- **Compare with** offers the other result tabs of the window, this console's nearest first (a result from another
  console tab, such as the same query on another server, carries that tab's name), then the tables and views of the
  console's database.
- **Match rows on** says which columns tell rows apart: the result's key when it has one, a single column, or every
  column (rows then differ only as being on one side). Rows with the same values there are the same row; when several
  share them, they pair up in the order they come.
- The rows that differ open in a result tab of their own, named after the other side (“vs Yesterday”), next to the
  result: rows only in this result green, rows only in the other red and struck through, and in rows on both sides the
  cells that differ amber (hold the pointer over one to see both values). The results bar says how many rows are the
  same. When nothing differs, AirSQL says so instead.

Only the columns both sides have, by name, are compared, with the rules of the data compare: numbers, decimals of
another scale and floats as numbers, JSON as values (MySQL writes it its own way), NULL apart from an empty string. A
table is read up to 100,000 rows; for a larger one, compare the result of a query with a WHERE, or whole tables with
**Tools ▸ Compare…**. Comparing only reads.

## Export the report

**Export Report…** saves what the compare found as **HTML** (to read or send), **CSV** (every difference on its own
line, for a spreadsheet) or **Markdown** (for a ticket). HTML and Markdown list up to 1,000 rows per table.

## Limits

- More than 100,000 differing rows in one table are reported as too many to list, without sync statements for that
  table: narrow the compare with a WHERE, or copy the table instead.
- Partitioning, row formats and system versioning aren't compared.
