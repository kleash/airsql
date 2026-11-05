---
title: Getting started
nav_order: 3
---

# Getting started

## Add your first connection

Choose **File ▸ New Connection…** (⌘N), or **New Connection…** on the first screen: the connection appears in the
sidebar, and its summary shows where it goes and how it logs in.

Passwords stay in your Keychain. A connection coloured **Production** starts with stricter safety checks
([Settings](settings.md#safety)).

## No server yet?

To try AirSQL with nothing installed but [Docker](https://www.docker.com/products/docker-desktop/), start a throwaway
MariaDB on this Mac:

```sh
docker run --name try-mariadb -e MARIADB_ROOT_PASSWORD=try-it -p 127.0.0.1:3306:3306 -d mariadb:11
```

Add a connection to host `127.0.0.1`, user `root`, password `try-it`, then open
[demo-shop.sql](https://github.com/kleash/airsql/blob/main/scripts/demo-shop.sql) with **File ▸ Open…** and press **Run
All** (⇧⌘↩): it fills a small shop to look around in. `docker rm -f try-mariadb` removes it all.

## Run a query

Double-click the connection to connect, then choose **File ▸ New Query** (⌘T). Pick a database in the toolbar, type a
statement, and press ⌘↩: the results show under the editor. See [Query tabs](console.md).

## Edit rows

Click a table in the sidebar to see its rows, and double-click a cell to change it. Your edits wait, marked in the grid,
until you press **Apply** (⌘S), which shows the SQL first; **Revert** takes them back. See [Table data](table-data.md).

## The window

- **The sidebar** lists your connections. Click one to see its summary (once connected, its [host page](navigator.md#the-host-page)), double-click it to connect, right-click it for
  everything else (Duplicate, Colour, Delete…). Hold ⌘ or ⇧ to select several.
- **The tabs** hold your queries and tables. When more are open than fit, the arrow at the end of the strip lists them all. Double-click a tab to rename it; middle-click it to close it; right-click it
  to close the others or all of them, or to duplicate it. ⌘W closes the tab shown, or the window when it has no tab, as
  it does in Settings, the SQL log and Compare. ⇧⌘T brings back the tab you closed last. ⌘P (**Quick Open…**) goes to a
  table, view or connection by part of its name.
- **The toolbar** (right-click it for **Icon and Text**, or **View ▸ Customize Toolbar…**) shows the connection and database a tab works on (choose another in either pop-up), Run (⌘↩), Run
  All (⇧⌘↩), Explain, the transaction mode and isolation level, Commit, Roll Back and Cancel. A button that can't act
  now is dimmed, and its tooltip says why.
- **The status bar** shows the route to the server, its version, an open transaction, the work running now (click it to
  cancel), what agents are doing, and the SQL log. Click an item for details; right-click it to copy it. When the
  window is narrow, the server's version, the route and then the agents' item make room first; an open transaction's
  warning keeps all its text, and a grid's row count stays.

## Tips

- Nothing is written to a database until you press Run or Apply.
- ⌘1 to ⌘9 show your tabs; ⇧⌘[ and ⇧⌘] step through them.
- **Help ▸ Report a Problem** opens a form with your versions filled in.
