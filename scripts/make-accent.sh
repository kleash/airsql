#!/bin/bash
# Compiles Resources/Assets.car: AirSQL's accent colour, which AppKit gives the app's ticks, radios, progress bars and
# selections unless the person chose an accent in System Settings. It holds only the two colours of `NSColor.accent`
# (Themes.swift). actool comes with Xcode, so the file is kept in the repository, as AppIcon.icns is, and only a change
# of colour needs this script.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
set_dir=$work/Assets.xcassets/AccentColor.colorset
mkdir -p "$set_dir"
echo '{"info":{"author":"xcode","version":1}}' > "$work/Assets.xcassets/Contents.json"
colour() { echo "{\"color\":{\"color-space\":\"srgb\",\"components\":{\"alpha\":\"1.000\",\"red\":\"$1\",\"green\":\"$2\",\"blue\":\"$3\"}},\"idiom\":\"universal\"$4}"; }
cat > "$set_dir/Contents.json" <<JSON
{"colors":[$(colour 0x0A 0x7F 0x91 ""),
$(colour 0x3F 0xB6 0xC8 ',"appearances":[{"appearance":"luminosity","value":"dark"}]')],
"info":{"author":"xcode","version":1}}
JSON
xcrun actool "$work/Assets.xcassets" --compile "$work" --platform macosx --minimum-deployment-target 13.1 \
    --accent-color AccentColor --output-partial-info-plist "$work/partial.plist" --output-format human-readable-text > /dev/null
cp "$work/Assets.car" Resources/Assets.car
