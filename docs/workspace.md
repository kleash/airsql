---
title: Files and your workspace
nav_order: 20
---

# Files and your workspace

## The Files panel

**View ▸ Files** (⌥⌘4, or the folder button at the foot of the sidebar) shows your scripts in the tree's place. Press it
again for the tree.

- **Attach Folder…** adds a folder of scripts. AirSQL only reads it: **Detach Folder** takes it out of the list, and it
  stays on disk.
- A click selects a file, a double-click or Return opens it in a query tab, and a double-click on a folder opens or
  closes it. ⌘ and ⇧ select several.
- Right-click a file or folder and choose **Run On** and a connection: **Run SQL File…** opens with the file chosen, and
  nothing runs until you press its Run. A folder runs its .sql and .sql.gz files by name, its subfolders first, with a
  Run for each file.
- The list follows the disk as AirSQL comes to the front; right-click and choose **Refresh** to read it now.

A file remembers the connection and the database it was last used on, and opens there next time.

## Scratch files

**File ▸ New Scratch File** (⌥⇧⌘N) opens a throwaway .sql file with no name to choose. Scratch files are listed under
Scratches in the Files panel. Closing one saves it without asking, every save goes into its Local History, and **Move to
Trash** in its menu removes it.

## A connection's consoles

**File ▸ Consoles…** (⇧⌘J) lists the query tabs of the connection, to jump to one by typing part of its name, and offers a
new one. **File ▸ Default Console** opens the tab the connection keeps for good: its text is there next time, whatever
you closed.

## Two tabs side by side

**View ▸ Split Right** (⌥⌘\\) shows the next tab beside the one on show, or a new query if it's the only one; press it
again for one tab. Right-click a tab and choose **Show Beside** to pair it with the tab you were looking at.

The side with the focus has an accent line along its top, and the status bar and every command follow it. Showing another
tab puts it on that side. **View ▸ Go to Other Side** (⌃⌘\\) moves the focus across; closing either tab ends the split.
