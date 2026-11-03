---
title: The SQL console
---

# The SQL console

A console tab is where you write and run SQL on one connection. Its statements run one at a time, on the connection's
own session, which every console tab of that connection shares.

## Open a console

- **File ▸ New Query** (⌘T), the **+** at the end of the tabs, or **New Query** on a connection's menu opens an empty
  console on the selected connection.
- **File ▸ Open…** (⌘O) opens .sql files, each in a console of its own. You can also drop .sql files on the editor.
- **File ▸ Save** (⌘S) saves the console's text to its file; **Save As…** to a new one. A tab with unsaved text shows a
  dot instead of its close button.
- When you quit, the open consoles are kept, unsaved text included, and come back the next time you open AirSQL.
- **Query ▸ Change Connection…** runs the console's statements on another connection.

## Write SQL

- Keywords, names, strings, numbers and comments have their own colours; the brackets around the cursor are marked.
- **Completion** opens as you type: after FROM or JOIN the tables and views, after JOIN first the joins that foreign
  keys give (`orders o ON o.customer_id = c.id`), after `alias.` that table's columns, after USE the databases, and
  elsewhere the statement's columns, functions and keywords. ↑ and ↓ choose, Return or Tab inserts, Escape closes;
  ⌥⎋ opens it anywhere. It comes from what AirSQL already read of the schema: nothing is sent to the server while you
  type.
- **View ▸ Query Helpers** shows beside the editor the columns of the tables the statement at the cursor names, the
  server's functions by kind, and the keywords. Double-click one to put it in at the cursor.
- **Edit ▸ Find** (⌘F) and **Find and Replace** (⌥⌘F) find in the editor, with **Regular Expression** and **Match
  Case**. With a regular expression, `$1`, `$2`… in the replacement put in its groups. **Replace All** is one change
  that **Undo** takes back.
- **Edit ▸ Comment Lines** (⌘/) comments the selected lines out with `--`, or takes the comment away. **Shift Right**
  (⌘]) and **Shift Left** (⌘[) indent; so do Tab and ⇧Tab on several lines.
- **Query ▸ Format SQL** (⌥⇧⌘F) puts each main clause on a line of its own and reserved words in capitals. It changes
  nothing else: names, values, comments and `/*! … */` code stay exactly as they are, and statements inside a
  `DELIMITER` block are left alone. If it couldn't do that, it leaves the SQL as it was and says so.
- **View ▸ Bigger** (⌘+), **Smaller** (⌘−) and **Actual Size** change the text size for a moment; Settings ▸ Editor
  sets it for good.

## Run it

| To run | Press |
|---|---|
| The statement at the cursor, or the selected text | ⌘↩ (or ⌃F9) |
| Only the selected text | Query ▸ Run Selection |
| Every statement | ⇧⌘↩ (or F9) |
| Stop the statement that is running | ⌘. (Query ▸ Cancel) |

The statement that ran is highlighted for a moment, so there is no "which statement?" question. Statements are split
on `;`, or on the delimiter a `DELIMITER` line sets, and sent one after another; a run stops at the first error.

While a statement runs, the bar above the results shows which one and for how long, with **Cancel**; the status bar
lists it too. Cancel stops only that statement: AirSQL checks the server is still running it before it stops it. A
connection can have a query timeout: a statement that runs longer is stopped the same way, and Messages says so.

Console tabs of one connection share its session, so while one runs a statement the others wait.

## Results and Messages

- Each result set gets a **result tab** under the editor, named after the comment just above its query (`-- Top
  customers` names it "Top customers"), else "Result 1", with its rows and columns. The next run replaces the result
  tabs, unless you **pin** one (right-click it, or Query ▸ Pin Result).
- Double-click a result tab to rename it; right-click it to pin, rename or close it.
- **Messages** lists what each statement did: its rows or the rows it changed, how long it took, the server's
  warnings, or its error and the line it points to (that line is marked red beside the editor). Double-click a message
  to select its statement.
- A result keeps at most its first 100,000 rows; the tab then says it is cut short.

## Transactions

- **Tx: Auto-commit** (the toolbar, or Query ▸ Transaction Mode) commits each statement by itself. In **Manual**, your
  changes wait in a transaction until you press **Commit**, or **Rollback** to undo them. Leaving Manual with changes
  waiting asks first whether to commit them or roll them back.
- **Query ▸ Isolation Level** sets how the console's transactions see others' changes. Until you choose one, the
  server's own applies (usually Repeatable Read).
- While a transaction is open, the status bar says so, with the number of rows changed, and how long it has been open
  once that passes the time set in Settings ▸ Safety.
- Closing the connection's last console with a transaction open asks first: **Commit**, **Roll Back** or keep the tab.

## What asks first

The safety settings (Settings ▸ Safety, or a connection's own) decide which statements ask before they run. The SQL
shows in a sheet, with what it will do:

- an UPDATE or DELETE without WHERE, which changes every row of its table;
- DROP and TRUNCATE; dropping a database needs its name typed, and so does dropping or emptying a table where the
  connection says so (the Production preset does);
- on a connection where every write asks (the Production preset), any statement that may change data.

## History, the SQL log, plans and profiles

- **Query ▸ Query History** (⌘Y) lists the statements run on the console's connection, newest first. Type to search;
  Return or a double-click puts one in the editor at the cursor. Passwords in statements are masked before they are
  kept, as in the SQL log.
- **View ▸ SQL Log** (⌥⌘L) shows every statement AirSQL sent, as they come. See [the SQL log](sql-log.md).
- **Query ▸ Explain** (⌥⌘E) shows how the server would run the statement at the cursor, without running it: as the
  server's table, or as a tree (MySQL's own tree; MariaDB's plan made into one).
- **Query ▸ Profile** runs the statement and shows where the server spent its time, step by step, where the server keeps
  profiles (SHOW PROFILE).
- **Query ▸ Save as Changeset…** saves the selected statements (or the one at the cursor) as a Liquibase changeset in a
  changelog you choose. See [Liquibase changelogs](liquibase.md).
