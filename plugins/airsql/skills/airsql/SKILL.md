---
name: airsql
description: Use AirSQL's MCP tools to answer questions about the person's MySQL, MariaDB or MongoDB databases (schemas, tables, data, query plans) and to propose SQL for them to run. Use when the person mentions their database, a table, a query or AirSQL.
---

# Working with AirSQL

AirSQL is the person's Mac app for MySQL and MariaDB, and MongoDB. Its tools reach only the connections the person allows, at the
access level they chose, and never change anything.

1. Call `context` first. It lists the connections you may use, their access level and whether they're connected.
2. Read the schema with `get_schema` (one call per connection; keep the `hash` and pass it as `if_changed_from` next
   time), then `describe` the tables you need. `search_columns` finds a column by name without the whole schema.
3. Answer with `run_queries` (several statements per call, small `max_rows`), `explain` and `profile`.
4. On a MongoDB connection (`engine: mongodb` in `context`), use the `mongo_` tools instead: `mongo_list_databases`,
   `mongo_list_collections`, `mongo_schema_sample` for a collection's shape, then `mongo_find`, `mongo_aggregate`,
   `mongo_count`, `mongo_distinct`. Documents and pipelines are Extended JSON text in strings,
   both ways: the documents and indexes you get back are strings too, to parse.
5. Never try to write. To change data or structure, write the SQL and call `open_in_console` with a clear title, tell
   the person what it does, and after they run it, `read_console`.

If a tool says a level is needed, or a connection isn't connected, tell the person what to change in AirSQL rather than
working around it. `guide` has the details.
