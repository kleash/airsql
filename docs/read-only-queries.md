---
title: Read-only queries
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

## Quotes inside strings

Write a quote inside a string by doubling it: `'O''Brien'`. `'O\'Brien'` is refused, because whether the backslash
escapes the quote depends on the server's `NO_BACKSLASH_ESCAPES` setting, so the same text could be read as two
different statements.

## A safeguard, not the only one

For a hard guarantee, connect agents with a database user that can only read.
