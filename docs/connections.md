---
title: Connections and routes
nav_order: 10
---

# Connections and routes

A connection is a MySQL or MariaDB server AirSQL remembers: its address, the login, how to reach it (its route) and
a few options. Passwords go in your Keychain, never in AirSQL's files.

## Add or edit a connection

Choose **File ▸ New Connection…** (⌘N), or select a connection and choose **Connection ▸ Edit…**. The editor has six
tabs:

- **General**: a name, the sidebar folder, a colour (Production also turns on the strict safety checks), the host and
  port, or for a server on this Mac its socket file, the user and password, the database to open, and a comment (what
  it is for, who to ask). Tick **Ask at each connect** to type the user and password each time; they are kept until
  you disconnect and never saved.
- **TLS**: how the connection is encrypted. A new connection to `127.0.0.1` or `localhost` starts with TLS off, as such
  servers rarely offer it and nothing leaves this Mac; any other host, or any route, starts with the strict check. **Encrypt, check certificate and host name** is the safe choice: the server must
  show a certificate for the host name you typed, even through a tunnel. A server whose certificate macOS doesn't know
  shows its fingerprint when you connect (see [Trust a server](trust-a-server.md)). Add a CA certificate for a
  private certificate authority, and a client certificate and key for a server that asks for one. **PAM or LDAP
  login** allows the plain-text login such accounts need, only over TLS that proves the server.
- **SSH and Proxy**: the route (below).
- **Options**: read-only (below), the compressed protocol, a query timeout, how query tabs use sessions and start their transactions (see [Sessions](console.md#sessions)), the databases shown (names or patterns
  such as `shop, reports_*`), startup SQL that runs after each login (for example `SET time_zone = '+00:00';`), and the
  connection's own client tools (empty: Settings ▸ Client Tools' choice; each says which program and version it is, or
  why it can't be used).
- **Safety**: safety checks of the connection's own: every switch and limit of [Settings ▸ Safety](settings.md#safety),
  starting from the ones that applied, with a slider mark beside its name in the sidebar.
- **Agents**: what AI agents may do with this connection.

A **read-only** connection's sessions are read-only on the server, and AirSQL itself runs on it only statements it can
prove only read: SELECT, WITH … SELECT, SHOW, DESCRIBE and EXPLAIN (as [read-only queries](read-only-queries.md)
decide), and USE. Anything else is refused before it is sent, with the reason, from the query tab, the navigator, a
compare's sync script, Restore, Run SQL File and Import, so not even `SET SESSION TRANSACTION READ WRITE` can lift
it. A table tab's WHERE filter goes through the same check, within the whole SELECT it runs in, so a condition can't
call a function such as `SLEEP` or `GET_LOCK` there. Open in Terminal starts `mysql` with a read-only session. The
grid and the editors don't apply changes to it, and agents can't write to it either. The process list's Kill Query
and Kill Connection still work: they stop a statement or a connection and change no data.

**Test Connection** connects with what the editor shows, reports each hop with its time, and disconnects. **Save and
Connect** saves and connects; **Save** only saves.

## Routes

Every route but Direct ends in a private socket on this Mac, in a folder only you can open. AirSQL, the client tools
and Terminal all connect through it, so the route works the same for each.

| Route | What it does |
|---|---|
| Direct | TCP to the host and port, or the server's own socket on this Mac. |
| SSH tunnel | ssh to the SSH host, which connects to the database host. |
| SSH through jump hosts | ssh through each jump host in order, then the SSH host. |
| SSH through a proxy | The first SSH host is reached through an HTTP CONNECT or SOCKS5 proxy (jump hosts optional). |
| Proxy, no SSH | The proxy connects to the database host itself. |

The database host is the name as the last SSH host or the proxy reaches it: often `127.0.0.1` or a private address.

SSH hosts log in with your ssh-agent and keys in `~/.ssh`, a key file, or a password. Whatever the server asks for
besides (a key's passphrase, a password, a code from your phone) appears as a question when you connect; tick
**Remember in Keychain** to save a password or passphrase once the connection works. The first time you reach an SSH
host, AirSQL shows its key fingerprint to trust; ssh remembers it in `~/.ssh/known_hosts`.

Your `~/.ssh/config` still applies: type one of its `Host` names as an SSH host and its settings (user, port, key,
its own proxy) are used, after what the editor sets.

## Import hosts from ~/.ssh/config

**File ▸ Import from ~/.ssh/config…** asks you to pick the file (it opens on `~/.ssh/config`), lists its hosts, and
makes a connection for each one you tick: an SSH tunnel through that host to a database on `127.0.0.1:3306`, which
you can then edit.

## Import and export connections

- **File ▸ New Connection from URL…** takes a `mysql://user@host:3306/database` address (or `mariadb://`), from the
  clipboard when it holds one, and opens the connection's settings to check before you save.
- **File ▸ Import Connections…** reads the saved connections of Sequel Ace, TablePlus, DBeaver or MySQL Workbench when
  they are on this Mac, or a file you choose: an AirSQL export, one of those apps' files, or HeidiSQL's exported
  settings. It lists the MySQL and MariaDB connections with ticks; one that is already here starts unticked.
- **File ▸ Export Connections…** saves the selected connections, or all of them, to a file for another Mac or a
  colleague.

Passwords never come along: an export has none, an import doesn't read them, and a password in a URL is left out.
AirSQL asks for each when you connect. An imported AirSQL file also leaves out what would run by itself: the client
programs chosen, startup SQL and agent access. TLS starts strict, except for a server on this Mac.

## Connect and disconnect

Double-click a connection (once it is connected, a double-click opens or closes its tree), or select it and choose
**Connection ▸ Connect** (⌘K). The status bar shows each step, hop
by hop, with Cancel. A connection that drops (the network goes away, the server restarts) is marked in the sidebar;
AirSQL never reconnects behind your back. **Connection ▸ Disconnect** (⇧⌘K) asks first when a tab has an open
transaction or edits that aren't applied.

Connected connections are kept alive with a ping every minute, except a session whose transaction has been open longer
than the safety setting allows.

## Folders

Folders group connections in the sidebar. **Connection ▸ New Folder…** makes one (the selected connections move into
it); right-click a folder to rename or delete it (its connections stay; Delete asks too). To move connections, drag them onto
a folder (or onto the list to take them out of one), or use **Connection ▸ Move to Folder**. Right-click the list's empty
space for New Connection and New Folder. F2 on a connection opens it to rename, and the filter's ↓ and Return go on to
the first match.
