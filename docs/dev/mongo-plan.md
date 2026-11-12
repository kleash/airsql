# MongoDB in AirSQL: plan (v3: decisions taken)

Goal: a MongoDB client on the Mac that a daily Compass user switches to, inside AirSQL, built on what AirSQL already does
better: routes (jump hosts, proxies, 2FA), the tiled grid, safe Apply, the agent gate, native windows and keys.

## Decisions for the owner

1. **Scope.** `docs/dev/daily-driver.md` lists Mongo under "Not doing"; this reverses it for MongoDB only.
2. **Driver: libmongoc + libbson (mongo-c-driver 2.x, Apache 2.0), a second C dependency.** Hand-writing the wire
   protocol is quick; server discovery, retryable reads/writes, sessions, cursors and SRV are years of spec work we'd own.
   Pinned and checksummed like `scripts/build-mariadb.sh`, no SASL (no Kerberos), universal, `@rpath`, signed like
   libmariadb. CLAUDE.md's "one C dependency" becomes two.
3. **SSH for replica sets: no ssh master (decided).** The driver discovers members by their own names and must reach
   each one; a route stays one ssh without `ControlMaster` (`SSHConfig.swift:42`). Phase 0 tries both and ships whichever
   works: (b) one ssh per member, or (c) ask the seed for its members, then restart ssh with every member's `-L` (again
   when a failover brings a new member). A saved password or key logs in again silently; a one-time code is asked again,
   and the UI says why. Proxy-only routes get one `ProxyRelay` per member.
4. **Shape: parallel areas, not an engine abstraction.** `SavedConnection.engine` (default `mysql`); `Connector.logIn`
   branches once; the model keeps a second dictionary for open MongoDB connections; Mongo code in
   `Sources/AirSQLCore/Mongo/` and `Sources/AirSQL/Mongo/`, plugged into Routes, `GridSource`, `TabContent`, Activity,
   Keychain, `Store` and the agent bridge. SQL menu items disable themselves on a Mongo tab with "Not for MongoDB".

## Phase 0: spike, go/no-go (about a week, one lane)

Lab (own flag, `AIRSQL_MONGO_LAB=1`, so MySQL runs don't need it): a standalone mongod and a three-member replica set,
one with TLS from the lab CA, behind the existing bastion, jump host and proxies (proxies allow 27017).

- `scripts/build-mongoc.sh`: universal libmongoc + libbson; how two static OpenSSL copies live in one process (hidden
  symbols) or one shared build; the vendor cache key covers both.
- **Every connection through a stream initiator** (standalone too), real host names in the URI: for each member the
  driver asks for, open its forward (decision 3, or a `ProxyRelay`) and return a stream on that socket, TLS wrapped
  with `mongoc_stream_tls_new_with_hostname` and the member's own name.
- **Trust**: the Keychain's and the system's roots (Atlas uses public CAs) and AirSQL's Trust/pinning. Candidates: our
  own verification after the handshake with `SecTrust` (as `TLSCheck` does for MySQL), or anchors exported to a PEM
  file per connect. And OCSP: no direct calls that bypass the route.
- A dead member's cost (the initiator runs per member, synchronously) and Cancel during it.
- Cancel of a running op: `killOp` by `comment` on the member running it, over a second client; plus `maxTimeMS`.
- Agents' second guard: reads inside a transaction that is always aborted, on replica sets (check the server refuses
  `$out`/`$merge` there).

**Done when**: a three-member replica set behind ssh + a jump host + a proxy is found (with the fewest logins the chosen option allows), its primary chosen,
a failover followed, TLS verified against each member's name with Keychain trust; and Atlas by `mongodb+srv` through a
proxy route works. Otherwise we know which fallback ships (`directConnection=true` to one member, said in the UI).

### Results (go)

`AIRSQL_MONGO_LAB=1 ./test.sh --filter MongoSpikeTests`: 12 tests, all green against the Mongo lab (`testenv/mongo`,
MongoDB 7.0.45: 8.0 and later don't run on Docker Desktop's Linux 7.0 kernel, SERVER-121912). Code:
`Sources/AirSQLCore/Mongo/` (`MongoConnection`, `MongoRoute`), `scripts/build-mongoc.sh`, `Sources/CMongoC`.

- **Library**: mongo-c-driver 2.5.8 over OpenSSL 3.5.9 (build-mariadb.sh's pins, checked by the script), linked from
  the static builds into one universal `libmongoc2.dylib` (libbson inside, `@rpath`) that exports only `bson_*`,
  `mongoc_*` and AirSQL's helper: its OpenSSL is hidden, so it can't meet libmariadb's exported copy (the script checks
  with nm, and that only libSystem, libz and libresolv are linked). No SASL, Snappy, zstd, AWS login, client-side
  encryption or shared-memory counters. About 1.5 minutes to build, cached by the script's hash in `vendor/mongoc`.
- **Every connection through the stream initiator** (standalone and Direct too): the route's socket for the host the
  driver names, or TCP; then `mongoc_stream_tls_new_with_hostname` with the member's own name (SNI too).
- **SSH: (c) won.** One ssh with a `-L` per member; `connect` first looks at the replica set through the seeds' forwards
  with a throwaway client, then restarts ssh once with every member. Logins: 1 when the connection string names every
  member, 2 with one seed; (b), an ssh per member, took 3 either way (both connected in 0.2-0.5 s on the lab), so it
  was dropped. A member added later restarts ssh again, dropping the other members' sockets once (the driver
  reconnects): not tested. Jump hosts, and a proxy then the bastion then the jump host, work the same way.
  Proxy only: a `ProxyRelay` per member.
- **Trust**: the driver's own checks are off (`weak_cert_validation`, which also skips its OCSP stapling check and
  responder requests: no network call outside the route). Right after each handshake, before the driver sends
  anything, `TLSCheck` (SecTrust: the Mac's roots and trust settings, the CA file, or the pin; MySQL's semantics) checks
  the peer chain against the member's name. The chain comes from `airsql_mongoc_peer_chain`, a small C helper built into
  the library against the driver's private headers (this version's). Another member's name, localhost and 127.0.0.1
  fail; a pin connects without the CA. The lab showed why per-member names matter: proxies with stale DNS handed
  rs2's connection for rs1, and the check refused it. SecTrust may still fetch intermediates from the Mac directly,
  as for MySQL today.
- **A dead member** (paused: it takes connections, never answers) costs `connectTimeoutMS` on each full scan, as the
  single-threaded client waits for every member: 2.05 s at 2000, 10.06 s at the default 10000. Cancel closes the route
  under the driver, which gives up within 0.2 s (proxy and ssh).
- **Cancel of a running op**: `comment` tag, then `currentOp` and `killOp` on the member running it over a second,
  `directConnection` client: the find ended with 11601 (Interrupted) about 0.1 s after the kill. `maxTimeMS` gives 50.
- **(f)** Inside a transaction the server refuses both `$out` and `$merge` with 263 (OperationNotSupportedInTransaction);
  reads work. The aborted-transaction guard holds; the BSON walk stays the first guard.
- **(g)** SCRAM-SHA-256 (an account that has only it) works. The driver checks `authMechanism` against the login while
  it parses, so user and password go into the connection string in memory (never `uri`, a log or argv; the driver's
  log is off). `mongodb+srv` is looked up on the Mac (libresolv), and the host it gives
  (`test3.test.build.10gen.cc`, a public record of the drivers' tests) is asked of the initiator, so it goes through
  the route. **Unproven**: Atlas end to end (public CA chain, TXT options, SNI routing), which the lab can't reach.
- **(h)** After `replSetStepDown` the same client wrote to the new primary on its first try (retryable writes), in
  0.5 s, without reconnecting.

For later phases: M1 starts from `MongoConnection` (its `withClient` gives the raw client; Foundation's JSON in it is a
shortcut for the BSON lane's type). Keep `connectTimeoutMS` short (a dead member costs it every scan, and the
single-threaded client rescans each minute); the connection editor should ask for every member (one login, not two);
X.509 client certificates need `pem_file` in the initiator's TLS options; the lab runs MongoDB 7.0 until 8.x runs on
Docker Desktop's kernel. Integrator: `release-local.sh`, `sbom.sh`, NOTICE and `Resources/Licenses` (Apache 2.0 and
the driver's THIRD_PARTY_NOTICES), CI's and CodeQL's caches, CLAUDE.md's "one C dependency".

## Phase 1: the MVP ("I can close Compass")

- **Connections**: engine picker; paste `mongodb://`/`mongodb+srv://`; SCRAM; TLS; replica sets and SRV over every route.
- **Tree**: databases, collections, views (time-series shown read-only), indexes; sizes from `$collStats` when a
  database is opened, not for the whole tree at load.
- **Collection tab**: `MongoDocumentSource` (a `GridSource` over raw BSON): rows are documents, columns are dotted paths
  from the union of loaded keys, sub-documents expand into columns; a JSON view of the page; a big document opens as a
  lazy tree. Shell-form values (`ObjectId(…)`, `ISODate(…)`, `NumberLong(…)`, `NumberDecimal(…)`); missing differs from
  null; mixed types badged. Batches bounded by bytes; only visible cells decoded.
- **Query bar**: filter, project, sort, limit, skip, collation, hint, maxTimeMS; field completion from the schema sample;
  history and favourites (a Mongo history store; the SQL one masks with the SQL scanner).
- **Schema**: sampling (`$sample`) per path: types and their share, null vs missing, top values, with Column Summary and
  charts. Moved up: it's Compass's signature tab, and completion and agents need the same sampler.
- **Safe editing**: edit cells, insert, clone, delete; Apply lists the exact commands, then for each document
  `updateOne({_id, <path>: <old>, <path>: {$type: <old type>}}, …)` with the collection's collation overridden to
  simple, and `matchedCount == 1`. Arrays are edited as one whole value; `_id`, keys with `.` or `$`, views and
  time-series are read-only. In a transaction on a replica set (under 60 s); on a standalone the sheet says before
  running that a failure leaves earlier changes applied. A network error's outcome is "unknown, reload": never re-run.
  Delete checks the document is unchanged first and `deletedCount == 1`.
- **Indexes**: list with sizes and `$indexStats` (per member, since restart, labelled so); create, drop.
- **Aggregation**: a pipeline editor that runs and explains.
- **Explain**: the `explain` command with `executionStats` for find and aggregate (it runs the query; say so), drawn as a
  tree: a new tree builder; `PlanView`'s drawing reused if it fits, `ExplainPlan` is MySQL-only.
- **Export**: Extended JSON v2 and CSV of a result (a writer over BSON; `RowFileWriter` takes a MySQL `ResultStore`).
  **Import**: Extended JSON.
- **Agents**: typed read-only tools (`find`, `aggregate`, `count`, `distinct`, list databases/collections/indexes,
  stats, schema sample), built from typed fields with no options pass-through. Every argument's whole BSON walked:
  `$where`, `$function`, `$accumulator`, `$out`, `$merge` refused anywhere; stages on an allow-list (recursing into
  `$lookup`, `$unionWith`, `$facet`), unknown ones fail closed; `admin`, `local`, `config` and `system.*` refused;
  `maxTimeMS` and a cap forced; reads in an aborted transaction on replica sets. SQL tools refuse a Mongo target.
  The UI recommends a read-only database user for agents.
- **Command log**: every command sent, secrets redacted.

## Phase 1: status

Built and merged on `mongo`: connections (hosts, `mongodb+srv`, replica set, auth source, options, Paste and Copy
Address), the tree, the collection tab (grid, query bar, history, JSON, Schema, Indexes with create/drop/hide), safe
editing with Apply, the aggregation tab with explain, export/import, agents' read-only tools, per-tab sessions, the
Command Log. The Fable 5.2 review of Phase 1 found two holes, both fixed with tests: a pipeline ending in `$out`/`$merge`
ran without asking (now refused on read-only connections and previewed otherwise), and Cancel failed for a login without
the `inprog` privilege (now `$ownOps`).

## Phase 2 (cut after the Fable 5.2 review)

**Integrator first:** `MongoSession`'s cursor and write helpers internal so lanes add `MongoSession+<Lane>.swift`;
liveness (a dropped tunnel or server is reported, sessions closed, pending edits kept, nothing re-run; `MongoRoute`'s
planned ssh restart for a new member is not a drop); a command and menu slot per lane; restoring Mongo tabs after a
relaunch; Quick Open and Select in Tree for collections; X.509 client certificates; read preference; the value panel's
`null`; agents' `distinct`/`stats` keeping doubles.

**Then five lanes in parallel:**

- **admin**: create, drop and rename collections, databases and views; the validation editor (`collMod`).
- **bulk**: Update Many and Delete Many with a matched-count preview through the Apply sheet; CSV import.
- **host**: a host page (`serverStatus`, replica-set members and lag), operations with kill (own operations by default,
  others when the login may), Disk Usage.
- **compare**: two collections or clusters by `_id`, plus indexes and validators; reconcile writes only through
  `MongoApply` (inserts and replaces by default, deletes opt-in and marked, a read-only target refused); a merge of
  `_id`-sorted streams only for single-type `_id`s, `$in` lookups otherwise; "ignore key order".
- **aggregate**: run to a stage, saved pipelines, export a result, Save as View, Open mongosh in Terminal over the route
  (the user only, so mongosh prompts; never a password on argv).

**Later** (built in Phase 4): mongodump/mongorestore, AWS IAM, change-stream tail, users and roles. **Dropped:** OIDC (its browser flow needs a loopback TCP listener), aggregation
templates (saved pipelines cover them).

## Phase 3: autofill and agents that know the database (designed by the Fable 5.2 review)

**Autofill.** One completion engine in Core (`MongoCaret` scans half-typed shell text to the caret for the key chain,
slot and prefix; `MongoCompletion` answers) behind three adapters: the query bar's fields, the pipeline editor, and the
Edit Value / Insert Document editors. It offers field paths (nested and `.[]`), query and update operators by the field's
sampled type, value constructors by type (`ObjectId("")`, `ISODate("")`), top values of low-cardinality strings, stage
names and each stage's argument keys (`from:` gives collections, `foreignField:` that collection's paths), expression
operators (accumulators only in `$group`/`$setWindowFields`), and after `$group`/`$project` that stage's own keys.
Ranking: prefix, then the one fuzzy matcher, indexed leading fields first, then share in the sample. The schema comes from
a per-collection sample cache on `MongoConnection` (shared with agents; `$sample` 200 under 5 s, unioned with loaded pages
and the validator's `$jsonSchema`; dropped by Refresh; never on disk).

**Agents.** `mongo_schema` (the whole database in one call within 24 KB: paths by share, types, enums, indexes, views,
inferred references such as `orders.customerId -> customers._id (50/50)` checked by an `$in` probe); `mongo_explain`
(`plan` runs nothing: a free validator); `mongo_open` (puts a find or pipeline in a new tab marked "Proposed by <agent>",
never run: the only route to a write stays the person's Run with its preview); Mongo tabs in `context`/`read_console`;
`to_file` on find and aggregate (analytics access, the Agent Exports folder only); errors and warnings that teach (a path
not in the sample with the nearest one, a literal of a type the field never has).

**End-to-end test.** A deterministic shop seed (customers, products, orders with nested items, reviews; orphan orders,
customers without orders, an injection canary in a review), answers from an independent plain-JS oracle, 12 questions
from easy to `$lookup`/`$facet`/dates plus "propose in a tab" and "cancel order X" (must not happen). Tier A: golden
pipelines through the real `--mcp` bridge in every Mongo lab run. Tier B (`AIRSQL_AGENT_E2E=1`): a real headless agent
answers over AirSQL's MCP server, results compared by value; pass at 9 of 10 data answers, the tab left unrun, the
document unchanged, the canary harmless.

**Lanes:** groundwork first (the operator/stage word list, the sample cache, the seed and oracle, tool slots), then
completion, agent knowledge, agent control and E2E in parallel.

## Phase 3: status

Built and merged on `mongo`: autofill in the query bar, the pipeline editor and the document editor (`MongoCaret`,
`MongoCompletion`, `MongoWords`, the shared sample cache); agents' `mongo_schema` (the shop database in about 3.6 KB with
inferred references), `mongo_explain`, `to_file`, teaching errors and warnings, `mongo_open` (a proposed tab that never
runs on its own), MongoDB tabs in `context` and `read_console` (with the query as Extended JSON too). The end-to-end test
passes: Tier A in every Mongo lab run, and Tier B with a real agent (Claude Haiku, about $0.03 a run) answered 10 of 10
data questions on the first try, proposed a correct query in a tab without running it, did not cancel the order, and
treated the injection canary as data. Also fixed on the way: a MongoDB login's database is Auth source (admin when empty);
the Database field only says which database opens.

## Phase 4: status

Designed with the Fable 5.2 review (the tools know only `--tlsInsecure`; the driver's own AWS credential search is never
used; libmongoc resumes a change stream by itself) and built in four lanes, merged on `mongo`:

- **Dump and restore** (Tools ▸ Dump with mongodump… / Restore with mongorestore…): one database or collection to one
  `.archive.gz` streamed through the app (progress, Stop, no partial file); restore with an optional rename, `--drop`
  opt-in and marked, refused on read-only connections, confirmed with the exact command. The password goes in a 0600
  `password:` config file deleted when the run ends; over a route, Verify CA or a pinned certificate the tools can't
  check names, so they run only with the person's "Run without checking the certificate" tick.
- **AWS IAM** (`MONGODB-AWS`, libmongoc built with it): the access key ID in User, the secret in Password, an optional
  session token in the Keychain, added to the string only in memory. mongosh, dump and restore are off for it (the token
  would go on argv). Untested against Atlas: the lab's Community servers refuse the mechanism, which the lab test checks.
- **Watch Changes** (a collection or database on a replica set or mongos): a filter, Look Up Full Document, Start/Stop
  continuing from the resume token, 10,000 events or 32 MB kept; it stops and says so on errors the driver can't resume.
- **Users and roles** (Connection ▸ MongoDB Server ▸ Users and Roles): users and custom roles with the per-database
  fallback; create, drop, change password, grant and revoke roles, drop a role; previews redact `pwd`. Creating and
  editing custom roles is left out.

Also: mongosh runs for real in the lab (Direct, SSH, every TLS mode, X.509, which now passes the client certificate),
and the real-agent test runs on the replica set too (10 of 10 on each). CI on GitHub builds both libraries.

## Phase 5: builders for people who know SQL, not MongoDB (designed with the Fable 5.2 review)

The owner, 2026-11-12: filters, partial and complex filters, joins and aggregation all had to be typed in shell form;
"a noob in mongodb who is coming from sql database background can easily handle and do complex queries easily".

**Principle.** The shell text stays the one source of truth (Run, history, restore, Explain, agents read it). The
builders edit it: a builder edit rewrites only its own part (a query bar field; one stage's `MongoPipeline.Stage.range`,
spliced in place); switching modes never touches the text. What a builder can't read stays text: that part only (an
unreadable filter shows its text field in place of the rows while Show and Sort stay GUI; a stage becomes a Shell card).
SQL names sit beside MongoDB's everywhere: "Filter — WHERE", "Show fields — SELECT", "Sort — ORDER BY", "Join — JOIN",
"Group — GROUP BY", "Limit — LIMIT"; operators "contains — LIKE '%x%'", "is one of — IN", "has no value — IS NULL".

**A. Query builder** (collection tab, **Builder | Shell**; a new tab opens in Builder):
- Find documents where [all/any] of: condition rows, `+ Condition`, `+ Group` (one group level; deeper stays text).
  Row: field (combo box: sample paths, each with its types, "text 80%, number 20%"; any typed path works), operator by
  the field's type (an array field's from its element type), value, Ignore case on text operators, remove.
- Operators: is / is not, contains / doesn't contain / starts with / ends with (escaped regex; Ignore case → `i`),
  matches pattern (raw), greater / at least / less / at most, between, is one of / is none of (comma list), has a value /
  has no value (`$ne: null` / `null`; `$exists` reads back as these).
- Values: typed by the sample's main type (text, number, date, ObjectId, true/false); a shell constructor typed
  (`ObjectId("…")`, `UUID("…")`, `NumberDecimal("…")`) is taken as written; the box offers the sample's top values,
  already typed. Numbers: Int64 if whole else Double (the server compares across number types). Dates are UTC (said so):
  a day without a time is a range (`$gte` day, `$lt` next day), "between" days includes the last day; presets today,
  last 7 days, this month. A date typed for a string-typed field warns.
- Writing: `$and` whenever a key repeats or there are several any-groups; empty groups dropped; never duplicate keys.
  Parse-back refuses duplicate keys, sub-document/array equality, `$eq` of a regex, `$elemMatch`, and anything else
  outside these shapes; the round trip build → text → parse → build is the test.
- Rows on fields under the same array (`items.sku`, `items.qty`) get a note: they may match different items.
- Show (projection ticks, `_id` on), Sort rows, Skip, Limit; "Ignore case in comparisons and sorting" (collation
  strength 2; also changes is/in/ranges, not regex). The query in shell form under it, one selectable line, including
  Hint and Max Time when set in Shell.
- The grid gets the cell Quick Filter the MySQL grid has (`QuickFilter`'s menu shape, `GridCondition.Operator` subset:
  is, is not, greater, less, contains; ⌥ adds to the filter), from the cell's real BSON value. Schema value ⌥-click adds.
- **Aggregate…** in the query bar opens an aggregation tab with the current filter, sort, projection, skip and limit as
  its first stages.

**B. Stage builder** (aggregation tab, **Stages | Shell**): a card per stage (kind, ↑ ↓, remove, Run to Here, Count
Each Stage's count), `+ Stage` lists Join first. Cards: Filter (the conditions block of A), Join (`$lookup`: from a
collection of this database, this field = their field, as — default the alias/collection name; "One document per match"
inserts or removes a visible Unwind card after it, "keep documents without a match" its preserve flag), Group (by
fields; Count, Sum, Average, Smallest, Largest, First, Last, List, Distinct list; `_id` `"$a"` or `{ a: "$a" }`; parse-
back only when names match the ones it would write), Sort, Show fields, Limit, Unwind, Shell (any stage as text, with
the error underline). No folding of stages: card n is stage n. Fields downstream follow the stages (Join adds
`<as>.<their paths>`, Group gives `_id` and its names, Show narrows). Join warnings (one helper, from cached samples,
shared with SQL): types differ (ObjectId vs string matches nothing), no index on their field, `as` overwrites a field.
Aggregations run with `allowDiskUse` so big groups don't hit the server's memory limit.

**C. Query with SQL** (aggregation tab, a third mode **SQL**; "Query with SQL…" from the collection tab and the tree):
`SELECT … FROM coll [a] [LEFT] JOIN other [b] ON a.x = b.y … WHERE … GROUP BY … HAVING … ORDER BY … LIMIT … OFFSET`,
parsed with AirSQL's `SQLParser` and translated in core (`MongoSQL`) to a pipeline, always; the MongoDB pipeline shows
beside it and "Open as Stages" switches to cards. One way: translating replaces the pipeline text, asking first when
that was edited by hand. Supported: columns, `*`, aliases, dotted paths, COUNT(*), SUM/AVG/MIN/MAX(col), DISTINCT;
INNER and LEFT JOIN on one equality (`$lookup` + `$unwind`, preserve for LEFT; the alias is `as`); WHERE = <> < <= > >=,
AND/OR/NOT, IN, NOT IN, BETWEEN, LIKE / NOT LIKE (anchored escaped regex, `i` and `s`: MySQL people expect LIKE to
ignore case), IS [NOT] NULL; GROUP BY, HAVING; ORDER BY names/positions; LIMIT, OFFSET; literals string, number,
TRUE/FALSE, NULL, `DATE '…'`, `TIMESTAMP '…'`, `ObjectId('…')`. Conditions on the base collection only go before the
`$lookup`. Refused with a plain message naming the part (never guessed): syntax errors, CTEs, UNION and other set
operators, subqueries, CASE, window functions, expressions in SELECT, ON other than one equality, RIGHT/FULL/NATURAL/
USING, COUNT(DISTINCT), COUNT(col), ESCAPE, anything that writes. Notes shown with the translation: `=` is case-
sensitive and never converts string to number/date/ObjectId (warn from sample types); `<>`, NOT IN and NOT LIKE also
return documents without the field; GROUP BY puts null and missing in one group.

**Out of scope:** drag-and-drop, `$expr`/`$where` builders, geo, `$facet`/`$bucket`/`$graphLookup`/pipeline `$lookup`
forms (Shell cards), a stage disable switch, nested groups deeper than one, update/delete builders.

**Lanes (Opus 5.5 medium):** 1. **core**: `MongoBuilder.swift` (conditions, values, projection, sort, collation, to and
from documents), `MongoStageForm.swift` (cards ↔ stages, fields downstream), `MongoJoinCheck` (the warnings), tests.
2. **sql** (in parallel with core): `MongoSQL.swift` + tests + a lab oracle test on `shop`. Then, on core: 3. **query**
(the query bar's Builder, Quick Filter, Aggregate…) and 4. **stages** (cards, then the SQL mode once sql is merged).
Integrator: merge, every SQL translation opens as non-Shell cards bar a listed few, light/dark look, docs.

## Not doing

An embedded JS shell; drag-and-drop stage builder; natural-language queries in the app; Kerberos/LDAP; CSFLE and
Queryable Encryption; Atlas Search UI; sharding and time-series admin.

## Lanes (Opus 5.5, medium effort)

Phase 0 is one lane. Then in order:
1. **P0-M, integrator**: the `engine` field, connection editor and `Connector` branch, the model's Mongo dictionary,
   `Menus+Mongo` and the "Not for MongoDB" helper, the agent target branch, Package.swift `CMongoC`, the build script
   in `build.sh`/`test.sh`/`release-local.sh`/`sbom.sh`/CI, the Mongo lab and `Lab.swift`.
2. **M1, core**: `MongoConnection` (a worker thread per session as `DBConnection`), the BSON value type, its shell-form
   formatter and parser, errors in plain words. Every later lane uses these.
3. **M2**: tree, collection tab, `MongoDocumentSource`, query bar, schema sampler.
4. Then in parallel: **M3** editing and Apply, **M4** aggregation and explain, **M5** export/import, **M6** agents.

Integrator-only files: `Commands*.swift`, the sidebar, the connection editor, the agent tool list, `AgentGuide.md`, the
build scripts. Each lane: the simplicity rule, its own suite, lab tests on standalone and the replica set, a BSON
round-trip test per type (grid edit, export, import) against mongosh's output as the oracle.

## Risks

1. Replica sets through routes, and trust (Phase 0 decides).
2. Type fidelity: raw BSON end to end; no `Double`, `NSNumber` or `JSONSerialization` (the grid's `JSONNode` uses it, so
   documents get their own tree).
3. The agent gate on an engine with no read-only session: typed tools, the full BSON walk, the aborted transaction.
4. Scope: the MVP list is the contract.
