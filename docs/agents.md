---
title: AI agents
nav_order: 15
---

# AI agents

Claude Code, Gemini CLI, Claude Desktop and other MCP clients can use AirSQL to read your schemas, run read-only
queries, profile tables and propose SQL for you to run. They work through AirSQL on your Mac, so they see only what you
allow, never your passwords, and can't change data.

## Turn agents on

1. **AirSQL ▸ Settings ▸ Agents**: tick **Allow AI agents to use AirSQL**.
2. Under **Connections**, choose what agents may do with each connection. Every connection starts at **Off**.
3. Add AirSQL to your agent:
   - **Add to Claude Code…** or **Add to Gemini CLI…**: AirSQL shows the exact change to that program's settings
     (`~/.claude.json` or `~/.gemini/settings.json`), and makes it only when you click **Add**, keeping the old file as
     `.airsql-backup`. Restart the program afterwards.
   - Claude Code's plugin: `claude plugin marketplace add kleash/airsql`, then `claude plugin install airsql@airsql`.
   - Claude Desktop: open `airsql.mcpb` from AirSQL's release.
   - Another client: **Copy** gives the command, `/Applications/AirSQL.app/Contents/MacOS/AirSQL --mcp`.

The connection must be connected in AirSQL for an agent to read it.

## Access levels

| Level | Agents may |
|---|---|
| Off | not see the connection at all |
| Schema | read databases, tables, columns, keys and indexes; put SQL into a console tab |
| Schema + read | also run read-only queries and see query plans, within the row cap and time limit of Settings ▸ Safety |
| Schema + read + analytics | also profile tables, get ten times the rows and four times the time, and save results to files |

**Sample rows** (a separate switch) lets agents see a few rows of each table they describe. Only you can change these:
no agent can, whatever it asks.

## What keeps your data safe

- An agent's statement runs only if AirSQL can prove it reads and nothing more: one SELECT, SHOW, DESCRIBE or
  EXPLAIN, without locking clauses, `INTO`, hints or functions such as `SLEEP` ([what passes](read-only-queries.md)).
- It then runs on a session of its own that the server keeps read-only, inside a read-only transaction that is rolled
  back, with a time limit. Even a statement that slipped past the check can't write.
- To change something, an agent puts the SQL into a console tab. Nothing runs until you press Run.
- For more safety still, connect with a database user that can only read.

## Agents in AirSQL's windows

Agents can also work in AirSQL's windows as you do: open tabs, choose menu commands, fill in sheets, take screenshots.
Whatever that would change waits for you:

- Anything that would run on a server (Run in a console, Apply, a compare's sync, Restore, Copy, CSV import, Commit)
  first shows the SQL preview sheet, marked **Asked by** and the agent's name. Only you can press its Run; the agent
  can only decline. Statements that AirSQL proves only read run without asking.
- Agents can't change Settings, agent access, a connection's colour, read-only switch, server, route, login, TLS,
  startup SQL or safety settings, nor save files, start an export, save a password, trust a certificate, paste from
  your clipboard, quit AirSQL or press a button marked destructive (Don't Save, Disconnect with a transaction open).
  Text an agent types into a console of a Production connection is shown to you first.
- On connections whose agent access doesn't include reading, grids and results are hidden from the agent's snapshots
  and screenshots.

**Settings ▸ Safety ▸ Ask before agents change anything** (on by default, per connection in its Options tab) turns the
asking off; what is yours alone stays yours.

## See what agents did

The agents' item in the status bar says what they're doing. Click it (or choose **Tools ▸ Agents ▸ Agent Activity**)
for every call since AirSQL opened, with how it ended. A call that reads a database also shows in Activity, where
**Cancel** stops it. **Turn Agents Off** in that popover (or in Tools ▸ Agents) stops them at once.

## Files agents save

With analytics, agents can save query results as CSV or JSON files. They go only to the **Agent Exports** folder in
AirSQL's settings folder (Settings ▸ Agents ▸ Exports ▸ Show in Finder), readable by you alone.

## The fine print

Agents reach AirSQL through a socket in AirSQL's settings folder that only you can open, with a key that changes each
time AirSQL starts. Other programs running as you could read that key too, as with any app of yours.
