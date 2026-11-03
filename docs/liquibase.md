# Liquibase changelogs

AirSQL writes [Liquibase](https://www.liquibase.com) changelogs in Liquibase's **formatted SQL**: plain SQL with
`--changeset author:id` lines, which Liquibase reads as it is. You can write one of a whole database, save a compare's
sync script as changesets, or save any change AirSQL shows you before it runs. AirSQL only writes the files: run them
with your own `liquibase` (`liquibase update`, `liquibase rollback-count 1`…).

## A changelog of a database

**Tools ▸ Generate Liquibase Changelog…** writes a changelog of a database of the connection the window is about.

- **Content**: **DDL** writes the objects' structure, **DML** their rows, **DDL + DML** both.
- The list holds the database's tables, views, procedures, functions, triggers, events and sequences, each ticked.
  Untick what you don't want; space ticks the selected rows, double-click ticks one, and the right-click menu
  includes all, none or the selected rows. For **DML**, tick **Rows** for the tables whose rows to write, and type a
  **WHERE** condition (double-click the cell) to write only some of them, such as `active = 1`.
- **Author** and **Ids** make each `--changeset` line (see [Settings](#settings) below). **Rollback** adds the
  `--rollback` line that undoes each object. **Skip what already exists** adds preconditions that mark a changeset
  as ran, rather than run it, when its object is already in the database: handy for a database made before you used
  Liquibase.
- **Files**: one file, or a folder with a file per changeset and `db.changelog-master.yaml`, which includes them in
  order: point Liquibase at that one.

The preview beside the form shows the changelog as it will be written. **Save Changelog** reads each table's rows
then, in key order, from one consistent snapshot; the work is listed in the activity list, with **Stop**. Nothing is
left behind if it fails or you stop it.

### What the changelog holds, in order

Each object gets one changeset, in an order that runs cleanly on an empty database:

1. sequences, then tables, each without its foreign keys and without its next AUTO_INCREMENT value;
2. the tables' rows (parents before children), as INSERTs of 100 rows each;
3. the foreign keys, one changeset each (`ALTER TABLE … ADD CONSTRAINT`);
4. functions and procedures, then views (each after the views it reads), triggers and events.

Rows come before foreign keys and triggers, so neither gets in their way. A changeset of rows first sets the session
as the rows were read: in UTC (TIMESTAMP values stay as they were), without strict mode (zero dates load) and with
`NO_AUTO_VALUE_ON_ZERO` (a 0 in an AUTO_INCREMENT column stays 0); it puts the session's own settings back at its end.
A table with zero dates or TIMESTAMP defaults gets the same around its `CREATE TABLE`.

Attributes are added only where they are needed:

- A procedure, function, trigger or event holds semicolons of its own, so its changeset says `splitStatements:false`
  and runs it as one statement (or ends it with `//` and says `endDelimiter://`, as you choose in Settings).
- `stripComments:false` keeps comments Liquibase would otherwise remove, such as MySQL's `/*!80023 INVISIBLE */`.
- Views are written as `CREATE OR REPLACE VIEW` with `runOnChange:true`: edit a view in the changelog and Liquibase
  replaces it.
- A comment line in a routine that Liquibase would read as one of its own (`-- rollback …`, `-- changeset …`)
  becomes a `#` comment, which MySQL and MariaDB read the same way.

Every changeset AirSQL writes is read back the way Liquibase reads it before it is saved; if Liquibase would split it
differently from how it runs here, AirSQL says so and doesn't write it.

## Save a change as a changeset

When the [SQL preview](sql-preview.md) shows a change (the table editor, a view or routine, a sync script), tick
**Save as Liquibase changeset**: once the change has run, a sheet shows the changeset. In the console, select the
statements (or put the insertion point in one) and choose **Query ▸ Save as Changeset…**. In the compare window,
**Save as Changeset…** saves the sync script: a changeset per structure step and one per run of row changes on a table,
destructive steps saying so in their `--comment`.

Choose the changelog to add to (**Choose…**), or start one (**New…**). The changesets go at its end and their ids carry
on its numbering. A change keeps only what Liquibase runs: `USE` and the transaction around it are left out (each
changeset runs in a transaction of its own), and so is the database the change named its objects with, so the
changeset runs in whichever database Liquibase updates. A `--rollback` is added when every statement of the change can
be undone: DROP for what it creates, DROP COLUMN for an added column, DROP INDEX and DROP FOREIGN KEY for added keys,
RENAME back. Row changes and drops get none.

## Settings

**Settings ▸ Liquibase** holds:

- **Author**: who the changesets are by; empty uses your Mac account's name.
- **Ids**: `{date}` (20261102), `{time}` (141500), `{n}` (001, 002…, counting on from the changesets a changelog has)
  and `{object}` (the table, view or routine). An id that is already taken gets `-2`, `-3`….
- **Changelog files**: one file, or a folder with a file per changeset.
- **Routines**: as the changeset's only statement (`splitStatements:false`), or with each statement ended by `//`
  (`endDelimiter://`). A change with several statements and a routine among them always uses `//`.
- **Leave DEFINER out** of views, routines, triggers and events (on at first), so they run as whoever runs the
  changelog rather than as an account the other server may not have.
- **Add --rollback** where it can be written (on at first).

## Limits

- Routines keep the sql_mode of the session Liquibase runs them in, not the one they were made with.
- Liquibase reads `${name}` in a changeset as a property it may replace; text like that in your data or routines is
  replaced when you define such a property.
- Generated columns are left out of the INSERTs: their values follow from the others.
