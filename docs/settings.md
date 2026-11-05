---
title: Settings
nav_order: 4
---

# Settings

Open **AirSQL ▸ Settings…** (⌘,). Changes are saved as you make them.

## General

- **Appearance**: **System** follows the Mac's light or dark mode; **Light** always uses Porcelain, **Dark** Deep
  Water.
- **Settings folder**: where your connections and settings are kept. Passwords are in your Keychain, never there.

## Editor

- **Wrap long lines**: wrap them at the editor's edge instead of scrolling sideways; on at first (**View ▸ Word Wrap** too).

- **Font**: the SQL editor's, from the fonts whose letters are all one width (SF Mono at first).
- **Tab width** and **Indent with tabs**: how wide a tab or an indent is, and whether Tab puts in a tab character or spaces.
- **Text size**: the SQL editor's (13 pt at first). **View ▸ Bigger** (⌘+) and **Smaller** (⌘−) change it for a
  moment; **Actual Size** (⌘0) goes back to this size.

- **Add an alias to a table**: completing a table after FROM or JOIN adds one, as `orders o`; on at first.
- **Change keywords' case as you type**: a reserved word takes the case set in [Format](#format) once you finish it; off at first.
- **Checks**: what the editor underlines while you type (see [Checks while you type](console.md#checks-while-you-type)).
  All are on at first; turn off any you don't want.

## Format

How **Query ▸ Format SQL** lays out SQL, with a preview of a sample below. **Preset** sets all the rules at once; change any
of them after.

- **Keywords**, **Types**, **Functions**, **Names** and **Aliases**: as written, in capitals or in small letters. Completion
  puts keywords and functions in the same case. Leave **Names** as written unless your server ignores their case.
- **Indent**, **Lists** (a line per item, when long, or never; **Comma first**), **Conditions**, **Joins**, **Subqueries**
  (where brackets go; **Right-align clauses**), **Layout** and **Spaces**.

## Grid

- **Text size**: the grid's (12 pt at first), open grids' too. ⌘+, ⌘− and ⌘0 change it the same way for the grid with
  the focus; a grid made bigger or smaller keeps its size until ⌘0.
- **Font**: the grid's font, or the system's.
- **Lines per row**: how many lines of a value with line breaks each row shows (1 by default).
- **Date format**: the pattern Display As ▸ Settings' Date Format uses.
- **Rows per page**: how many rows a table or result loads at a time (1,000 by default).
- **Most rows in a result**: where a console result stops; the statement stops on the server there (100,000 by default).
- **Open tables newest first**: a table with an AUTO_INCREMENT key shows its newest rows first until you sort it (on by
  default).
- **Long values**: how many characters of a long value a table's page reads (1,000 by default; 0 reads every value whole).
  Load Full Cell reads the rest.
- **Load All asks above**: Load All asks first when a table has more rows than this (100,000 by default), since every
  row is then held in memory.
- **NULL shown as**: how empty values look in the grid, open grids' too.
- **Transpose results with one row**: a query result with a single row opens turned on its side, one line per
  column (on by default).

## Connections

- **Load details up to … tables**: on a server with more tables than this, a database's columns, indexes and keys load
  when you open it, so connecting stays quick.
- **Read the schema every … minutes**: reads connected schemas again on a timer, to catch changes others make; 0 (the
  default) reads them only at connect and on Refresh.

## Safety

What asks first before data changes. These are the defaults; a connection can have its own (every switch and limit
below, in its Safety tab), and a connection coloured Production starts with a strict preset.

| Setting | Default | Production |
|---|---|---|
| Ask before UPDATE or DELETE without WHERE | on | on |
| Ask before any write from the query tab | off | on |
| Show the SQL before the grid's Apply | off | on |
| Ask before DROP or TRUNCATE (a database's name is always typed) | on | on, table names typed too |
| Ask before restoring into a database that has tables | on | on |
| Leave DROP and DELETE out of sync scripts unless ticked | always | always |
| Ask before agents change anything | on | on |
| Agents' rows per query and time limit | 10,000 and 30 s | 1,000 and 15 s |
| Warn when a transaction stays open | 15 minutes | 5 minutes |
| Ask before sorting a large table by a column without an index | on | on |
| Warn when closing with an open transaction or pending edits | on | on |

**Restore Defaults** puts every switch back. Read-only is a switch of each connection. Agents can read these settings
but never change them.

## Agents

- **Allow AI agents to use AirSQL**: off until you turn it on. Agents never see passwords.
- **Connections**: what agents may do with each connection: Off (where every connection starts), Schema, Schema + read,
  or Schema + read + analytics; and **Sample rows**, which lets them see a few rows of each table. Right-click a
  connection for the same choices; double-click it to open its settings at the Agents tab.
- **Exports**: the only folder agents save files in.
- **Add to Claude Code…** and **Add to Gemini CLI…**: show the change to that program's settings that adds AirSQL, and
  make it when you click Add. **Copy** gives the command other MCP clients start.

More in [AI agents](agents.md).

## Client Tools

The `mysql` (or `mariadb`) and `mysqldump` (or `mariadb-dump`) programs AirSQL runs. Leave them empty to let AirSQL
find them: it looks in Homebrew's folders, `/usr/local/mysql/bin`, MAMP and your `PATH`, and picks for each server the
tools of its family and version. Under each field the pane says which program and version it found, or why there is
none or it can't be used; **Found** lists every tool on this Mac, and **Find Again** looks again after you install or
update some. See [Export, restore, copy and import](client-tools.md).

## Liquibase

Who changesets are by, how their ids are made, whether a changelog is one file or a folder, how procedures, functions,
triggers and events are kept whole, DEFINER, and `--rollback`. See [Liquibase changelogs](liquibase.md#settings).
