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

## 1.0.0: what only the owner can do

Everything else is ready (the dry run, `scripts/release-local.sh --adhoc`, passes). As of 2026-11-04 the repository
has no Pages site, no secrets and no release, and `kleash/homebrew-tap` has no `Casks/airsql.rb`. In this order:

1. **GitHub Pages**: Settings ▸ Pages ▸ Build and deployment ▸ Deploy from a branch ▸ `main`, `/docs` ▸ Save (or
   `gh api -X POST repos/kleash/airsql/pages -f 'source[branch]=main' -f 'source[path]=/docs'`). After the first
   build (Actions ▸ pages-build-deployment), https://kleash.github.io/airsql/ is AirSQL Help: the Help menu, the
   README and the cask link there.
2. **Security settings**: private vulnerability reporting (SECURITY.md points to it) and Dependabot alerts on, in
   Settings ▸ Advanced Security, or `gh api -X PUT repos/kleash/airsql/private-vulnerability-reporting` and
   `gh api -X PUT repos/kleash/airsql/vulnerability-alerts`. Secret scanning and push protection are on already.
3. **Signing secrets**, so that CI signs and notarizes and a tag alone releases:
   ```sh
   # Keychain Access ▸ My Certificates ▸ "Developer ID Application: …" ▸ Export… as DeveloperID.p12, with a password
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12 -R kleash/airsql
   gh secret set DEVELOPER_ID_P12_PASSWORD -R kleash/airsql      # it asks for the password
   # App Store Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect API ▸ Team Keys ▸ + (access: Developer):
   # download AuthKey_<Key ID>.p8 (Apple offers it once), note the Key ID and the Issuer ID shown above the keys
   base64 -i AuthKey_<Key ID>.p8 | gh secret set NOTARY_KEY -R kleash/airsql
   gh secret set NOTARY_KEY_ID -R kleash/airsql --body <Key ID>
   gh secret set NOTARY_ISSUER -R kleash/airsql --body <Issuer ID>
   rm DeveloperID.p12                                            # keep the .p8 somewhere safe, offline
   ```
   Without them, the Mac signs instead: the notary profile in the table below, then step 6's second way.
4. **The tap's token**: github.com ▸ Settings ▸ Developer settings ▸ Fine-grained tokens ▸ Generate: repository
   access **Only `kleash/homebrew-tap`**, permission **Contents: Read and write**; then
   `gh secret set TAP_TOKEN -R kleash/airsql` and paste it. Without it, step 7 is by hand.
5. **The version**: `1.0.0` in `VERSION`, `mcpb/manifest.json` and `plugins/airsql/.claude-plugin/plugin.json`
   ("version"), and the bug form's placeholder (`.github/ISSUE_TEMPLATE/bug_report.yml`); drop "in development" from
   README.md, docs/index.md, AGENTS.md and CLAUDE.md; `scripts/llms.sh`; commit and push; wait until CI, CodeQL and
   Security are green on that commit (`gh run watch`).
6. **The tag**, which starts release.yml (scan, build, sign, notarize, check the zip, the release with its notes and
   files, the cask):
   ```sh
   git tag -a v1.0.0 -m "AirSQL 1.0.0" && git push origin v1.0.0
   gh run watch "$(gh run list -R kleash/airsql -w Release -L 1 --json databaseId -q '.[0].databaseId')"
   ```
   Without the signing secrets, on the Mac with the Developer ID (`gh release create` makes the tag; release.yml adds
   the rest, see Release below):
   ```sh
   scripts/release-local.sh
   gh release create v1.0.0 build/AirSQL-1.0.0.zip build/AirSQL-1.0.0.zip.sha256 --target main \
       --title "AirSQL 1.0.0" --generate-notes
   ```
7. **The cask**: with `TAP_TOKEN`, release.yml has written `Casks/airsql.rb` to `kleash/homebrew-tap`. Without it,
   copy the cask from the run's summary (Actions ▸ Release ▸ the run ▸ Summary) into the tap:
   ```sh
   gh repo clone kleash/homebrew-tap "$TMPDIR/tap" && cd "$TMPDIR/tap"
   pbpaste > Casks/airsql.rb                                     # the summary's cask, copied
   git add Casks/airsql.rb && git commit -m "AirSQL 1.0.0" && git push
   ```
8. **Check it from the outside**: the commands under "After" below, on a Mac that never built AirSQL if you can.

## One-time setup

| What | How |
|---|---|
| Developer ID certificate | Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application (the one AirSCP uses works). |
| Notary credentials on the Mac | `xcrun notarytool store-credentials airsql-notary --apple-id <Apple ID> --team-id <team ID>`, or another profile of the same Apple account: `AIRSQL_NOTARY_PROFILE=airscp-notary scripts/release-local.sh` |
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
