# Contributing to AirSQL

Thank you for helping. Bug reports, fixes, docs and features are all welcome. For a bigger change, open an issue first
so we can agree on the approach before you write it.

## Build and test

You need a Mac with macOS 13.1 or later and the Command Line Tools (`xcode-select --install`); Xcode isn't needed.

```sh
./build.sh --native      # build/AirSQL.app for this Mac (./build.sh: universal); the first build compiles libmariadb
swift build              # the debug build, which must have no warnings
./test.sh                # the tests (Swift Testing, needs Swift 6); ./test.sh --filter DriverTests runs one suite
AIRSQL_LAB=1 ./test.sh   # also the lab: MySQL and MariaDB servers and the SSH and proxy routes, in Docker (testenv/)
```

The app builds with Swift 5.9 or later. The tests never touch your `~/.ssh` or your Keychain. libmariadb (MariaDB
Connector/C with OpenSSL) is built by `scripts/build-mariadb.sh` from pinned, checksummed sources, once, into a cache
next to the repository.

## What a change needs

- **The smallest change that solves the problem.** No new layers, settings or abstractions unless the problem needs
  them.
- **No third-party Swift packages, and nothing from Homebrew** in the build or the app. The one C dependency is
  libmariadb; the SBOM (`scripts/sbom.sh`) and the vulnerability scan read its pins in `scripts/build-mariadb.sh`.
- **The app explains itself.** Every button, menu item and field gets a one-line tooltip (verb first, no full stop); a
  disabled one says why. A test fails on any control without one. Plain words first, jargon in brackets.
- **Native feel**: single click selects, double click opens, right click shows the menu; no database, network or file
  work on the main thread; a busy indicator for anything slow.
- **Security and data safety**: secrets only in the Keychain, SQL only through the quoting helpers, nothing written
  without Run or Apply (CLAUDE.md has the full list).
- **Tests** for what you change, and `./test.sh` green. CI runs it on every pull request.
- **Docs**: the page in `docs/` for what users see (plain words, task-first), `Resources/AgentGuide.md` for what agents
  reach, then `scripts/llms.sh` to refresh `docs/llms.txt` and `docs/llms-full.txt` (CI checks them).
- No passwords, real server names, personal paths or e-mail addresses in code, tests, docs or screenshots.

## Pull requests

Fork, branch, and open a pull request against `main`. Describe what changed and how you checked it. CI must be green.
Changes that need the Docker lab are run by a maintainer on their Mac. Commit messages are short and imperative ("Show
the row count in the status bar").

Working with an AI coding agent? `CLAUDE.md` and `AGENTS.md` describe the codebase, the rules and the CI loop for it;
the plan every change follows is [docs/dev/plan.md](docs/dev/plan.md).

## Licence

AirSQL is Apache 2.0. By contributing you agree that your contribution is licensed the same way.
