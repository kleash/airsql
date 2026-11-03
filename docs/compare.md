---
title: Compare two databases
nav_order: 14
---

# Compare two databases

**Tools ▸ Compare…** (or **Compare…** in a connection's or a database's menu, which starts from it) opens a window
that compares two databases, on the same server or on two different connections, such as production against staging
or MySQL 8 against MariaDB. Connect both connections first: each side then works through its own route, on a session of
its own. The compare only reads; nothing changes until you run the sync script yourself.

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
  are all NOT NULL. The **Data** tab lists rows **missing** from the target, **extra** in it, and **changed** rows,
  with the cells that differ marked (hold the pointer over one to see the target's value). Tables without such a key
  are still checked as a whole, but their rows can't be matched or synced. Generated columns are left out: their
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
`updated_at`), or add a WHERE condition for its rows on both sides. **Leave Out of Next Compare** in an object's
menu unticks it too.

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

## Export the report

**Export Report…** saves what the compare found as **HTML** (to read or send), **CSV** (every difference on its own
line, for a spreadsheet) or **Markdown** (for a ticket). HTML and Markdown list up to 1,000 rows per table.

## Limits

- More than 100,000 differing rows in one table are reported as too many to list, without sync statements for that
  table: narrow the compare with a WHERE, or copy the table instead.
- Partitioning, row formats and system versioning aren't compared.
