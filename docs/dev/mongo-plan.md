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

## Phase 2

Compare and reconcile by `_id` (plus indexes and validators); host page and Disk Usage (`serverStatus`, `currentOp` with
kill); validation editor; users and roles; mongosh, mongodump and mongorestore over routes (they need
`directConnection` and can't check the name over a socket; mongosh takes passwords only in argv or a prompt); aggregation
extras (run to a stage, templates, saved pipelines); CSV import; hide/unhide; read preference; X.509, AWS IAM, OIDC;
change-stream tail.

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
