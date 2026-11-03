#!/bin/bash
# Builds build/AirSQL.app with libmariadb in Contents/Frameworks, and signs both ad hoc.
#   ./build.sh            universal: arm64 + x86_64
#   ./build.sh --native   host architecture only (fast dev loop)
set -euo pipefail
cd "$(dirname "$0")"

archs=(arm64 x86_64)
for arg in "$@"; do
    case $arg in
        --native) archs=("$(uname -m)") ;;
        *) echo "usage: $0 [--native]" >&2; exit 2 ;;
    esac
done

version=$(tr -d '[:space:]' < VERSION)
app=build/AirSQL.app

# The macOS 26 SDK, as CI builds: the macOS 27 SDK's SwiftUI needs a macro plugin that only Xcode has (@State: "plugin
# for module 'SwiftUIMacros' not found"). The newest MacOSX26*.sdk of the developer folder in use or of the Command Line
# Tools; SDKROOT wins when it is set.
if [ -z "${SDKROOT:-}" ]; then
    dev=$(xcode-select -p)
    sdk=$(ls -d "$dev"/SDKs/MacOSX26*.sdk "$dev"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26*.sdk \
        /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -n 1 || true)
    if [ -n "$sdk" ]; then
        export SDKROOT=$sdk
    else
        echo "No macOS 26 SDK here: building with $(xcrun --show-sdk-path)." >&2
    fi
fi

# libmariadb, as scripts/build-mariadb.sh makes it: copied from the shared vendor cache (built there first when this
# version of the script hasn't been yet) when vendor/out is missing or was made by another version.
[ "$(cat vendor/out/stamp 2>/dev/null)" = "$(shasum -a 256 scripts/build-mariadb.sh | cut -d' ' -f1)" ] || scripts/build-mariadb.sh

# shortcut: the deprecated native build system, as in AirSCP's build.sh. SwiftPM 6.4's default (swiftbuild) records the
# deployment target as the SDK the app was built with (vtool -show-build), which turns on AppKit's behaviour for old
# apps. Move to swiftbuild (a --scratch-path per arch) once it records the real SDK.
flags=(--build-system native)
# `swift build --arch` needs Xcode's build system; per-triple builds + lipo work with CLT alone.
bins=()
for arch in "${archs[@]}"; do
    triple=$arch-apple-macosx13.1
    swift build -c release --triple "$triple" --product AirSQL "${flags[@]}"
    bins+=("$(swift build -c release --triple "$triple" "${flags[@]}" --show-bin-path)/AirSQL")
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
lipo -create "${bins[@]}" -output "$app/Contents/MacOS/AirSQL"
# The Swift driver also records its toolchain's folder, a path on the build machine where dyld would look for libmariadb
# before Contents/Frameworks: the app keeps only /usr/lib/swift and its own folders.
otool -l "$app/Contents/MacOS/AirSQL" | sed -n 's|^ *path \(/.*\) (offset [0-9]*)$|\1|p' | sort -u | while IFS= read -r rpath; do
    [ "$rpath" = /usr/lib/swift ] || install_name_tool -delete_rpath "$rpath" "$app/Contents/MacOS/AirSQL"
done
cp Resources/AirSQL-Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"  # scripts/make-icon.swift draws it
# The app finds it through its rpath, @executable_path/../Frameworks (Package.swift).
cp vendor/out/universal/lib/libmariadb.3.dylib "$app/Contents/Frameworks/"
# The libraries' licences, and NOTICE (it says how to use another build of libmariadb).
cp -R Resources/Licenses "$app/Contents/Resources/"
# What agents read through the guide tool and MCP's instructions.
cp Resources/AgentGuide.md "$app/Contents/Resources/"
cp NOTICE "$app/Contents/Resources/Licenses/NOTICE.txt"

# Inside out: the library, then the app.
codesign --force --sign - "$app/Contents/Frameworks/libmariadb.3.dylib"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app $version (${archs[*]})"
