---
title: MongoDB collections
nav_order: 21
---

# MongoDB collections

Once a MongoDB connection is connected (see [Connections and routes](connections.md)), the sidebar shows its databases
under it. Open a database with its arrow or a double-click: AirSQL reads its collections and its size on disk (with its
indexes) then, never every collection's figures at once. Collections show **C**, views **V** and time-series
collections **TS**; views and time-series say *read-only*. A collection's arrow shows its indexes, with their keys.
MongoDB's own databases (admin, config, local) come last, in a quieter colour, and the server's `system.` collections
(`system.views`, `system.profile`, a time-series collection's buckets…) aren't listed, as in Compass.

A click on a collection shows its documents in the preview tab; a double-click, Return or **Open Collection** (⌥⇧⌘O)
opens them in a tab of their own. Right-click a row to open it, sample its schema, copy its name or read it again
(**Refresh**, ⌘R).

SQL's commands are for MySQL and MariaDB: on a MongoDB tab or connection they're off and say *Not for MongoDB*, in the
menus and in the toolbar (the database, the transaction mode, Run All, Explain, Commit and Roll Back). The toolbar's
**Run** and **Cancel** work on the collection tab. The log at the right of the status bar is the **Command Log** there:
the same file as [the SQL log](sql-log.md), with every command AirSQL sends to MongoDB in shell form, passwords masked.

## Connect to MongoDB

Choose **File ▸ New Connection…** and set **Server** to MongoDB, or choose **File ▸ New Connection from URL…** with a
`mongodb://` or `mongodb+srv://` address. In the editor's General tab, **Paste Address** fills the fields from the
address on the clipboard and says what it understood; a password in it goes to your Keychain when you save, never
into AirSQL's files. **Copy Address** copies the connection's address with its user but never its password, for
mongosh or Compass.

- **Host** and **Port**: the first server. **Other members**: the replica set's others, as `host:port` separated by
  commas (optional: the driver finds them from any one).
- **DNS seed list (mongodb+srv)**: for Atlas and other `mongodb+srv://` addresses: one host name without a port, and
  DNS lists the servers. TLS turns on with it.
- **Replica set**: its name, such as `rs0`. **Direct connection**: only the server named, never the other members
  (for one secondary on its own).
- **Auth source**: the database the user is defined in; empty, the database above, else `admin`.
- **Options**: the address's other options as they follow its `?`, such as `readPreference=secondary&w=majority`,
  `appName` or `retryWrites`.

A new connection starts with TLS checking the certificate and host name, except for a server on this Mac. A pasted
`mongodb://` address without `tls=true` turns TLS off, and the editor says the connection isn't encrypted. The TLS tab's
CA certificate is how a private authority (such as a replica set's own) is trusted. Every route works, as for MySQL.

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
*missing*), which differs from `null`, shown as mongosh writes it (Settings ▸ Grid's NULL text is for MySQL).
Right-click the header of a sub-document's column for **Expand Field**: its fields become columns of their own; on one
of them, **Collapse Field** makes them one column again.

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

## Indexes

**Indexes** (⌃⌥7) lists the collection's indexes: each one's name, keys, options (unique, sparse, TTL, partial filter,
collation, hidden, and text, 2dsphere, hashed or wildcard), its size on disk (`$collStats`) and how often it has been
used (`$indexStats`). Use is counted by each server on its own, from when it last started or the index was made: the
caption names the server that answered, and **Since** says from when. An index still being built says *(building)*.
**Refresh** (⌘R) reads them again.

- **Create Index…** takes the keys in shell form (`{ field: 1, other: -1 }`, `{ body: "text" }`), an optional name
  (else made from the keys, as mongosh does) and options: Unique, Sparse, Hidden, Expire After (seconds, for a TTL
  index), a partial filter and a collation. **Preview…** shows the exact `createIndexes` command; **Create** runs it,
  with **Cancel** (⌘.) while it builds. A unique index over documents that share their keys isn't made, and the message
  names the first duplicate the server found.
- **Drop Index…** shows the `dropIndexes` command, marked as destructive; on a Production connection (or one whose
  Safety settings ask for it) you type the index's name first. The `_id` index can't be dropped.
- **Hide Index…** (or **Unhide Index…**) shows the `collMod` command that hides the index from the query planner, or
  shows it again; a hidden index is still kept up to date, so unhiding it is instant.

In the sidebar, double-click an index to see it on its collection's Indexes page; right-click it to hide or drop it, or
right-click a collection for **Create Index…**. On a read-only connection, a view or a time-series collection these
commands are off, and say why.

## Export and import

**Data ▸ Collection ▸ Export Documents…** writes the documents of the collection selected in the tree, or of the
collection tab in front, to a file. Choose every document, or what the tab's query finds (its filter, projection,
sort, skip and limit), and a format:

- **Extended JSON, relaxed** or **canonical**: one document per line (JSON Lines, as mongoexport writes) or one JSON
  array. Canonical keeps every type exactly, so a 64-bit integer of 1 comes back a 64-bit integer.
- **CSV**: a column per field path (a sub-document's fields are columns of their own), filled in from the first 1,000
  documents and yours to change; other values in shell form (`ObjectId("…")`) or as relaxed Extended JSON.

The sheet shows the first lines as they'll be written. The documents are read and written in batches, so a large
collection takes little memory; the status bar shows how far it is, with Cancel. The file appears only once every
document is written: a cancelled or failed export leaves the file that was there.

**Import Documents…** inserts the documents of an Extended JSON file (JSON Lines, documents one after another, or one
array) into a collection: an existing one, or a new name, which the first insert makes. The sheet shows the first
documents, about how many the file holds and what Import will write; nothing is written before **Import**. A
document without an `_id` gets a new ObjectId; nothing is replaced or deleted. Choose what an error does:

- **Stop at the first error**: a document that can't be read, or that the server refuses (such as a duplicate `_id`),
  ends the import; the documents before it stay.
- **Skip lines that can't be read and refused documents**: each line must hold one whole document; the rest go in.

When it ends, a summary says how many documents went in, how many the server refused (duplicate `_id`s counted) and
how many lines were skipped, with the first problems and their line or document numbers. Cancel stops it between
batches, and the summary says how many went in. Views and time-series collections are read-only here, and a read-only
connection imports nothing.

## Aggregation

**New Aggregation** (⌥⌘A, in a collection's right-click menu and Data ▸ Collection) opens a tab with a pipeline editor
over the documents it gives. Type the stages in shell form, as an array or one after another:
`[{ $match: { status: "paid" } }, { $group: { _id: "$customer", total: { $sum: "$amount" } } }]`. Each stage of
several lines folds on its own; typing `$` at a stage's start offers the stage names, and inside a stage the field
names of the documents loaded (with `$` before them, as an expression names a field). A mistake is underlined where it
is, and Run says which stage, line and column.

**Run** (⌘↩) runs the pipeline; its documents load a batch at a time, with **Load More** (⌥⌘↓), and show in the same
grid as a collection's. **Collation** and **Max Time** above the editor apply to the whole pipeline. **Cancel** (⌘.)
stops it on the server: the tab has a session of its own, so it stops only this tab's work, and closing the tab closes
the session.

**Explain** (⌥⌘E) runs the pipeline with `executionStats` and shows how the server ran it: what makes it slow first
(a scan of the whole collection, a sort in memory, many more documents read than returned), then its steps with the
documents each returned and its time, as a diagram, a flame graph, indented **Text**, or the server's own answer. Explain
runs the pipeline to measure it, so a slow pipeline is slow here too.

A collection tab's find can be explained the same way: its plan opens in a window of its own.

## Compare and reconcile

Right-click a collection and choose **Compare With…** (also in Data ▸ Collection) to compare it with another
collection: in the same database, another one, or on another connection (a standalone with a replica set, say). The
collection you started from is the **source**; choose the target's connection, database and collection (a connection
that isn't connected connects when you choose it), then **Compare** (⌘R). **Cancel** (⌘.) stops it on the server.
Nothing is written while comparing.

Documents are matched by `_id`, exactly: `1`, `NumberLong(1)` and `1.0` are three different `_id`s. When every `_id` on
both sides is of one type (ObjectId, string, int or long), both collections are read in `_id` order and merged;
otherwise each batch of the source is looked up in the target, then the target's leftovers in the source (the summary
says which). Two documents are the same only when every value has the same type and value and the fields are in the
same order. **Ignore Key Order** counts fields in another order as the same; **Ignore fields** leaves paths out
(`updatedAt, meta.seen`; `items.price` covers every item's price).

The chips filter the list: **Only in Source**, **Only in Target**, **Different** and **Same** (off at first). Select a
document to see both sides, the lines that differ marked, and where they differ above (*(field order)* when only the
order does). **Indexes and Options** lists the two collections' indexes, matched by their keys, and their options (the
validator, its level and action, a collation) side by side. A compare lists at most 10,000 differences; past that it
says so, and the counts still cover every document.

**Reconcile…** makes the target's documents match the source's, through the same Apply as editing: tick what it does,
**Insert Missing** and **Replace Different** (on), and **Delete Extra** (off, marked destructive). The sheet shows every
command first; each target document is read back and must still be exactly as compared, or Reconcile stops there, so a
change made meanwhile is never overwritten. On a replica set it all runs in one transaction; on a standalone the
changes before a failure stay, and the report says how many. A replace writes the source's document whole, ignored
fields included. A read-only connection, a view or a time-series target can't be reconciled; on a Production
connection you type the collection's name first. Indexes and options aren't changed: the compare only shows them.

## Agents

With agent access set to **Schema + read** or more, AI agents can find, aggregate, count and sample a MongoDB
connection's documents, read-only: see [AI agents](agents.md#mongodb-connections). Its editor's Agents tab recommends
connecting with a login that can only read (the `read` role), so the server itself refuses any write.
