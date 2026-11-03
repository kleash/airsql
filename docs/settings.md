# Settings

Open **AirSQL ▸ Settings…** (⌘,). Changes are saved as you make them.

## General

- **Appearance**: follow the Mac's light or dark mode (System), or always use Porcelain (light) or Deep Water (dark).
- **Settings folder**: where your connections and settings are kept. Passwords are in your Keychain, never there.

## Editor and Grid

- The text size of the SQL editor and of the grid.
- **Rows per page**: how many rows a table or result loads at a time (1,000 by default).
- **NULL shown as**: how empty values look in the grid.

## Connections

- **Load details up to … tables**: on a server with more tables than this, a database's columns, indexes and keys load
  when you open it, so connecting stays quick.

## Safety

What asks first before data changes. These are the defaults; a connection can have its own, and a connection
coloured Production starts with a strict preset.

| Setting | Default | Production |
|---|---|---|
| Ask before UPDATE or DELETE without WHERE | on | on |
| Ask before any write from the console | off | on |
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
  or Schema + read + analytics; and **Sample rows**, which lets them see a few rows of each table.
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
