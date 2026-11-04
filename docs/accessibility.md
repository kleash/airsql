---
title: Accessibility
nav_order: 89
---

# Accessibility

AirSQL is built from the Mac's own controls wherever it can be, and labels the ones it draws itself for VoiceOver.

## VoiceOver

- The data grid reads as a table: its column names and types, cell values, sort order and row counts, and which rows
  are changed, added or marked for deletion.
- A connection says its state and its marks (Production, read-only) in words, not only by its colour.
- AirSQL announces what happens away from the focus: a statement's error or note, a Test Connection result, and the end
  of a Find Text search.
- In the ER diagram each table reads with its columns; pressing it opens its structure.

## Keyboard

Every command is in the menu bar, and **Help ▸ Keyboard Shortcuts** lists them all. ⌥⌘1, ⌥⌘2 and ⌥⌘3 go to the sidebar,
the editor and the results; ⌃⇥ moves between tabs. To show, hide and find columns in a grid without the mouse, use
**View ▸ Column List**.

## Motion and text size

Sidebar and tree animations stop under **Reduce Motion**. ⌘+ and ⌘− change the text size of the SQL editor and the grid
in focus; the rest of the window stays at its size.
