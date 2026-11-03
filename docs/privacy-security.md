---
title: Privacy and security
nav_order: 91
---

# Privacy and security

AirSQL holds the keys to your databases, so it is careful by default: it talks only to the servers you set up, your
passwords stay in your Keychain, and nothing changes on a server until you say so.

## What AirSQL connects to

Only the database servers, SSH hosts and proxies you add. It has no account, no ads and no analytics, and it doesn't
check for updates by itself (Homebrew does: `brew upgrade --cask airsql`). The Help menu opens pages in your browser.

## Your passwords

- They are kept in your Keychain, never in AirSQL's settings file, in its logs, in the [SQL log](sql-log.md) or in
  what AI agents see.
- A PAM or LDAP login sends the password as plain text, so AirSQL uses one only when you turn it on for the connection,
  and only over TLS that proves the server is the right one.

## Your connections

- TLS is checked against the server's real name, also through an SSH tunnel. A certificate macOS doesn't know is shown
  with its fingerprint for you to [trust](trust-a-server.md), and AirSQL warns you if it ever changes.
- Tunnels and proxies end in a private socket on your Mac, never in a network port that other apps or computers could
  use.
- A server can't make AirSQL read files on your Mac (`LOAD DATA LOCAL INFILE` is off), and AirSQL sends one statement
  at a time.
- A lost connection is reported, never quietly reconnected: that would lose an open transaction without a word.

## Your data

- Nothing is written until you choose Run or Apply. Changes show their SQL first
  ([Check SQL before it runs](sql-preview.md)), and Apply checks that each change touched exactly the rows it should.
- A connection coloured **Production** starts with stricter safety checks ([Settings](settings.md#safety)).
- A **read-only** connection runs only what AirSQL can prove reads, on sessions the server keeps read-only
  ([Connections](connections.md#add-or-edit-a-connection)).

## AI agents

Agents can't use AirSQL until you allow them. Then each connection has its own access level, an agent's queries must
pass the [read-only check](read-only-queries.md), and a change it asks for waits for your approval. Agents never see
saved passwords.

## The app itself

AirSQL is signed by its developer, uses macOS's hardened runtime and is notarized by Apple. Its one library, MariaDB
Connector/C with OpenSSL, is built from pinned, checked sources, and every release includes that source and a list of
what is inside (an SBOM). Every change is scanned for known vulnerabilities, leaked secrets and security bugs. More in
[SECURITY.md](https://github.com/kleash/airsql/blob/main/SECURITY.md).

## Check a download

Every release lists the zip's SHA-256. In Terminal, in the folder where the download is:

```sh
shasum -a 256 -c AirSQL-X.Y.Z.zip.sha256
```

Once AirSQL is in Applications, `spctl -a -vvv -t exec /Applications/AirSQL.app` says
`source=Notarized Developer ID`.
