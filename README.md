<h1 align="center"><img src="https://raw.githubusercontent.com/kleash/airsql/main/docs/assets/icon.png" width="40" alt=""> AirSQL</h1>

<p align="center"><b>A native Mac app for MySQL and MariaDB: every way to connect, a fast data grid with safe editing, and
AI agents that never change anything without you. Free and open source.</b></p>

<p align="center">
  <a href="https://github.com/kleash/airsql/actions/workflows/ci.yml?query=branch%3Amain"><img src="https://github.com/kleash/airsql/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://github.com/kleash/airsql/actions/workflows/codeql.yml?query=branch%3Amain"><img src="https://github.com/kleash/airsql/actions/workflows/codeql.yml/badge.svg?branch=main" alt="CodeQL"></a>
  <a href="https://github.com/kleash/airsql/actions/workflows/security.yml?query=branch%3Amain"><img src="https://github.com/kleash/airsql/actions/workflows/security.yml/badge.svg?branch=main" alt="Security"></a>
  <a href="https://scorecard.dev/viewer/?uri=github.com/kleash/airsql"><img src="https://api.scorecard.dev/projects/github.com/kleash/airsql/badge" alt="OpenSSF Scorecard"></a>
  <a href="https://github.com/kleash/airsql/blob/main/LICENSE"><img src="https://img.shields.io/github/license/kleash/airsql" alt="Licence"></a>
  <a href="https://github.com/kleash/airsql/releases/latest"><img src="https://img.shields.io/github/v/release/kleash/airsql" alt="Latest release"></a>
</p>

AirSQL is in development and not ready to use yet: the plan is in [docs/dev/plan.md](docs/dev/plan.md), and
[AirSQL Help](docs/index.md) describes each part as it is now.

- **Every way in** ([Connections and routes](docs/connections.md)): direct or a socket, SSH tunnels (password, key,
  ssh-agent, 2FA, your `~/.ssh/config`), jump hosts, HTTP and SOCKS5 proxies, each ending in a private socket on your
  Mac. TLS is checked against the server's real name, also through a tunnel. Folders, colours, read-only connections
  and startup SQL.
- **A fast data grid with safe editing** ([A table's rows](docs/table-data.md), [Read the data in a grid](docs/data-grid.md)):
  filter and sort on the server or in the loaded rows, search every column, quick filters and filter by values; an
  editor for each type (dates, JSON, ENUM and SET, foreign keys with search), paste from a spreadsheet, undo. Nothing
  is written until you Apply, and Apply checks that every change touched exactly the rows it should. Transpose, record
  view, value panel, display formats (UUID, hex, numbers, dates, time zones), heatmaps, charts, column summary and
  frozen columns; compare two results; copy and export as CSV, JSON, SQL, Markdown, HTML, XML or Excel.
- **A SQL console** ([The SQL console](docs/console.md)) with completion, formatting, EXPLAIN as a plan, profiles,
  history, transactions, query helpers, result tabs and a log of every statement AirSQL sends.
- **A server at a glance** ([Browse a server](docs/navigator.md)): the tree and the database view; create, rename,
  empty, copy and drop; a bulk table editor, maintenance, text found in every table, and the process list with Kill.
- **Schema tools** ([Change tables, views and routines](docs/editors.md)): the table editor, with its ALTER shown as you
  type (columns, indexes, foreign keys, checks, options), views and routines as CREATE code, and an ER diagram.
- **Client tools** ([Export, restore, copy and import](docs/client-tools.md)): your own `mysqldump` and `mysql`, with
  passwords kept off the command line, or AirSQL's own export and runner; Terminal over any route; copies to another
  server; CSV import.
- **Compare and reconcile** two databases ([Compare two databases](docs/compare.md)), structure and data, with a sync
  script you review first and a report as HTML, CSV or Markdown; **Liquibase changesets**
  ([Liquibase changelogs](docs/liquibase.md)) of a schema or of any change.
- **AI agents over MCP** ([AI agents](docs/agents.md)), at the level you set for each connection: their queries must
  pass a read-only check, their changes wait for your approval, you see what they ran, and they never see your
  passwords.
- **A Mac app** ([Keyboard shortcuts](docs/shortcuts.md)): native AppKit, light and dark, right-click menus and a
  shortcut for every common command, drag and drop, and no waiting on the network while you work. Apple silicon and
  Intel, macOS 13.1 or later. No account.

## Screenshots

To come, in light and dark, made from neutral demo data:

- The window: connections, the database navigator and a table in the grid
- The SQL console with results and EXPLAIN
- Editing rows, with the SQL shown before Apply
- A connection through an SSH host and a jump host
- Compare and reconcile
- Agent access: Settings ▸ Agents and the agents' activity

## Install

```sh
brew install --cask kleash/tap/airsql
```

Or download the zip from [Releases](https://github.com/kleash/airsql/releases). AirSQL is signed with a Developer ID
and notarized by Apple, so it opens like any app. Every release has the zip's SHA-256, the exact source of the client
library inside and signed build provenance: [check a download](SECURITY.md#check-a-download).

## Build from source

```sh
./build.sh --native   # build/AirSQL.app for this Mac (./build.sh: universal); the first build compiles libmariadb
./test.sh             # the tests (Swift 6)
```

The Command Line Tools are enough (`xcode-select --install`); Xcode isn't needed. More in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Security in brief

- Passwords live in your Keychain, never in files, logs or what agents see.
- TLS is verified against the server's real name; a certificate macOS doesn't know is shown with its fingerprint first.
- Tunnels end in private Unix sockets, never network ports. The server can't make AirSQL read your files
  (`LOAD DATA LOCAL INFILE` is off), and one statement goes at a time.
- Nothing is written without Run or Apply, and a lost connection is never reconnected behind your back.
- Releases are signed with a Developer ID, use the hardened runtime, are notarized, and come with an SBOM.

Report a vulnerability privately: [SECURITY.md](SECURITY.md).

## More

[AirSQL Help](https://kleash.github.io/airsql/) · [Report a problem](https://github.com/kleash/airsql/issues/new) ·
[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Code of conduct](CODE_OF_CONDUCT.md) · For agents:
[llms.txt](docs/llms.txt), [AGENTS.md](AGENTS.md) · Apache 2.0 ([LICENSE](LICENSE), [NOTICE](NOTICE))
