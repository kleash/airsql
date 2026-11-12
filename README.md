<p align="center">
  <img src="https://raw.githubusercontent.com/kleash/airsql/main/docs/assets/screenshots/mongo-sql-light.png" width="49%" alt="A SQL SELECT with a JOIN and GROUP BY, translated to a MongoDB pipeline and run on a shop's orders">
  <img src="https://raw.githubusercontent.com/kleash/airsql/main/docs/assets/screenshots/mongo-stages-dark.png" width="49%" alt="The same query as stage cards: a filter, a join and a group, in dark mode">
</p>

<h1 align="center"><img src="https://raw.githubusercontent.com/kleash/airsql/main/docs/assets/icon.png" width="40" alt=""> AirSQL</h1>

<p align="center"><b>One native Mac app for MySQL, MariaDB and MongoDB.<br>
Write SQL against MongoDB. Join and group without learning <code>$lookup</code>. Let AI agents read your data, never
write it behind your back.<br>Free and open source.</b></p>

<p align="center">
  <a href="https://github.com/kleash/airsql/actions/workflows/ci.yml?query=branch%3Amain"><img src="https://github.com/kleash/airsql/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://github.com/kleash/airsql/actions/workflows/codeql.yml?query=branch%3Amain"><img src="https://github.com/kleash/airsql/actions/workflows/codeql.yml/badge.svg?branch=main" alt="CodeQL"></a>
  <a href="https://github.com/kleash/airsql/actions/workflows/security.yml?query=branch%3Amain"><img src="https://github.com/kleash/airsql/actions/workflows/security.yml/badge.svg?branch=main" alt="Security"></a>
  <a href="https://scorecard.dev/viewer/?uri=github.com/kleash/airsql"><img src="https://api.scorecard.dev/projects/github.com/kleash/airsql/badge" alt="OpenSSF Scorecard"></a>
  <a href="https://github.com/kleash/airsql/blob/main/LICENSE"><img src="https://img.shields.io/github/license/kleash/airsql" alt="Licence"></a>
  <a href="https://github.com/kleash/airsql/releases/latest"><img src="https://img.shields.io/github/v/release/kleash/airsql" alt="Latest release"></a>
</p>

```sh
brew install --cask kleash/tap/airsql
```

## Why people switch

<table>
  <tr>
    <td width="50%"><img src="https://raw.githubusercontent.com/kleash/airsql/main/docs/assets/screenshots/mongo-sql-light.png" alt="A SELECT with JOIN, WHERE, GROUP BY and ORDER BY beside the MongoDB pipeline it became"><br><b>SQL on MongoDB.</b> Type <code>SELECT … JOIN … GROUP BY</code>; get the pipeline, its results, and notes where MongoDB differs from SQL.</td>
    <td width="50%"><img src="https://raw.githubusercontent.com/kleash/airsql/main/docs/assets/screenshots/mongo-builder-light.png" alt="The query builder: name contains, country is one of, a date range, sorted, with the find it wrote"><br><b>Filters without the syntax.</b> Field, operator, value: contains, is one of, between, date ranges. It writes the <code>find</code> for you, and shows it.</td>
  </tr>
  <tr>
    <td width="50%"><img src="https://raw.githubusercontent.com/kleash/airsql/main/docs/assets/screenshots/mongo-stages-group-light.png" alt="Pipeline stages as cards: an unwind and a group by country with a sum and a count"><br><b>Joins and group-bys as cards.</b> Filter, Join, Group, Sort: each stage a form, with a count per stage and warnings when a join can't match.</td>
    <td width="50%"><img src="https://raw.githubusercontent.com/kleash/airsql/main/docs/assets/screenshots/agents-light.png" alt="Settings ▸ Agents: each connection's access, and adding AirSQL to Claude Code or Gemini CLI"><br><b>AI agents, on a leash.</b> Claude Code, Gemini CLI or Claude Desktop over MCP: read-only checks, changes wait for your OK, never your passwords.</td>
  </tr>
  <tr>
    <td width="50%"><img src="https://raw.githubusercontent.com/kleash/airsql/main/docs/assets/screenshots/console-light.png" alt="The SQL console with a query's results"><br><b>A SQL editor that reads your SQL.</b> Completion that knows aliases and joins, checks as you type, rename, a formatter, a session per tab.</td>
    <td width="50%"><img src="https://raw.githubusercontent.com/kleash/airsql/main/docs/assets/screenshots/edit-light.png" alt="Two edited cells in the grid and the sheet with the UPDATE statements Apply would run"><br><b>Edits you can trust.</b> Nothing is written until Apply; you see every statement first, and Apply checks it touched exactly those rows.</td>
  </tr>
  <tr>
    <td width="50%"><img src="https://raw.githubusercontent.com/kleash/airsql/main/docs/assets/screenshots/connection-light.png" alt="The connection editor's SSH and Proxy tab: a jump host, then an SSH host"><br><b>Every way in.</b> SSH, jump hosts, HTTP and SOCKS proxies, your <code>~/.ssh/config</code>, replica sets and <code>mongodb+srv</code>; TLS checked against the real name.</td>
    <td width="50%"><img src="https://raw.githubusercontent.com/kleash/airsql/main/docs/assets/screenshots/compare-light.png" alt="The compare window: tables that differ, a table's changed rows and the sync script"><br><b>Compare and sync.</b> Two servers, databases or tables, structure and rows, with a script you review before it runs.</td>
  </tr>
</table>

Also: EXPLAIN as a tree and a flame graph, a fast grid with charts and heatmaps, users and roles, Disk Usage, the table
editor and ER diagrams, Liquibase changesets, dump and restore, Watch Changes on a replica set, and import from Sequel
Ace, TablePlus, DBeaver, Workbench and HeidiSQL. Native AppKit, light and dark, a shortcut for everything, Apple silicon
and Intel, macOS 13.1+, no account. Every picture is also in dark mode in
[docs/assets/screenshots](docs/assets/screenshots); [AirSQL Help](https://kleash.github.io/airsql/) has the rest.

## Install

`brew install --cask kleash/tap/airsql`, or the zip from [Releases](https://github.com/kleash/airsql/releases).
Signed with a Developer ID and notarized by Apple; every release has its SHA-256, an SBOM and signed build provenance
([check a download](SECURITY.md#check-a-download)).

## Security in brief

Passwords stay in your Keychain, never in files, logs or what agents see. TLS is verified against the server's real
name. Tunnels end in private Unix sockets, never network ports. Nothing is written without Run or Apply, and a lost
connection is never reconnected behind your back. Report a vulnerability privately: [SECURITY.md](SECURITY.md).

## Build from source

```sh
./build.sh --native   # build/AirSQL.app for this Mac; the Command Line Tools are enough, no Xcode
./test.sh             # the tests (Swift 6)
```

[Contributing](CONTRIBUTING.md) · [Report a problem](https://github.com/kleash/airsql/issues/new) ·
[Code of conduct](CODE_OF_CONDUCT.md) · For agents: [llms.txt](docs/llms.txt), [AGENTS.md](AGENTS.md) · Apache 2.0
([LICENSE](LICENSE), [NOTICE](NOTICE))
