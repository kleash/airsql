# Security

AirSQL holds the keys to people's databases, so security reports get priority.

## Report a vulnerability

Please report it privately: **[open a private report](https://github.com/kleash/airsql/security/advisories/new)**
(GitHub ▸ Security ▸ Report a vulnerability). Don't open a public issue for it.

Include what you did, what happened, the AirSQL and macOS versions, and how to reproduce it. You'll get an answer
within a few days. Once a fix is released, the advisory is published with credit to you, unless you'd rather not.

## Supported versions

The latest release. Fixes ship as a new release (Homebrew: `brew upgrade --cask airsql`).

## Check a download

- The zip: `shasum -a 256 -c AirSQL-X.Y.Z.zip.sha256` (the SHA-256 is in the release notes and the Homebrew cask too),
  and once it is installed, `spctl -a -vvv -t exec /Applications/AirSQL.app` says `source=Notarized Developer ID`.
- The files the release workflow built (the SBOM and the MCP bundle, and the zip when GitHub built it) come with signed
  SLSA build provenance, `AirSQL-X.Y.Z.intoto.jsonl` on the release. This checks that a file came out of this
  repository's release workflow, at the release's tag: `gh attestation verify sbom.spdx.json --repo kleash/airsql`.
- The client library's source on the release (the Connector/C and OpenSSL tarballs) has the SHA-256s that
  `scripts/build-mariadb.sh` pins and the SBOM lists.

## What AirSQL does to stay safe

- Passwords live in the login Keychain, never in AirSQL's settings file, exports, logs, the SQL log or agent replies,
  and never on a command line: client tools read them from a private file that is deleted once they have started.
- TLS is verified against the server's real name, also through SSH tunnels. A certificate macOS doesn't trust is shown
  with its fingerprint for the user to trust, and AirSQL warns if it changes.
- Login methods are restricted: plain-text ones (PAM, LDAP) only when the user turns them on and only over TLS that
  proves the server, and no login plugin is ever loaded from disk.
- `LOAD DATA LOCAL INFILE` is off (and left out of the library), multi-statements are off, and a lost connection is
  reported, never reconnected behind the user's back: a query tab that lost its session runs nothing until the user opens
  a new one. Connecting at launch is opt-in per connection, and never for one coloured Production.
- A password typed for a server account goes to the server and is kept nowhere else: the SQL preview, Copy SQL and the SQL
  log show `<secret>`.
- Routes (SSH tunnels, jump hosts, proxies) end in Unix sockets in a private folder, never TCP ports.
- SQL is built only with quoting helpers. Nothing is written without Run or Apply, Apply checks the affected rows
  exactly, and destructive steps are opt-in and marked.
- Agent access (MCP) is off until the user allows it. Then each connection has its access level, queries must pass a
  read-only check that refuses when in doubt, and every change waits for the user's approval, behind a gate that fails
  closed.
- Release builds are signed with a Developer ID and use the hardened runtime, whose library validation loads only
  libraries signed by the same team (the bundled libmariadb is), and are notarized by Apple.

More, in plain words: [Privacy and security](https://kleash.github.io/airsql/privacy-security.html).

## How it is scanned

The results are public, and the badges in the README show the latest ones.

- **CodeQL** checks AirSQL's own Swift and C code for security bugs (the `security-extended` queries): on every change
  to `main` and every pull request.
- **Security**, on every change to `main`, every pull request and before every release: the software bill of materials
  (`scripts/sbom.sh`, attached to every release) lists the code AirSQL ships, MariaDB Connector/C and OpenSSL at their
  pinned versions, and OSV-Scanner checks it against the OSV database (osv.dev); gitleaks looks for secrets in every
  commit. A known vulnerability fails the scan until the library is upgraded.
- **OpenSSF Scorecard** rates the project's supply-chain practices. Every GitHub Action is pinned to a commit and every
  downloaded tool to its SHA-256, and each workflow job gets only the permissions it needs.

## In scope

Anything that lets someone other than the user read passwords, reach a database, change data without the user's Run,
Apply or approval, or drive AirSQL: the Keychain use, the routes and their sockets, TLS verification, the client tools'
private files, the SQL quoting and the read-only check, the agent socket and MCP bridge, and the release packages. Bugs
in MariaDB Connector/C, OpenSSL, OpenSSH or the database servers themselves belong to those projects, but tell us too if
AirSQL is affected.
