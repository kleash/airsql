# Check SQL before it runs

Some changes show their SQL in a sheet before anything runs: applying edits in a table, changing a table's structure,
dropping or renaming, restoring a dump, and sync scripts.

- **Warnings** say what else will happen, such as rows deleted in other tables (ON DELETE CASCADE), or a table whose
  engine can't roll back.
- A change on a **Production** connection says so in red.
- To drop a database (and, on Production, a table), type its name first.
- When an **agent** asked for the change, the sheet names it. Nothing runs until you approve it; **Decline** refuses it.
- **Save as Liquibase changeset** saves the statements as a changeset in a changelog once they have run (see
  [Liquibase changelogs](liquibase.md)).
- **Copy SQL** copies the statements. **Cancel** changes nothing.
