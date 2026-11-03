#!/bin/bash
# Makes AirSQL's release (ported from AirSCP's scripts/release-local.sh): the universal app and its libmariadb signed
# with the Developer ID and the hardened runtime, notarized and stapled, as build/AirSQL-<version>.zip with
# build/AirSQL-<version>.zip.sha256, then checked the way Gatekeeper will; and next to it the exact source of that
# libmariadb (Connector/C's and OpenSSL's tarballs, as scripts/build-mariadb.sh checked them), which every release
# attaches (NOTICE).
#   scripts/release-local.sh               the Keychain's "Developer ID Application" identity, notarytool profile
#                                          airsql-notary
#   scripts/release-local.sh --adhoc       a dry run: ad hoc with the hardened runtime, not notarized (never for a
#                                          release)
#   scripts/release-local.sh --no-notarize the Developer ID signature without notarizing
# One-time setup: Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application, then
#   xcrun notarytool store-credentials airsql-notary --apple-id <Apple ID> --team-id <team ID>
# release.yml runs this too, with the identity in a temporary keychain and an App Store Connect API key instead of the
# profile (NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER). AIRSQL_SIGN_IDENTITY picks an identity by name,
# AIRSQL_NOTARY_PROFILE another notarytool profile (the same Apple account's AirSCP one works).
set -euo pipefail
cd "$(dirname "$0")/.."

adhoc=false notarize=true
case "${1:-}" in
    "") ;;
    --adhoc) adhoc=true notarize=false ;;
    --no-notarize) notarize=false ;;
    *) echo "usage: $0 [--adhoc | --no-notarize]" >&2; exit 2 ;;
esac
version=$(tr -d '[:space:]' < VERSION)
app=build/AirSQL.app
zip=build/AirSQL-$version.zip

# The hardened runtime's library validation loads only libraries signed by Apple or by the app's own team, and an ad
# hoc signature has no team: the dry run turns it off to start at all, so it proves everything but that check. The
# release needs no entitlements: libmariadb gets the app's Developer ID (docs/dev/release.md).
entitlements=()
if $adhoc; then
    identity=- timestamp=--timestamp=none
    plist=$(mktemp -t airsql-adhoc)
    trap 'rm -f "$plist"' EXIT
    cat > "$plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>
EOF
    entitlements=(--entitlements "$plist")
else
    identity=${AIRSQL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}
    if [ -z "$identity" ]; then
        echo "No \"Developer ID Application\" identity in the Keychain: see the top of $0 (--adhoc is a dry run" >&2
        echo "without one)." >&2
        exit 1
    fi
    timestamp=--timestamp
    notary=(--keychain-profile "${AIRSQL_NOTARY_PROFILE:-airsql-notary}")
    if [ -n "${NOTARY_KEY_ID:-}" ]; then notary=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"); fi
fi

./build.sh
# build.sh signs ad hoc for development; the release signs again with the hardened runtime, inside out: the library,
# then the app (--deep is for checking only).
codesign --force --options runtime "$timestamp" --sign "$identity" "$app/Contents/Frameworks/libmariadb.3.dylib"
codesign --force --options runtime "$timestamp" ${entitlements[@]+"${entitlements[@]}"} --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
# It starts and loads its libmariadb under that signature: dyld stops it before it prints when library validation
# refuses the library.
"$app/Contents/MacOS/AirSQL" --version | grep 'MariaDB Connector/C' \
    || { echo "The signed app doesn't start with its libmariadb (above)." >&2; exit 1; }

if $notarize; then
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    echo "Notarizing (a few minutes)..."
    result=$(xcrun notarytool submit "$zip" "${notary[@]}" --wait --output-format json)
    echo "$result"
    if ! grep -Eq '"status" *: *"Accepted"' <<< "$result"; then
        id=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' <<< "$result")
        [ -n "$id" ] && xcrun notarytool log "$id" "${notary[@]}" >&2
        echo "Notarization wasn't accepted (Apple's log above)." >&2
        exit 1
    fi
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=4 "$app"
fi

# The zip people download: the (stapled) app, with its signature intact; and the library's source next to it.
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
(cd build && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
cp vendor/out/source/*.tar.gz build/
if $adhoc; then
    echo "Built $zip: ad hoc with the hardened runtime (library validation off), NOT notarized: a dry run only."
elif ! $notarize; then
    echo "Built $app and $zip: Developer ID signed, NOT notarized (for checks only)."
else
    echo "Built $zip: Developer ID signed, notarized and stapled. SHA-256: $(cut -d' ' -f1 "$zip.sha256")"
    echo "Release it (docs/dev/release.md): gh release create v$version $zip $zip.sha256 --title \"AirSQL $version\" --notes-file <notes>"
fi
