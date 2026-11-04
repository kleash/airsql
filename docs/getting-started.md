---
title: Getting started
nav_order: 3
---

# Getting started

## Add your first connection

Choose **File ▸ New Connection…** (⌘N), or **Add Connection…** on the first screen: the connection appears in the
sidebar, and its summary shows where it goes and how it logs in.

Passwords stay in your Keychain. A connection coloured **Production** starts with stricter safety checks
([Settings](settings.md#safety)).

## The window

- **The sidebar** lists your connections. Click one to see its summary, double-click it to connect, right-click it for
  everything else (Duplicate, Colour, Delete…). Hold ⌘ or ⇧ to select several.
- **The tabs** hold your queries and tables. Double-click a tab to rename it; middle-click it to close it; right-click it
  to close the others or all of them, or to duplicate it. ⌘W closes the tab shown, or the window when it has no tab, as
  it does in Settings, the SQL log and Compare. ⇧⌘T brings back the tab you closed last. ⌘P (**Quick Open…**) goes to a
  table, view or connection by part of its name.
- **The toolbar** shows the connection and database a tab works on (choose another in either pop-up), Run (⌘↩), Run
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
