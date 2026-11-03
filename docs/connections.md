---
title: Connections and routes
nav_order: 10
---

# Connections and routes

A connection is a MySQL or MariaDB server AirSQL remembers: its address, the login, how to reach it (its route) and
a few options. Passwords go in your Keychain, never in AirSQL's files.

## Add or edit a connection

Choose **File ▸ New Connection…** (⌘N), or select a connection and choose **Connection ▸ Edit…**. The editor has five
tabs:

- **General**: a name, the sidebar folder, a colour (Production also turns on the strict safety checks), the host and
  port, or for a server on this Mac its socket file, the user and password, and the database to open. Tick **Ask at
  each connect** to type the user and password each time; they are kept until you disconnect and never saved.
- **TLS**: how the connection is encrypted. **Check the authority and host name** is the safe choice: the server must
  show a certificate for the host name you typed, even through a tunnel. A server whose certificate macOS doesn't know
  shows its fingerprint when you connect (see [Trust a server](trust-a-server.md)). Add an authority file for a
  private certificate authority, and a client certificate and key for a server that asks for one. **PAM or LDAP
  login** allows the plain-text login such accounts need, only over TLS that proves the server.
- **SSH and Proxy**: the route (below).
- **Options**: read-only (writes from the console, the grid and agents are refused), the compressed protocol, a query
  timeout, the databases shown (names or patterns such as `shop, reports_*`), startup SQL that runs after each login
  (for example `SET time_zone = '+00:00';`), the connection's own client tools (empty: Settings ▸ Client Tools'
  choice; each says which program and version it is, or why it can't be used), and safety checks of the connection's
  own.
- **Agents**: what AI agents may do with this connection.

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

## Connect and disconnect

Double-click a connection, or select it and choose **Connection ▸ Connect** (⌘K). The status bar shows each step, hop
by hop, with Cancel. A connection that drops (the network goes away, the server restarts) is marked in the sidebar;
AirSQL never reconnects behind your back. **Connection ▸ Disconnect** (⇧⌘K) asks first when a tab has an open
transaction or edits that aren't applied.

Connected connections are kept alive with a ping every minute, except a session whose transaction has been open longer
than the safety setting allows.

## Folders

Folders group connections in the sidebar. **Connection ▸ New Folder…** makes one (the selected connections move into
it); right-click a folder to rename or delete it (its connections stay). The editor's **Folder** menu moves a
connection.
