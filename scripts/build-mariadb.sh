#!/bin/bash
# Builds libmariadb, the MySQL and MariaDB client library AirSQL ships: MariaDB Connector/C over a static OpenSSL, as one
# universal dynamic library
#   vendor/out/universal/lib/libmariadb.3.dylib  (arm64 + x86_64, install name @rpath/libmariadb.3.dylib)
#   vendor/out/universal/include                 (Connector/C's headers; OpenSSL's in openssl/)
#   vendor/out/source/                           (Connector/C's and OpenSSL's source tarballs as built, for releases)
# The result is kept outside the repository in $AIRSQL_VENDOR_CACHE/<SHA-256 of this script> (default: the folder
# airsql-vendor-cache next to the main checkout, so every worktree shares it) and copied into vendor/out;
# vendor/out/stamp holds the SHA-256. build.sh and test.sh run this when the stamp isn't the current one. A script with other versions or
# options has another SHA-256 and builds again (a few minutes, and the internet the first time).
# Downloads (pinned versions, SHA-256 checked) are kept in $AIRSQL_VENDOR_CACHE/dl. Command Line Tools only: a portable
# CMake is downloaded too, and nothing from Homebrew (/opt/homebrew, /usr/local) is looked at.
set -euo pipefail
cd "$(dirname "$0")/.."

cmake_version=4.4.3
openssl_version=3.5.9
mariadb_version=3.4.11
# name, URL, SHA-256
downloads=(
    "cmake-$cmake_version-macos-universal.tar.gz"
    "https://github.com/Kitware/CMake/releases/download/v$cmake_version/cmake-$cmake_version-macos-universal.tar.gz"
    0c5d65251c14cc884bfa16bdbed3c263ce5bffe2e21c0d0d00962cb0610464fa
    "openssl-$openssl_version.tar.gz"
    "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz"
    603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
    "mariadb-connector-c-$mariadb_version-src.tar.gz"
    "https://archive.mariadb.org/connector-c-$mariadb_version/mariadb-connector-c-$mariadb_version-src.tar.gz"
    521c0712e9291fa96558df9e2ff431376a3a79329f13751896b694cae12765b4
)
archs=(arm64 x86_64)
# Package.swift's macOS 13: the linker warns about a library made for a newer macOS than the code that links it.
deployment_target=13.0
# Where the libraries are built to live. OpenSSL reads openssl.cnf and its default certificates there, and Connector/C
# looks there for plugins it doesn't have built in. /var/empty stays empty and only root can write to it, so no file
# can change the library's TLS or add a plugin. The builds install into a folder of their own (DESTDIR).
prefix=/var/empty/airsql
# The login plugins built into the library; every other plugin is left out.
plugins=(mysql_native_password caching_sha2_password sha256_password client_ed25519 mysql_clear_password dialog)

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CMAKE_PREFIX_PATH CPATH C_INCLUDE_PATH LIBRARY_PATH LDFLAGS CFLAGS CPPFLAGS
hash=$(shasum -a 256 scripts/build-mariadb.sh | cut -d' ' -f1)
# Next to the main checkout, also from a worktree (.claude/worktrees/<name>), so every worktree shares it.
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$PWD/.git")
base=${AIRSQL_VENDOR_CACHE:-$(dirname "$(dirname "$common")")/airsql-vendor-cache}
cache=$base/$hash
step() { echo "build-mariadb: $*"; }

# Copies this version's build from the cache into vendor/out.
use_cache() {
    mkdir -p vendor
    rm -rf "vendor/out.$$"
    cp -R "$cache" "vendor/out.$$"
    rm -rf vendor/out
    mv "vendor/out.$$" vendor/out
    step "vendor/out from $cache (Connector/C $mariadb_version, OpenSSL $openssl_version;" \
        "$(lipo -archs vendor/out/universal/lib/libmariadb.3.dylib))"
    exit 0
}
[ -f "$cache/stamp" ] && use_cache

jobs=$(sysctl -n hw.ncpu)
mkdir -p "$base/dl"
work=$(mktemp -d "$base/work.XXXXXX")
log=$work/logs
mkdir -p "$work/src" "$log"
# Runs a build step with its output in a log file; prints the end of the log if it fails.
logged() {
    local name=$1; shift
    if ! "$@" > "$log/$name.log" 2>&1; then
        tail -40 "$log/$name.log" >&2
        echo "build-mariadb: $name failed (log: $log/$name.log)" >&2
        exit 1
    fi
}

for ((i = 0; i < ${#downloads[@]}; i += 3)); do
    name=${downloads[i]} url=${downloads[i + 1]} sha=${downloads[i + 2]}
    file=$base/dl/$name
    if [ ! -f "$file" ] || [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sha" ]; then
        step "downloading $name"
        curl -fL --retry 3 --silent --show-error -o "$file.$$" "$url"
        mv "$file.$$" "$file"
    fi
    if [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sha" ]; then
        echo "build-mariadb: $name does not have the expected SHA-256 ($sha); not using it." >&2
        rm -f "$file"
        exit 1
    fi
    tar -xzf "$file" -C "$work/src"
done
cmake=$work/src/cmake-$cmake_version-macos-universal/CMake.app/Contents/bin/cmake
openssl_src=$work/src/openssl-$openssl_version
mariadb_src=$work/src/mariadb-connector-c-$mariadb_version-src

static=()
for plugin in "${plugins[@]}"; do
    static+=("-DCLIENT_PLUGIN_$(tr '[:lower:]' '[:upper:]' <<< "$plugin")=STATIC")
done

for arch in "${archs[@]}"; do
    stage=$work/stage/$arch
    lib=$stage$prefix/lib/libmariadb.3.dylib

    step "OpenSSL $openssl_version ($arch)"
    mkdir -p "$work/build/openssl-$arch"
    (cd "$work/build/openssl-$arch" &&
        logged "openssl-$arch-configure" perl "$openssl_src/Configure" "darwin64-$arch-cc" no-shared no-tests no-apps \
            no-docs no-legacy no-module no-dso no-engine no-ssl3 no-quic no-comp no-zlib --prefix="$prefix" \
            --openssldir="$prefix/ssl" --libdir=lib -mmacosx-version-min=$deployment_target &&
        logged "openssl-$arch-build" make -j"$jobs" &&
        logged "openssl-$arch-install" make install_sw DESTDIR="$stage")

    # Configuring compiles small checks and runs none (its LibreSSL probe doesn't compile against OpenSSL), so the
    # x86_64 build never runs x86_64 code. __FILE__ names the source without this build's folder. LOAD DATA LOCAL is
    # off unless a connection turns it on.
    step "Connector/C $mariadb_version ($arch)"
    logged "mariadb-$arch-configure" "$cmake" -S "$mariadb_src" -B "$work/build/mariadb-$arch" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-fmacro-prefix-map=$work/src/=" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_INSTALL_NAME_DIR=@rpath \
        -DINSTALL_LIBDIR=lib -DINSTALL_INCLUDEDIR=include \
        -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
        -DCMAKE_IGNORE_PATH="/opt/homebrew/bin;/opt/homebrew/lib;/opt/homebrew/include;/usr/local/bin;/usr/local/lib;/usr/local/include" \
        -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON \
        -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF \
        -DWITH_SSL=OPENSSL -DOPENSSL_ROOT_DIR="$stage$prefix" -DOPENSSL_USE_STATIC_LIBS=ON \
        -DWITH_EXTERNAL_ZLIB=ON \
        -DWITH_CURL=OFF -DWITH_UNIT_TESTS=OFF -DENABLED_LOCAL_INFILE=OFF \
        "${static[@]}" \
        -DCLIENT_PLUGIN_MYSQL_OLD_PASSWORD=OFF -DCLIENT_PLUGIN_PARSEC=OFF -DCLIENT_PLUGIN_AUTH_GSSAPI_CLIENT=OFF \
        -DCLIENT_PLUGIN_ZSTD=OFF -DCLIENT_PLUGIN_REMOTE_IO=OFF
    logged "mariadb-$arch-build" make -C "$work/build/mariadb-$arch" -j"$jobs"
    logged "mariadb-$arch-install" make -C "$work/build/mariadb-$arch" install DESTDIR="$stage"

    # The library as the app needs it: the @rpath install name, only macOS's own libraries (zlib, libSystem) besides
    # itself, and the login plugins inside (CMake ignores a misspelled plugin option without a word).
    id=$(otool -D "$lib" | tail -n 1)
    [ "$id" = @rpath/libmariadb.3.dylib ] || { echo "build-mariadb: libmariadb's install name is $id ($arch)" >&2; exit 1; }
    others=$(otool -L "$lib" | awk 'NR > 2 {print $1}' | grep -v -e '^/usr/lib/' -e '^/System/Library/' || true)
    [ -z "$others" ] || { echo "build-mariadb: libmariadb ($arch) links $others, which macOS doesn't have" >&2; exit 1; }
    symbols=$(nm "$lib")
    for plugin in "${plugins[@]}"; do
        grep -q " _${plugin}_client_plugin$" <<< "$symbols" ||
            { echo "build-mariadb: the $plugin plugin isn't built into libmariadb ($arch)" >&2; exit 1; }
    done
done

# Nothing from Homebrew may end up in the compiler or linker flags.
if grep -rl --include=flags.make --include=link.txt -e /opt/homebrew -e /usr/local "$work/build"; then
    echo "build-mariadb: the build picked up Homebrew files (see the files above); not using it." >&2
    exit 1
fi

result=$work/result
mkdir -p "$result/universal/lib" "$result/source"
lipo -create $(for arch in "${archs[@]}"; do echo "$work/stage/$arch$prefix/lib/libmariadb.3.dylib"; done) \
    -output "$result/universal/lib/libmariadb.3.dylib"
ln -s libmariadb.3.dylib "$result/universal/lib/libmariadb.dylib"
# Signed ad hoc as the linker signs, so the tests can load it from here; build.sh signs the app's copy again.
codesign --force --sign - "$result/universal/lib/libmariadb.3.dylib"
# The headers are the same for both architectures.
cp -R "$work/stage/${archs[0]}$prefix/include" "$result/universal/"
# The exact source of the library AirSQL ships (this script holds any patch): releases attach it.
cp "$base/dl/mariadb-connector-c-$mariadb_version-src.tar.gz" "$base/dl/openssl-$openssl_version.tar.gz" "$result/source/"
echo "$hash" > "$result/stamp"
# Another build of the same script may have finished first: then that one is used.
[ -d "$cache" ] || mv "$result" "$cache"
rm -rf "$work"
step "built $cache"
use_cache
