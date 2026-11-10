---
title: MongoDB collections
nav_order: 21
---

# MongoDB collections

Once a MongoDB connection is connected (see [Connections and routes](connections.md)), the sidebar shows its databases
under it. Open a database with its arrow or a double-click: AirSQL reads its collections and its size on disk (with its
indexes) then, never every collection's figures at once. Collections show **C**, views **V** and time-series
collections **TS**; views and time-series say *read-only*. A collection's arrow shows its indexes, with their keys.

A click on a collection shows its documents in the preview tab; a double-click, Return or **Open Collection** (⌥⇧⌘O)
opens them in a tab of their own. Right-click a row to open it, sample its schema, copy its name or read it again
(**Refresh**, ⌘R).

## The query bar

Each field takes shell form, as mongosh writes it: `{ age: { $gt: 30 } }`, `ObjectId("…")`, `ISODate("…")`,
`NumberLong(…)`, `NumberDecimal("…")`, `/regex/i`.

- **Filter**: which documents; empty finds every document.
- **Project**, **Sort**, **Skip** and **Limit**: which fields, in what order, how many.
- **Collation** (how strings compare, such as `{ locale: "en", strength: 2 }`), **Hint** (an index's name, or its keys)
  and **Max Time** (milliseconds the server may spend before it stops the find).

**Run** (⌘↩, or Return in any field) finds the documents. A field AirSQL can't read says what's wrong and where under
the fields, and nothing runs. Press Esc in a field to complete a field name from the documents loaded and the schema
sample. The clock button (⌘Y) lists the collection's recent queries and its favourites: choose one to run it again,
or keep the query in the bar among the favourites. They're kept per connection on this Mac, beside the SQL history.

A click on a column's header sorts by that field on the server; ⇧-click adds it to the sort.

## Documents

Each document is a row; each field a column, by its dotted path, in the order fields first appear (`_id` first). A
column's header gives its type, or *mixed* and the types it holds. A field a document lacks is blank (its tooltip says
*missing*), which differs from `null`. Right-click the header of a sub-document's column for **Expand Field**: its fields
become columns of their own; on one of them, **Collapse Field** makes them one column again.

Documents load a batch at a time (Settings ▸ Grid's rows per page, and at most 4 MB): the next batch comes as you
scroll to the end, or with **Load More** (⌥⌘↓). The status bar says how many are loaded, of about how many the
collection holds; **Count Exactly** counts the documents the filter finds. **Cancel** (⌘.) stops a slow find on the
server.

Everything in [Read the data in a grid](data-grid.md) works here: the status bar's figures, Record View, Column Summary
(click a value to find the documents that hold it), charts. The value panel (⇧↩) shows a sub-document or an array as a
tree, opened a level at a time. ⌘C copies cells in shell form; **Copy Documents** (⌥⇧⌘C) copies the selected rows'
documents as Extended JSON, one per line.

## Editing documents

Nothing is written until you apply. Double-click a cell, or press Return, to edit a field; Return keeps the new value
as a pending change, Esc cancels. Type in shell form, as the cell shows it: the field **keeps its type**, so `5` typed
over `NumberLong(1)` is `NumberLong(5)`, plain words over a string are that string, an ISO date over a date is that date
and 24 hex digits over an ObjectId are that ObjectId. Text that can't be read as the field's type is refused, with why.
To change a field's type, use **Edit Value…** (Data ▸ Collection, or the cell's menu): its Type pop-up keeps the type or
changes it to the one you choose. Edit Value… and the value panel also take a long value, a whole array or a
sub-document. **Remove Field** removes the selected fields.

**Insert Document** (⌘I) takes a new document in shell form; without an `_id` it gets a new ObjectId. **Duplicate
Document** (⌘D) adds a copy of each selected document with a new ObjectId, and **Delete Documents** (⌘⌫) marks them
for deletion. Pending changes show in the grid's colours (edited, new, to delete) and in the bar over it; **Revert**
(⌥⌘Z) takes back the selected documents' changes, **Revert All** every one, and ⌘Z undoes one change at a time.

Some things stay read-only, and say why when you try: views and time-series collections, `_id` (it is how a document is
found), fields whose names hold `.` or `$`, deprecated types, and fields inside an array (edit the array as one value).
With a **Project** set, nothing is edited: Apply compares whole documents, so clear Project and run the query again.

**Apply** (⌘S) lists the exact commands first. Each document is read back and must still be exactly as you loaded it,
types included; then `updateOne` names its `_id` and the old values, and must match one document (`deleteOne` likewise).
On a replica set or a sharded cluster the changes run in one transaction: all of them or none. A standalone server has
no transactions, and the sheet says so before you run: if a change fails, the ones before it stay applied. When Apply
stops, it says which document and why (someone else changed it, a duplicate `_id`…), and the changes not applied stay
pending, to fix or revert. If the connection fails before the server answers, AirSQL can't tell whether the change was
made: it says so and never sends it again; Refresh (⌘R) shows what the server holds. After Apply, the changed documents
are read back into the grid.

Running another query, closing the tab, disconnecting or quitting with changes not applied asks first.

## JSON and Schema

The switch over the grid shows the same documents another way:

- **JSON** (⌃⌥5): the documents loaded, as relaxed Extended JSON, laid out.
- **Schema** (⌃⌥6): a random sample of 100, 1,000 or 10,000 documents (`$sample`) summed up per field: its types and
  their share, how many documents hold it, how often it is null or missing, its distinct and most common values, and
  its smallest and largest number or date. `[]` stands for an array's elements. Double-click a field to find the
  documents that have it.

**Documents** (⌃⌥4) shows the grid again. Data ▸ Collection has every command of a collection tab.
