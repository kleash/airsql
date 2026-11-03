---
title: Read-only queries
nav_order: 8
---

# Read-only queries

Where only reading is allowed, such as a query from an AI agent, AirSQL first checks that the statement can only
read. The check is strict on purpose: when in doubt it refuses, and it says why in one line.

## What passes

One statement at a time (a `;` at the end is fine):

- `SELECT`, with `UNION`, subqueries and `WITH … SELECT`;
- `SHOW …`;
- `DESCRIBE`, `DESC` or `EXPLAIN` of a table; `EXPLAIN` of a `SELECT` (`FORMAT=JSON` and `FORMAT=TREE` too);
  `EXPLAIN FOR CONNECTION` and a connection number.

## What is refused, wherever it appears

- More than one statement, and every other kind of statement: `UPDATE`, `INSERT`, `SET`, `CALL`, `DO`, `CREATE` and
  the rest, and `WITH …` followed by anything but `SELECT`.
- `EXPLAIN ANALYZE`, which runs the statement, and `EXPLAIN` of `INSERT`, `UPDATE`, `DELETE` or `REPLACE`.
- `INTO` (a file or variables), `FOR UPDATE`, `FOR SHARE` and `LOCK IN SHARE MODE`.
- Optimizer hints, `/*+ … */`: they can lift the server's time limit (`MAX_EXECUTION_TIME`).
- Temporary tables: they can be written even in a read-only transaction.
- Setting a variable with `:=`, and moving a sequence on (`NEXT VALUE FOR`, `NEXTVAL`, `SETVAL`).
- Any function other than the built-in ones that only compute. So `SLEEP`, `BENCHMARK`, `GET_LOCK` and the other
  locks, `LOAD_FILE`, `LAST_INSERT_ID` and the waits for replication are refused, and so are user-defined functions,
  stored functions (`shop.bonus(…)`, or any name AirSQL doesn't know) and function names in quotes.

The text inside executable comments, `/*! … */` and `/*M! … */`, counts as code, whatever server version it names.

## Backslashes and double quotes

The check reads a backslash in a string as the server does: as an escape, unless the session's sql_mode has
`NO_BACKSLASH_ESCAPES`. Double-quoted text with a backslash in it is refused either way: with `ANSI_QUOTES` it is a
name, where a backslash escapes nothing, so the server could end it somewhere else. Write strings in single quotes.

## A safeguard, not the only one

For a hard guarantee, connect agents with a database user that can only read.
