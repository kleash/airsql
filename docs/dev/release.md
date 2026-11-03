# Releasing AirSQL

A release is a tag `vX.Y.Z` whose `VERSION` says `X.Y.Z`, made as AirSCP's are (its `docs/dev/release.md`). It ships:

| File | What |
|---|---|
| `AirSQL-X.Y.Z.zip` + `.sha256` | The universal app, Developer ID signed with the hardened runtime, notarized and stapled |
| `mariadb-connector-c-<v>-src.tar.gz`, `openssl-<v>.tar.gz` | The exact source of the libmariadb inside (NOTICE's offer: the LGPL lets people rebuild and replace it) |
| `airsql.mcpb` + `.sha256` | The MCP bundle (`scripts/build-mcpb.sh`) |
| `sbom.spdx.json` | The SBOM (`scripts/sbom.sh`) |
| `AirSQL-X.Y.Z.intoto.jsonl` | Signed build provenance for the files the release workflow built |

and the Homebrew cask in `kleash/homebrew-tap`. `.github/workflows/release.yml` does everything after the zip; the
zip is made either on the Mac (`scripts/release-local.sh`) or in CI when the signing secrets exist.

## One-time setup

| What | How |
|---|---|
| Developer ID certificate | Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application (the one AirSCP uses works). |
| Notary credentials on the Mac | `xcrun notarytool store-credentials airsql-notary --apple-id <Apple ID> --team-id <team ID>` |
| `TAP_TOKEN` secret | A fine-grained token with **Contents: Read and write** on `kleash/homebrew-tap` only: `gh secret set TAP_TOKEN -R kleash/airsql`. Without it, release.yml puts the filled cask in the run's summary instead. |
| CI signing (optional) | The secrets AirSCP's release uses: `DEVELOPER_ID_P12` (`base64 -i DeveloperID.p12`), `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY` (`base64 -i AuthKey_XXXX.p8`, an App Store Connect API key), `NOTARY_KEY_ID`, `NOTARY_ISSUER`. Then a tag alone releases. |
| GitHub Pages | Settings ▸ Pages ▸ Deploy from a branch ▸ `main` / `/docs` (the help site: `docs/`, Just the Docs as a remote theme). |
| Private vulnerability reporting | Settings ▸ Code security ▸ on (SECURITY.md and the code of conduct point to it), with Dependabot alerts and secret scanning with push protection. |

## Before the tag

1. `VERSION`, and the same version wherever `scripts/build-mcpb.sh` checks it (`mcpb/manifest.json`, the Claude Code
   plugin's `plugin.json`).
2. `scripts/llms.sh` (CI fails while `docs/llms.txt` and `docs/llms-full.txt` are out of date).
3. CI, CodeQL and Security green on `main`; the lab suites (`AIRSQL_LAB=1 ./test.sh`) green.
4. A dry run: `scripts/release-local.sh --adhoc` (below), then launch `build/AirSQL.app`.

## Release

On the Mac with the Developer ID:

```sh
scripts/release-local.sh   # universal build → Developer ID + hardened runtime → notarize → staple → zip + SHA-256
gh release create vX.Y.Z build/AirSQL-X.Y.Z.zip build/AirSQL-X.Y.Z.zip.sha256 \
    --target main --title "AirSQL X.Y.Z" --notes-file notes.md
```

Publishing the release (it creates the tag) starts release.yml: it checks the zip (version, universal, signature,
Gatekeeper, and that the app starts with its libmariadb), adds the library's source, the bundle, the SBOM and the
build provenance, and updates the cask. Publish it, don't leave it a draft: the workflow can't read a draft's files.
A run that started from the tag before the zip was there fails with what to do; run it again from Actions ▸ Release ▸
Run workflow (tag `vX.Y.Z`). With the CI signing secrets, a tag is enough: `git tag vX.Y.Z && git push origin vX.Y.Z`.

## The hardened runtime and libmariadb

The release signs `Contents/Frameworks/libmariadb.3.dylib`, then the app, with the Developer ID and `--options runtime`,
and no entitlements:

- **Library validation** comes with the hardened runtime: the app loads only libraries signed by Apple or by its own
  team. libmariadb carries the same Developer ID, so it loads; the release workflow proves it by starting the app from
  the zip (`AirSQL --version` prints the library's version, and dyld would stop the app before that).
- **No entitlements.** AirSQL compiles no code at run time (no JIT or unsigned executable memory) and needs no camera,
  microphone, location, contacts, calendars, photos or Apple Events. The network entitlements belong to the App
  Sandbox, which this build doesn't use, so connections need none: the first connection to the local network shows
  macOS's question (`NSLocalNetworkUsageDescription` in the Info.plist).
- **Ad hoc can't pass library validation**, tested on macOS 27.2: signed ad hoc with `--options runtime`, dyld finds
  the bundled library through `@rpath` and refuses it ("mapping process and mapped file (non-platform) have different
  Team IDs"), because an ad hoc signature has no team. So `./build.sh` stays ad hoc without the runtime for development
  and CI, and the dry run `scripts/release-local.sh --adhoc` adds the hardened runtime with library validation turned
  off (`com.apple.security.cs.disable-library-validation`): it proves the rest of the runtime and the loader path, and
  the app starts. That zip is never released: Gatekeeper refuses it, so release.yml would stop.
- **Replacing the library** (NOTICE's steps: sign the library, then the app, again ad hoc) still works on a release:
  re-signing the app ad hoc drops the Developer ID signature with its hardened runtime, so the new library loads.

On the notarized app, check what the hardened runtime could break: a connection through an SSH tunnel and a jump host,
a proxy, TLS with a server certificate to trust, the client tools (`mysql`, `mysqldump`) and Open in Terminal, and
agents over `--mcp`.

## After: check it from the outside

```sh
gh release view vX.Y.Z                          # zip, .sha256, the two .tar.gz, airsql.mcpb, .sha256, sbom, .intoto.jsonl
shasum -a 256 -c AirSQL-X.Y.Z.zip.sha256        # in the download folder
spctl -a -vvv -t exec /Applications/AirSQL.app  # "accepted, source=Notarized Developer ID"
gh attestation verify airsql.mcpb --repo kleash/airsql --bundle AirSQL-X.Y.Z.intoto.jsonl   # and sbom.spdx.json
brew install --cask kleash/tap/airsql --appdir="$(mktemp -d)"   # then uninstall
brew audit --cask --online kleash/tap/airsql
```

## Build provenance

release.yml's `actions/attest` step makes SLSA build provenance for the files that run built, signs it with Sigstore
through GitHub's artifact attestations and adds it to the release as `AirSQL-X.Y.Z.intoto.jsonl`. It covers the SBOM
and the bundle always, and the zip only when release.yml built and notarized it (the CI signing secrets): a zip made on
the Mac didn't come out of that run. That zip is checked by its SHA-256 and Apple's notarization. The source tarballs
are downloads, checked against the SHA-256s that `scripts/build-mariadb.sh` pins and the SBOM lists.

## Security scans

| Workflow (badge) | What it checks | When |
|---|---|---|
| `codeql.yml` (CodeQL) | AirSQL's Swift and C with the `security-extended` queries | Pushes to `main`, pull requests, by hand |
| `security.yml` (Security) | OSV-Scanner on the SBOM against osv.dev, after showing it flags Connector/C 3.1.7 and OpenSSL 3.5.0; gitleaks over every commit | Pushes to `main`, pull requests, by hand, and before every release (release.yml calls it) |
| `scorecard.yml` (OpenSSF Scorecard) | Supply-chain practices; publishes the score behind the badge | Pushes to `main`, by hand |

A finding fails the run. For a CVE in Connector/C or OpenSSL: move the pin in `scripts/build-mariadb.sh` to the fixed
release, then the gates and a release. OSV lists few Connector/C CVEs (most are filed against MariaDB Server), so read
Connector/C's release notes when its pin moves. Every action is pinned to a commit SHA with its version in a comment,
and every tool a workflow or script downloads is one release checked by its SHA-256.

## The cask

`packaging/homebrew/Casks/airsql.rb` is the cask with a placeholder version and SHA-256 (modelled on AirSCP's in
`kleash/homebrew-tap`). release.yml fills both from the release's zip and writes it to the tap as `Casks/airsql.rb`.
No `binary` stanza, as in AirSCP's cask (whose binary, run through a symlink, can't find its bundle): agents use the
full path `/Applications/AirSQL.app/Contents/MacOS/AirSQL`.
