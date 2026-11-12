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
- **Log in with**: **Password (SCRAM)**, **X.509 certificate**: the TLS tab's **Certificate** (one PEM file with
  the certificate and its key, as mongosh's `--tlsCertificateKeyFile` takes it) logs in as the user in `$external`
  its subject names; the user is optional and no password is asked; or **AWS IAM** (below).
- **Auth source**: the database the user is defined in; empty, `admin` (with a DNS seed list, what its DNS record says, `admin` on Atlas). **Database** only says which database opens. A pasted address without `authSource` keeps its own meaning: its database goes into Auth source.
- **Options**: the address's other options as they follow its `?`, such as `readPreference=secondary&w=majority`,
  `appName` or `retryWrites`. With a `readPreference`, finds, aggregations, counts and distinct values go to the
  member it chooses, and the status bar names a secondary that answered (it may lag the primary); writes, Apply and
  agents' reads stay on the primary.

A new connection starts with TLS checking the certificate and host name, except for a server on this Mac. A pasted
`mongodb://` address without `tls=true` turns TLS off, and the editor says the connection isn't encrypted. The TLS tab's
CA certificate is how a private authority (such as a replica set's own) is trusted. Every route works, as for MySQL.

A connection that drops (its SSH tunnel ends, or the server stops answering the check AirSQL makes every minute) is
marked in the sidebar with why, as a MySQL one is: its sessions close, nothing is run again, and the tabs keep what
they show and their pending changes. Double-click the connection to connect again, then Apply. Quick Open (⌘P) finds
the databases and the collections the tree has read, and **Select in Tree** (⇧⌘L) shows a collection or pipeline
tab's collection there.

After a relaunch, collection tabs come back with their query bar and page, and pipeline tabs with their pipeline, as
placeholders: nothing connects until you press **Connect and Open**.

### AWS IAM

**Log in with ▸ AWS IAM** logs in with an AWS access key (`MONGODB-AWS`), as MongoDB Atlas offers for IAM users and
roles. **Access key ID** takes the key's ID, **Secret key** its secret, and **Session token** the token of temporary
credentials (from STS), if any: the secret and the token go to your Keychain, never into AirSQL's files, the address or
the logs, and a new secret key saved without a token forgets the old token. AirSQL uses only the key typed here: it
never reads the Mac's AWS settings or asks AWS for credentials (an empty Access key ID is refused), and the login goes
through the connection's route like any other. **Paste Address** understands `authMechanism=MONGODB-AWS` and takes a
session token in `authMechanismProperties` for the Keychain; **Copy Address** gives the access key ID but never the
secret or the token. **Open mongosh in Terminal** is off for these connections: mongosh takes the session token only on
its command line, where other programs on the Mac can read it.

AWS IAM login is tested only as far as the attempt: AirSQL's test servers (MongoDB Community) don't offer it, and say
so in plain words (*The server doesn't offer this login method*). It hasn't been tried against Atlas.

## The query bar

Each field takes shell form, as mongosh writes it: `{ age: { $gt: 30 } }`, `ObjectId("…")`, `ISODate("…")`,
`NumberLong(…)`, `NumberDecimal("…")`, `/regex/i`.

- **Filter**: which documents; empty finds every document.
- **Project**, **Sort**, **Skip** and **Limit**: which fields, in what order, how many.
- **Collation** (how strings compare, such as `{ locale: "en", strength: 2 }`), **Hint** (an index's name, or its keys)
  and **Max Time** (milliseconds the server may spend before it stops the find).

**Run** (⌘↩, or Return in any field) finds the documents. A field AirSQL can't read says what's wrong and where under
the fields, and nothing runs. The fields autofill as you type (see [Autofill](#autofill)). The clock button (⌘Y)
lists the collection's recent queries and its favourites: choose one to run it again, or keep the query in the bar
among the favourites. They're kept per connection on this Mac, beside the SQL history.

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

## Collections, views and databases

Right-click a database or collection in the sidebar, or use **Data ▸ Collection** (for the tree's selection, or the
collection tab in front). Each command asks what it needs, then shows its exact command (`create`, `drop`,
`renameCollection`, `collMod`) before anything runs; **Cancel** in Activity stops it. The sidebar reads the
database again afterwards, and the tab of a collection that was dropped or renamed says so.

- **Create Collection…** takes its name. **More Options** makes it *capped* (a size in bytes and, if you like, a most
  number of documents: the oldest go first), *time-series* (the time field, a meta field and the granularity) or
  *clustered* (stored in `_id` order), and gives it a default collation and validation rules, in shell form.
- **Create Database…** asks the database's name and its first collection's: MongoDB keeps no empty database.
- **Create View…** takes its name, the collection or view it reads and an aggregation pipeline in shell form. A view
  stores nothing: its pipeline runs each time it is read, and it is read-only.
- **Rename Collection…** renames within the database. Ticking *Replace a collection that has this name* drops that
  collection first: the preview marks it and asks you to type the name. Views and time-series collections can't be
  renamed.
- **Validation Rules…** shows the collection's validator (`$jsonSchema` or query operators) in shell form, with its
  level (strict, moderate, off) and action (error, warn). **Check Existing Documents** counts the documents the rules
  as typed would refuse, before you change anything; the preview repeats that count.
- **Drop Collection…** (**Drop View…** for a view) and **Drop Database…** are marked as destructive. A database's
  name is always typed first; a collection's on a Production connection (or one whose Safety settings ask for it).

`admin`, `local` and `config` and `system.*` collections are MongoDB's own: these commands are off there, and say why.
On a read-only connection every one of them is off.

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

A **CSV** file (`.csv`) imports too: its first row names the fields, and a dotted name such as `address.city` makes a
sub-document. Each row is one document, and an empty cell leaves its field out. A column's cells are read **auto** by
default: a cell that is exactly a whole number becomes an int (a long past its range), a number with a fraction or an
exponent a double, `true`, `false` and `null` those values, an ISO date (`2024-05-01T12:00:00Z`) a date, 24 hex digits
an ObjectId, and the shell form the CSV export writes (`NumberLong(5)`, `ISODate("…")`) its type; anything else, `007`
among them, stays a string. Under **Types**, choose a column and the type all its cells are read as (string, int,
long, double, decimal, bool, date or objectId); the preview shows the first documents as they'll be inserted, and a row
whose cell isn't that type, or whose number of cells differs from the header, stops the import or is skipped and
listed, with its row number, as the Errors choice says.

## Update Many and Delete Many

**Data ▸ Collection ▸ Update Many…** changes every document a filter matches, and **Delete Many…** deletes them, on the
collection tab in front. The filter starts as the tab's, and the tab's collation applies. An update is written as
operators (`{ $set: { status: "closed" } }`) or as an aggregation pipeline (`[ { $set: { total: { $add: ["$a", "$b"] } } } ]`);
a replacement document is refused, since it would replace every matching document whole, and upsert is off.

**Preview…** counts the documents the filter matches now, on the tab's own session, and shows the exact `updateMany`
or `deleteMany` command with that count. Type the count to confirm it; to delete every document (an empty filter),
type the collection's name instead. Nothing runs before that. While it runs the status bar shows it with **Cancel**
(⌘.), which ends it on the server: what it had already changed stays. Then AirSQL says how many documents the server
matched and changed, and warns when that isn't the count you confirmed (documents changed in between); the tab reads
its documents again. If the connection fails before the server answers, AirSQL can't tell what happened: it says so,
and never runs the command again; Refresh (⌘R) shows what the server holds. On a read-only connection, a view or a
time-series collection, or with edits not applied, both commands are off and say why.

## Aggregation

**New Aggregation** (⌥⌘A, in a collection's right-click menu and Data ▸ Collection) opens a tab with a pipeline editor
over the documents it gives. Type the stages in shell form, as an array or one after another:
`[{ $match: { status: "paid" } }, { $group: { _id: "$customer", total: { $sum: "$amount" } } }]`. Each stage of
several lines folds on its own, and the editor autofills stages, their keys and the fields (see
[Autofill](#autofill)). A mistake is underlined where it is, and Run says which stage, line and column.

**Run** (⌘↩) runs the pipeline; its documents load a batch at a time, with **Load More** (⌥⌘↓), and show in the same
grid as a collection's. **Collation** and **Max Time** above the editor apply to the whole pipeline. **Cancel** (⌘.)
stops it on the server: the tab has a session of its own, so it stops only this tab's work, and closing the tab closes
the session.

**Explain** (⌥⌘E) runs the pipeline with `executionStats` and shows how the server ran it: what makes it slow first
(a scan of the whole collection, a sort in memory, many more documents read than returned), then its steps with the
documents each returned and its time, as a diagram, a flame graph, indented **Text**, or the server's own answer. Explain
runs the pipeline to measure it, so a slow pipeline is slow here too.

A collection tab's find can be explained the same way: its plan opens in a window of its own.

### Autofill

The query bar's fields, the pipeline editor and the document editor (Insert Document, Edit Value) list what fits where
you type: it opens as you type `$`, `.`, `"` or a word's second letter, and Esc opens it anywhere (⌥⎋ in the document
editor, where Esc cancels). ↑ and ↓ choose, Return inserts, Tab replaces the rest of the word, Esc closes. Nothing is
sent to the server while you type: the list comes from a sample of the collection (200 documents, read when its tab
opens and again on Refresh, kept in memory only), its indexes and validator, and the documents loaded.

- **Fields**: nested paths (`address.city`, `items.sku`), the indexed ones first in a filter and a sort, then those most
  documents have; each says its type and share. Fields already in the document aren't offered again.
- **Operators** by the field's type: `$gt` for a number or date, `$regex` for a string, `$elemMatch` for an array; in a
  filter's top level `$and`, `$or`, `$nor`, `$expr`; in an update `$set`, `$inc` and the rest.
- **Values** by the field's type: `ObjectId("")`, `ISODate("")`, `true` and `false`, `null`, and a string's values when
  it has 20 or fewer; `1` and `-1` in a sort, `1` and `0` in a projection, the index names in Hint.
- **Pipelines**: stage names as templates whose required keys Tab walks; each stage's keys; `from:` the database's
  collections and `foreignField:` that collection's fields once its sample is read; expression operators, and
  accumulators only where they're allowed (`$group`, `$bucket`, `$setWindowFields`); `"$` the fields, `"$$` the
  variables. After `$group`, `$project`, `$addFields`, `$set`, `$unset` or `$replaceRoot`, the fields are those the
  stage gives.
- Stages and operators newer than the server's version are left out.

### Stages, saved pipelines, views and mongosh

**Run to Here** (⌃⌘↩, or the ⏭ button's menu, which lists the stages) runs the pipeline up to the stage the caret is in
and shows that stage's documents; a line over the grid says which stage they come from. **Count Each Stage** runs the
pipeline once per stage with a `$count` after it and shows how many documents each stage gives, in that menu and over
the grid: it runs the pipeline several times, so it is only done when you ask. After a Run whose documents are all
loaded, the last stage's count shows there too.

**Save Pipeline…** (the bookmark button, or Data ▸ Collection) keeps the pipeline under a name for its collection, on
this Mac beside the query history; the same menu opens a saved pipeline, and **Rename Saved Pipeline…** and **Delete
Saved Pipeline…** act on the one open in the tab. **Export Documents…** (the share button) writes what the pipeline gives,
in the same formats as a collection's export, a batch at a time.

**Save as View…** makes a view on the collection that gives what the pipeline gives: name it, then the exact `create`
command shows before it runs. A pipeline that writes (`$out`, `$merge`) can't be a view or be exported, and a read-only
connection makes no view; a pipeline that writes runs only after its own preview, and never on a read-only connection.

**Open mongosh in Terminal** (Connection menu, or a MongoDB connection's right-click menu) opens your own MongoDB Shell
in Terminal on the connection, through its route: AirSQL passes the user only, so mongosh asks for the password in
Terminal, and no password is ever on its command line. Over an SSH or proxy route mongosh reaches one server through a
socket on this Mac (`directConnection`), so with TLS it can't check the server's name in its certificate, only that an
authority it trusts signed it (the connection's CA file is passed); Terminal says so before mongosh starts. AirSQL doesn't
install mongosh: if it finds none (in Homebrew's folders, /usr/local/bin or your PATH), it says where to get it,
MongoDB's download page or `brew install mongosh`.

## Server, operations and disk usage

Click a connected MongoDB connection in the sidebar (or choose **Connection ▸ MongoDB Server**, or right-click the
connection) to see its server page, laid out as a MySQL server's:

- **Server**: what `serverStatus` says: version, host, uptime, storage engine, the replica set and its primary,
  connections, operations per second (inserts, queries, updates, deletes, get mores, commands), memory, WiredTiger's
  cache and network. Rates are worked out between the last two reads.
- **Members**: each member of a replica set with its state, health, how many seconds it is behind the primary, its
  ping and uptime, from `replSetGetStatus`. A standalone has none, and says so.
- **Operations**: what `currentOp` finds running on the primary: its id, kind, namespace, how long it has run, its
  client, its comment (AirSQL tags its own commands) and its plan. It lists this login's own operations, which needs no
  privilege; **All Operations** lists every login's when the login may (the `inprog` privilege, as `clusterMonitor`
  gives), and says why not otherwise. **Kill Operation…** asks first, then ends the selected operations with `killOp`;
  the server's own work (replication, monitoring, background tasks) can't be killed from here, and on a read-only
  connection Kill is off.

The page reads on a session of its own every 5 seconds while it shows, never while it is hidden, and each read has a
time limit, so a slow server or route doesn't pile reads up. A login without `clusterMonitor` sees what it may, and the
page names the role it lacks.

**Disk Usage** (on the server page, in a database's right-click menu, or **Connection ▸ MongoDB Server**) shows where the
space went, as sorted bars: each database (`dbStats`), and with a double-click its collections (`$collStats`), with the
space their documents and indexes take on disk, the free space kept for reuse, their size uncompressed and their
document count. Views take no space and aren't listed. Right-click any of these lists for **Copy List** and **Export
List…**, which copy or save it as CSV.

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

## Users and roles

Choose **Connection ▸ MongoDB Server ▸ Users and Roles** (or right-click the connection) to list the server's users
and custom roles: each one's database (a user's auth source), the roles it holds on each database, and how a user logs
in (SCRAM-SHA-1, SCRAM-SHA-256) or how many privileges a role has. Select one to see the server's description of it
under the list. Passwords are never read: AirSQL never asks for `showCredentials`.

Seeing every database's users takes `viewUser` everywhere (`userAdminAnyDatabase`, `root`). Without it, AirSQL asks
each database in turn and adds your own login, which you may always see; the list says which databases it couldn't
read. Custom roles are read database by database (`rolesInfo`, which needs `viewRole`). A database that holds no
collections isn't listed by the server, so its users and roles show only with `viewUser` everywhere.

- **New User…**: the database it is defined in (admin by default), its name, its password typed twice, and a role to
  start with on a database (empty: the user's own).
- **Change Password…**: the selected user's new password, typed twice.
- **Grant Role…** (or double-click a user): a built-in role (`read`, `readWrite`, `dbOwner`, `readAnyDatabase`,
  `root`…) or a custom one, on a database.
- **Revoke Role…**: one of the roles the user holds.
- **Drop User…** or **Drop Role…**: asks you to type its name first. Custom roles are listed read-only: make or change
  one in mongosh.

Each shows its exact command first and runs only when you press its button; the password shows as `<secret>` there,
as it does in the Command Log. When the connection has neither TLS nor an SSH route, the preview warns that the
password travels to the server as typed. A read-only or Production connection can't change users, and agents never
can. MongoDB Atlas manages its users in its own web console (Database Access); AirSQL says so when Atlas refuses.

## Agents

With agent access set to **Schema + read** or more, AI agents can find, aggregate, count and sample a MongoDB
connection's documents, read-only: see [AI agents](agents.md#mongodb-connections). Its editor's Agents tab recommends
connecting with a login that can only read (the `read` role), so the server itself refuses any write.

## Watch Changes

**Watch Changes** (in a collection's or a database's right-click menu, and Data ▸ Collection) opens a tab that shows
the changes made to that collection, or to every collection of that database, as they happen: each insert, update,
replace and delete is a row, newest first, with the server's own fields (`operationType`, `documentKey`, `ns`,
`updateDescription`, `clusterTime`…) as columns. It needs a replica set or a sharded cluster (a mongos): on a
standalone, a view, a time-series collection or MongoDB's own databases the command is off and says why.

The tab watches from the moment it opens. **Filter** keeps only the changes that match, as a filter on the change events
in the query bar's form (`{ operationType: "delete" }`, `{ "fullDocument.status": "paid" }`). An update shows only
what changed; **Look Up Full Document** (off at first) also shows the whole document as it is now, which the server
reads again for each update. Change the filter or the tick box while stopped.

**Stop** ends the watch; **Start** continues after the last change shown, so the changes made meanwhile come first. If
the server no longer has them all (its oplog has moved on), the tab says so and watches from now. A failover is
followed: the watch carries on from the new primary without losing a change. A dropped connection or an error the
server can't resume from stops the watch and says why; it never starts again by itself, and a tab that comes back after
a relaunch waits for Start. The tab keeps the newest 10,000 changes, and at most 32 MB of them; the status bar says
how many older ones went. It reads on a session of its own, closed with the tab. Watching only reads: nothing is
written.

## Dump and restore

**Dump with mongodump…** and **Restore with mongorestore…** (Tools menu, after Flush; a MongoDB connection's right-click menu, and a
database's; a collection's has Dump) run your own MongoDB Database Tools on the connected connection, through its route.
AirSQL doesn't install them: if it finds none (where it looks for mongosh), it says where to get them, MongoDB's download
page or `brew install mongodb-database-tools`. The user goes on the command line and the password in a private file
only you can read (`--config`), removed when the tool ends; the sheet shows the exact command, which holds neither.

A dump writes one database, or one of its collections, to one `.archive.gz` file (`--archive --gzip`), Downloads by
default, with its size as it grows and Stop. A stopped or failed dump leaves no file.

A restore reads an archive back into the server: every database in it under its own name, or, with a database typed in
**Into database**, only the file's database named in **From database** (filled in from the file's name) under the new
name. **Drop each collection first** (`--drop`, off, in red) deletes each of the file's collections on the server, with
its documents and indexes, before restoring it. Without it only documents with new `_id`s are inserted: those already
there are skipped, not replaced, and a time-series collection that already exists stops the restore. Before it runs,
AirSQL asks, showing the command, the server and what it writes. A restore that stops or fails stays partly applied. A
read-only connection can't be restored into.

The tools know only one way to go without the certificate check, `--tlsInsecure`, which skips all of it. So over an SSH
or proxy route with TLS (the tools reach one server through a socket on this Mac and can't check its name), with Verify
CA, or with a certificate you trusted in AirSQL and no authority's file, the sheet says why it can't check and offers
**Run without checking the certificate**, for one run, noted in the SQL log. Agents can't dump or restore.

## Stages

An aggregation tab opens on **Stages**, a card for each stage of the pipeline, so you can build one without knowing
MongoDB's words; **Shell** (above the cards, or Data ▸ Collection ▸ **Edit as Stages** ⌃⌥8 and **Edit as Shell** ⌃⌥9)
shows the same pipeline as text. Both edit the same text: switching never changes it, and a card's edit rewrites only
its own stage, so the rest of what you typed stays as you typed it. Text that isn't a pipeline stays in Shell, with
its mistake underlined.

Each card names what it does with SQL's word beside it: **Join — JOIN**, **Filter — WHERE**, **Group — GROUP BY**,
**Sort — ORDER BY**, **Show fields — SELECT**, **Limit — LIMIT**, **Unwind** and **Shell**. Card 1 is the first stage,
card 2 the second, and so on. Choose another kind in its pop-up to start the card again as that kind; ↑ and ↓ move it,
the bin removes it, ⏭ runs the pipeline up to it (Run to Here), and after **Count Each Stage** it says how many
documents it gives. **+ Stage**, after the cards (and **+** between them), adds one: Join comes first.

- **Join**: another collection of this database (**From**), this collection's field that must equal **their field**,
  and **As**, the field that gets the matching documents as a list. **One document per match** adds an Unwind card
  after it, so each order with its customer is one document, as SQL's JOIN gives; **Keep documents without a match**
  then keeps the ones with none, as LEFT JOIN does. Under the card, warnings from the collections' samples: the two
  fields hold different types (an ObjectId never equals text, so nothing joins), their field has no index (each
  document's join reads all of theirs), or As replaces a field you have.
- **Group**: the fields to group **by** (none: every document in one group), then the results: Count, Sum, Average,
  Smallest, Largest, First, Last, List or Distinct list of a field, each named (`sum_total`; type another name).
- **Sort**: fields, each ascending or descending. **Show fields**: tick the fields to keep, and `_id`. **Limit**: how
  many documents. **Unwind**: one document per item of an array field.
- **Filter** and **Shell**: the stage as text (Filter's conditions as rows come later). A stage no card shows exactly
  (`$facet`, `$bucket`, a `$lookup` with a pipeline…) is a Shell card of its own text, which goes into the pipeline as
  you type it.

The field boxes offer the fields each stage sees: the collection's (from its sample), a join's `<As>.<their field>`,
a group's `_id` and results, only those a Show fields card keeps. Any field typed works.

Aggregations run with `allowDiskUse`, so a big group or sort spills to disk on the server instead of stopping at its
memory limit.
