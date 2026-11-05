---
title: Check SQL before it runs
nav_order: 5
---

# Check SQL before it runs

Some changes show their SQL in a sheet before anything runs: applying edits in a table, changing a table's structure,
dropping or renaming, restoring a dump, and sync scripts.

- **Warnings** say what else will happen, such as rows deleted in other tables (ON DELETE CASCADE), or a table whose
  engine can't roll back.
- A change on a **Production** connection says so in red.
- To drop a database (and, on Production, a table), type its name first.
- When an **agent** asked for the change, the sheet names it. Nothing runs until you approve it; **Decline** refuses it.
- **Save as Liquibase changeset** (a table's edited rows, the table and object editors, dropping, emptying or renaming
  in the sidebar, and sync scripts) saves the statements as a changeset in a changelog once they have run (see
  [Liquibase changelogs](liquibase.md)). In the query tab, use **Query ▸ Save as Changeset…**.
- **Copy SQL** copies the statements. **Cancel** changes nothing.
- **Passwords and keys** show as `<secret>` here and in what Copy SQL copies, as in the [SQL log](sql-log.md); only the
  statements that run have them. Such a change can't be saved as a changeset.
