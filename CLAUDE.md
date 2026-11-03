# AirSQL: notes for Claude (and other coding agents)

AirSQL is a native macOS app (Swift, AppKit; SwiftUI only for Swift Charts; macOS 13.1+) for MySQL and MariaDB:
connections over every route (direct, SSH tunnel, jump hosts, proxies, each ending in a private Unix socket), a SQL
console, a custom data grid with safe editing, schema tools, client tools, compare and reconcile, Liquibase, and agent
access over MCP behind a gate that fails closed. It is in development (0.1.0). It follows AirSCP (`../porter`, Apache
2.0, same author): ported files keep AirSCP's type names and a first line naming the AirSCP file and version.

The source of truth is [docs/dev/plan.md](docs/dev/plan.md): architecture, phases and lanes, and these rules in full.
Also `docs/dev/grid-spec.md` (the grid), `docs/dev/mockups.html` (the look: themes Porcelain and Deep Water),
`docs/dev/scope.html` (every feature row, in its `GROUPS` array) and `docs/dev/research.md`.

## Rules for every change

- **Simplicity first**: the smallest change that solves the problem; no speculative abstractions, no new layers or
  settings unless a scope row needs them. Read the surrounding code (and AirSCP's) and follow its patterns; comments
  say why, not what.
- **Toolchain**: Command Line Tools only (no Xcode project), Swift 5 language mode, code that compiles with Swift 5.9+,
  deployment target macOS 13.1, universal (arm64 + x86_64), built with the macOS 26 SDK (`build.sh` picks it, as CI
  does). No third-party Swift packages. Nothing from Homebrew in the build or the app. The one C dependency is MariaDB
  Connector/C with OpenSSL, from `scripts/build-mariadb.sh` (pinned, checksummed).
- **Native feel**: single click selects or shows, double click opens or edits, right click opens the item's menu, on
  every surface (plan §2.12); ⌘/⇧ multi-select; every action in the menu bar with its shortcut; full keyboard use;
  **no database, network or file work on the main thread**; a busy indicator for anything slow (§2.11); a polished
  layout with no cut text (§2.13). Since macOS 14 a view isn't clipped to its bounds: draw only inside it (intersect
  `dirtyRect` with `bounds`).
- **The app explains itself**: every control and menu item has a one-line tooltip (verb first, no full stop); disabled
  items say why; plain words before jargon; empty states say what to do next.
- **Security defaults**: secrets only in the Keychain, never on a command line, in logs, in agent replies or the SQL
  log; SQL built only with the quoting helpers; TLS verified against the real server name; restricted login plugins;
  `LOCAL INFILE` off; multi-statements off; local endpoints are Unix sockets in a private folder, never TCP ports.
- **Data safety**: nothing is written without Run or Apply; Apply checks affected rows exactly; no silent reconnect;
  destructive steps are opt-in and marked.
- **Docs follow the code**: the user page in `docs/`, `Resources/AgentGuide.md` for anything agents reach; then run
  `scripts/llms.sh` (CI checks that its output is up to date).
- **Shared files** (Package.swift, the menu skeleton, the Settings window, shared UI, the docs index) belong to P0 and
  then to the integrator: a lane lists the changes it wants in its report.
- **Commits**: short imperative messages that say what the code now does, with the repository's own git identity and
  no attribution trailers. Never commit build outputs or `vendor/`.
- **The repository is public** (github.com/kleash/airsql): no secrets, real hostnames, personal paths or e-mail
  addresses in code, tests, docs, screenshots or commit messages.

## Safety (you are working on someone's own Mac and accounts)

- Never read or write `~/.ssh`: tests use a throwaway SSH folder, as AirSCP's `testenv/AGENT.md` describes. Tests keep
  passwords in an in-memory store, never the login Keychain.
- Docker: AirSQL's lab is the Compose project `airsql-lab`. Never stop, recreate or change containers you didn't create
  (AirSCP's `porter-lab-*`, the old `mysqlmacclient-test-*`); give your own a prefix of yours and remove them when done.
- Never run the x86_64 slice. Don't install into `~/Applications`. Kill what you start.

## Layout

| Path | What |
|---|---|
| `Package.swift` | Targets: `CPTY` (C, from AirSCP: run a program on a pseudo-terminal), `CMariaDB` (module map over libmariadb's headers in `vendor/out`; links it), `AirSQLCore` (no UI), `AirSQL` (the AppKit app), `AirSQLTests` (Swift Testing) |
| `Sources/AirSQLCore/<Area>/` | Core code by area: `Driver/` (`MariaDB.swift`: the client library's version), `DB/` (the driver and sessions: `DBConnection`, `Connection`, `ResultStore`, `SQLQuote`, `SQLLog`, `ErrorMapping`, `TLSCheck`), `Schema/` (the schema cache), `SQL/` (the SQL text: `SQLLexer`, `SQLSplitter`, `ReadOnlyClassifier`, `SQLWords`, and `SQLLexer.sameTokens` for the formatter), `Models/` (saved connections, settings, `Store`, `Keychain`), `Activity/` (slow work and its Cancel), `Tools/` (the client tools and their option file, `Runner`, the built-in export, SQL file runner and CSV import), `Editors/` (table designs and their ALTER/CREATE, column types per flavour, object CREATE code and DEFINER, the ER layout and Mermaid), `Recon/` (compare and reconcile: structure, data by chunks, the sync script and report), `Agents/` (the MCP bridge (`--mcp`), the agent socket, the tools and their read-only runner, agent setup; `AgentGate.swift`: the agents' gate in the driver and what only the person may change), `Routes/` (route settings, `Tunnel`, `ProxyRelay`, `ProxyConnect`, askpass, the generated ssh_config, ssh config import, `OpenRoute`), `Navigator/` (the navigator's statements), `Grid/` (`GridSource` and its columns, cells and marks, `GridSelection`, `ResultSetSource`, `TransposedSource`, Display As, the status bar's figures and Column Summary, charts' points, JSON trees), `GridData/` (the table tab's `TableDataSource`, which writes its pages, counts and summaries; filters, find and sorting; `PendingChanges` and Apply; the copy and export formats and the .xlsx writer), `GridEdit/` (typed cell values and their literals, auto values, paste, foreign-key lookups, which results can be edited) |
| `Sources/AirSQL/<Area>/` | The app by area; `main.swift` runs helper modes (`--version`, `--mcp`, ssh's askpass) first, then the app. `Menus/Commands.swift` is the one table of commands, shortcuts and tooltips (`Menus+<Lane>.swift`: the lanes' slots); `Settings/` has one file per pane; `Tools/` (the tools' sheets and `ToolsResponder`), `Editors/` (table editor, object editors, ER diagram), `Recon/` (the compare window), `Agents/` (`AgentService`, the activity popover; `AgentService+Gate.swift`: `AgentGuard` and the gate's approver), `Connections/` (`Connector`, the connection editor and its tabs, the connect prompts and Trust sheets, folders, ssh config import), `Navigator/` (`OpenConnection`, the tree, database view, table commands, Find Text, process list), `Grid/` (`DataGridView`, the data grid, and `GridViewer`, which hosts it with the status bar's figures, value panel, Record View, Transpose, Display As, heatmaps, View As, charts, Column Summary and copying), `GridData/` (the table tab, `TableDataController`, with its grid bar, find bar, notice, editing by type (pick-lists, the SET checklist, `ForeignKeyLookup`, Insert Value), paste, Apply and the rows read back, and the Export Rows and Filter by Values sheets); `App/QuitCheck.swift` (what Quit asks about); `Harness/` drives the UI, for the tests and agents' UI tools (`AgentServer+Gate.swift`: the gate and redaction there) |
| `Tests/AirSQLTests/<Area>Tests.swift` | One suite file per area (`DriverTests.swift`); lab tests need `AIRSQL_LAB=1`. `Support/`: isolation, polling and a throwaway sshd (`Support.swift`), the lab's endpoints (`Lab.swift`), fake proxies (`TestProxy.swift`), the app tests' window and harness (`App.swift`; UI tests go in `extension AppTests`, which runs serialized) |
| `testenv/` | The Docker lab (Compose project `airsql-lab`): `docker-compose.yml`, `up.sh [service...]`, `down.sh`, `seed/` (the fixture and logins), `AGENT.md` (how to use it, the throwaway credentials) |
| `Resources/` | `AirSQL-Info.plist`; `AppIcon.icns`; `Licenses/` (copied into the app with `NOTICE`); `AgentGuide.md` (what agents read: keep it in step with the tools) |
| `plugins/airsql/`, `.claude-plugin/marketplace.json` | The Claude Code plugin (AirSQL's MCP server and skill) |
| `mcpb/`, `scripts/build-mcpb.sh` | The MCP bundle (`airsql.mcpb`) for Claude Desktop |
| `scripts/release-local.sh`, `scripts/sbom.sh`, `packaging/homebrew/` | A release (Developer ID, notarized; `--adhoc` for a dry run), its SPDX SBOM, the Homebrew cask template; `docs/dev/release.md` says how |
| `scripts/llms.sh` | Writes `docs/llms.txt` and `docs/llms-full.txt` from the help and the agent guide |
| `scripts/make-icon.swift` | Draws the app icon: `Resources/AppIcon.icns`, the README's `docs/assets/icon.png` and the help site's `docs/favicon.ico` |
| `scripts/build-mariadb.sh` | libmariadb: Connector/C 3.4 over a static OpenSSL, universal, install name `@rpath/libmariadb.3.dylib` |
| `docs/dev/` | The plan, grid spec, mockups, scope and research |

## Build and test (on a Mac)

```sh
./build.sh --native      # build/AirSQL.app for this Mac (./build.sh = universal): libmariadb in Contents/Frameworks,
                         # everything signed ad hoc inside out, then codesign --verify --deep --strict
swift build              # debug build: must have 0 warnings (run the app from build/AirSQL.app, where libmariadb is)
./test.sh                # Swift Testing (needs Swift 6); extra args go to swift test: ./test.sh --filter DriverTests
AIRSQL_LAB=1 ./test.sh   # + the lab suites, on the lab as it runs; when some of it doesn't, testenv/up.sh starts it,
                         # in the main checkout only: worktrees share that lab and its key and CA (testenv/AGENT.md)
AIRSQL_SCREENSHOTS=1 ./test.sh --filter ScreenshotTests   # light and dark pictures of each screen, in build/screenshots
AIRSQL_SCREENSHOTS=1 ./test.sh --filter GridScreenshotTests   # the grid's light and dark pictures, in build/screenshots
AIRSQL_GRID_FPS=1 ./test.sh -c release -Xswiftc -enable-testing --filter GridFrameRateTests
                         # the grid's frame rate on this Mac's display (puts a window on screen for about 15 s)
```

UI tests drive the app in-process through `Sources/AirSQL/Harness` (`appWindow` and `call` in
`Tests/AirSQLTests/Support/App.swift`).

libmariadb comes from a vendor cache outside the repository: `scripts/build-mariadb.sh` keeps its output in
`$AIRSQL_VENDOR_CACHE/<SHA-256 of the script>` (default `../airsql-vendor-cache`, shared by every worktree) and copies
it into `vendor/out`; `build.sh` and `test.sh` run it when `vendor/out/stamp` isn't the script's SHA-256. A changed
script (a version, an option) builds once more, in about two minutes.

Gates for a change: `swift build` 0 warnings; `./test.sh` green; the lab suites when the change can affect them;
`./build.sh` with its signature check; a launch of the built app in light and dark.

## CI

`.github/workflows/ci.yml` (macos-26, Command Line Tools with the macOS 26 SDK; the tests with Xcode 26's toolchain,
whose Swift Testing has its macro plugin): libmariadb (cached by the script's hash), `swift build` without warnings,
`./test.sh`, `./build.sh` (universal), then the signature and `AirSQL --version` from the bundle. `codeql.yml` scans
the Swift and C code; `security.yml` runs gitleaks over the whole history (`.gitleaks.toml`). Follow a run with
`gh run watch`, read a failure with `gh run view <id> --log-failed`.
