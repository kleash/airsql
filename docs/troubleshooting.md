---
title: Troubleshooting
nav_order: 92
---

# Troubleshooting

AirSQL says what went wrong in plain words, with the server's own error under **Details**. Here is what to do about
the common problems.

## A connection fails

| AirSQL says | What to do |
|---|---|
| Can't find the server | Check the host name, and that you are on the right network or VPN. |
| The server refused the connection | Check the port, and that the database server is running. |
| The server didn't answer in time | Check the host name and the port: a firewall may be dropping the connection. |
| The server can't be reached from this network | Turn on the VPN, or connect through an SSH host that can reach the server. |
| The server didn't accept the user name or password | Check both. Through an SSH host, the server sees the SSH host's address, and the account must allow that host. |
| This user may not log in from this computer's address | An administrator can allow it (the account's host part). |
| The server only accepts encrypted connections | Turn on TLS for the connection. |
| The server asked for a login method AirSQL doesn't allow on this connection | A PAM or LDAP account: turn on its plain-text login for the connection, with TLS that proves the server. |
| The server blocked this computer after too many failed connections | An administrator can unblock it (`FLUSH HOSTS`). |

## AirSQL asks about the server's certificate

See [Trust a server](trust-a-server.md). If AirSQL warns that a certificate has changed and nobody told you it would,
choose **Cancel** and ask the server's administrator.

## "The connection to the server was lost"

AirSQL doesn't reconnect by itself, because a quiet reconnect would lose an open transaction without telling you.
Reconnect when you are ready. Changes you hadn't committed were rolled back by the server.

## macOS asks about the local network

To reach a server on your local network, choose **Allow** when macOS asks whether AirSQL may find and connect to
devices on it. If you chose **Don't Allow**: System Settings ▸ Privacy & Security ▸ Local Network, then turn on AirSQL.

## AirSQL doesn't open

It needs macOS 13.1 or later. Downloads from the releases page and Homebrew are notarized and open normally.

## Report a problem

**Help ▸ Report a Problem** opens a form on GitHub with your AirSQL and macOS versions filled in. **Help ▸ Copy
Diagnostics** copies those versions and the client library's (no names, hosts or paths). The [SQL log](sql-log.md)
shows exactly what AirSQL sent: read it before you share any of it, because it holds your queries.
