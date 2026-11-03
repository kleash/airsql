# AirSQL agent guide

AirSQL is a Mac app for MySQL and MariaDB. Through its MCP server you can read the schemas of the connections the
person at the Mac allows, run read-only queries, profile tables, and propose SQL in a console tab for the person to
edit and run. You never see passwords, and you can't change data, connections or settings: each connection's access
level is the person's choice alone.

## overview

1. `context` first: the connections you may use (name, id, access level, MySQL or MariaDB and its version, current
   database, schema hash, row cap and timeout), the person's active connection and the open console tabs. A connection
   whose access is Off isn't listed; `hiddenConnections` counts them.
2. `get_schema` once per connection: every database's tables in one compact reply. Keep its `hash` and pass it back as
   `if_changed_from` later: an unchanged schema answers `{unchanged: true}` and costs nothing.
3. `describe` the tables you'll query (columns, keys both ways, indexes, CREATE statement, row estimates).
4. `run_queries` with several statements at once; `explain` a slow one; `profile` a table you don't know yet.
5. To change anything, write the SQL and call `open_in_console`: the person reads it, edits it, runs it. Then
   `read_console` shows what they ran and the result or error.

Connections must be connected in AirSQL (by the person) before the database tools work on them.

## access

Each connection has one level, set by the person in Settings ▸ Agents (or the connection's Agents tab):

- **Off** (the default; Production connections start here): invisible to agents.
- **Schema**: `get_schema`, `describe`, the schema resource, `open_in_console`; `read_console` without result rows.
- **Schema + read**: also `run_queries` and `explain`, within the connection's row cap and timeout (Settings ▸ Safety:
  10,000 rows and 30 s by default, 1,000 and 15 s on Production).
- **Schema + read + analytics**: also `profile`, `to_file`, ten times the rows and four times the timeout.

Sample rows are a separate switch: when on, `describe` shows a few rows of each table. A call beyond the level is refused
with the level it needs. Ask the person to change a level; you can't.

## read-only

Statements you write run only when AirSQL's classifier proves them read-only: one statement, `SELECT`,
`WITH … SELECT`, `SHOW`, `DESCRIBE` or `EXPLAIN` (not `EXPLAIN ANALYZE`). It refuses `INTO`, `FOR UPDATE`,
`LOCK IN SHARE MODE`, optimizer hints, temporary tables, and functions such as `SLEEP`, `BENCHMARK`, `GET_LOCK`,
`LOAD_FILE` and stored functions. Each statement then runs on AirSQL's own agent session, which is read-only, inside
`START TRANSACTION READ ONLY` … `ROLLBACK`, with the server's statement timeout and a watchdog. Both guards always apply.
A refused statement comes back with `ok: false` and the reason; the other statements of the call still run.

This AirSQL build doesn't have the classifier yet, so it refuses every statement you write (run_queries, explain,
profile with `where`) until it does. The schema tools, describe and profile without `where` work.

## tools

- `context {}`: start here.
- `get_schema {connection, databases?, format?: compact | ddl, if_changed_from?}`: compact lines look like
  `orders: id bigint PK AI, customer_id int NULL → customers.id, total decimal(12,2) ='0.00'; KEY(customer_id)`:
  PK primary key, AI auto-increment, NULL nullable, `=` default, `→` foreign key, then composite keys and indexes, and
  `-- comment`. Views start with `view`, sequences with `sequence`. System databases are left out unless named. A
  database too big for the reply comes as names only: name it, or describe its tables.
- `describe {connection, objects: ["table" or "db.table"], database?}`: names in backquotes may contain dots.
- `run_queries {connection, database?, queries: [{sql, max_rows?}], format?: json | csv, to_file?}`: 200 rows per
  statement unless `max_rows` says more (up to the row cap); `capped: true` means there were more. Values are text
  (binary as 0x… hex), NULL is null in JSON and an empty field in CSV, long values are cut at 2,000 characters.
  `to_file: true` (analytics) writes each result to a CSV or JSON file in AirSQL's agent export folder and answers with
  its path, rows and size instead of the rows.
- `profile {connection, table, database?, columns?, where?}`: row count, and per column NULLs, distinct values, min,
  max, average (numbers) and the five most common values, computed on the server.
- `explain {connection, sql, database?, format?: traditional | json}`.
- `open_in_console {sql, title?, connection?}`: never runs anything.
- `read_console {tab?}`: by id or title from `context`; default the active console tab.
- `guide {topic?}`: this guide.

Long calls send progress notifications when your client asks for them (`_meta.progressToken`).

## resources

Each connected connection you may read has its compact schema as a resource, `airsql://<connection name>/schema`
(percent-encoded), the same text as `get_schema`. `resources/list` lists them.

## recipes

- **Answer a question about the data**: `context` → `get_schema` → `describe` the tables involved → `run_queries`
  with a `COUNT(*)` first, then the query, with `max_rows` small.
- **Analyse a big result**: with analytics, `run_queries` with `to_file: true`, then read the file with your own tools.
- **Change data or structure**: write the statements, then `open_in_console` with a clear title; tell the person what
  they do. After they run them, `read_console`.
- **Check a query's cost**: `explain` it, look for full scans (`type: ALL`) on big tables, `describe` for indexes.

## troubleshooting

- "isn't running, or agents are off": open AirSQL and turn on Settings ▸ Agents ▸ Allow AI agents to use AirSQL.
- "No connection … is open to agents": use a name or id from `context`; the person may have set it to Off.
- "isn't connected": ask the person to connect it in AirSQL.
- "needs Schema + read" (or analytics): the person can raise the level in Settings ▸ Agents.
- "Refused": the statement isn't provably read-only; rewrite it as one plain SELECT, or propose it with
  `open_in_console`.
- "Stopped at the agent timeout": narrow the query (WHERE, LIMIT), or ask for the analytics level.
