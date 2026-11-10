---
title: SQL log
nav_order: 7
---

# The SQL log

AirSQL writes every statement it sends to a server into one file on your Mac, just before the statement goes out.
Use it to see exactly what AirSQL did: what a query tab ran, what a table edit applied, what the navigator asked the
server for.

## Where to read it

Click **SQL Log** at the right of the status bar, or choose **View ▸ SQL Log** (⌥⌘L), and while a server is connected the
log shows under the tabs; the same again closes it. It starts closed, so the rows keep their room. Drag its top edge to
give it more. The icons beside it open it in a window of its own, where you can filter it, show the file in Finder and
clear it. With nothing connected, ⌥⌘L opens that window. Select some SQL in it and right-click to open it in a new query
tab.

On a MongoDB connection the link says **Command Log**: the same log, where each command AirSQL sends to MongoDB is
written in shell form.

## Where it is

`~/Library/Logs/AirSQL/SQL.log`. Only you can read it (file mode 0600). At 10 MB it becomes `SQL.1.log`, replacing the
one before, and a new file starts. It stays on your Mac: AirSQL sends it nowhere.

## What a line says

```
2026-11-03 14:03:12.345 [Shop production query:12] SELECT * FROM orders WHERE id = 7
```

- the time;
- the connection's name;
- the session: **query** (a query tab's own session), **main** (the connection's first session, which query tabs share
  when the connection says so or the server has few connections left), **data** (table tabs and their edits), **schema**
  (the navigator), **agent** (AI agents), **tools** (client tools and compare), **cancel** (the short connection that
  stops a running statement);
- the statement's number in that session. The server sees the same number in a comment at the start of the statement,
  `/* airsql:query:12 */`, so you can find it in the server's process list.

Lines that start with `--` are AirSQL's own notes: connected (server version, thread, TLS), disconnected, connection
lost, reconnected (and whether an open transaction was rolled back), the number of a statement's error, and
"startup SQL (2 statements)".

## What is never in it

- **Passwords you log in with**: they go to the server only during the login, never as SQL.
- **Passwords and keys inside statements**: replaced with `<secret>`, as MySQL hides them in its own logs: the value
  after `IDENTIFIED BY`, `SET PASSWORD … =`, `MASTER_PASSWORD` or `SOURCE_PASSWORD`, `PASSWORD '…'` in `CREATE SERVER`,
  everything inside `PASSWORD(…)`, and the key of `AES_ENCRYPT`, `AES_DECRYPT`, `DES_ENCRYPT`, `DES_DECRYPT`, `ENCODE`,
  `DECODE` and `ENCRYPT`. A value set for a column named like `password` is hidden too.
- **A connection's startup SQL**: only how many statements it had, since it may hold secrets.
- **Error messages**: only their numbers, because a syntax error quotes the statement it failed on.
- **Results**: rows never go into the log.

Very long statements (an import's big `INSERT`) are cut after 60,000 bytes.

⌘F opens a find bar over the log while its text has the focus.
