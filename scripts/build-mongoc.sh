#!/bin/bash
# Builds libmongoc, the MongoDB client library AirSQL ships: mongo-c-driver's libmongoc and libbson over a static
# OpenSSL, linked into one universal dynamic library that exports only the driver's own API (and AirSQL's one helper
# below), so its OpenSSL can't clash with libmariadb's
#   vendor/mongoc/universal/lib/libmongoc2.dylib  (arm64 + x86_64, install name @rpath/libmongoc2.dylib)
#   vendor/mongoc/universal/include               (bson/ and mongoc/: the driver's headers)
#   vendor/mongoc/source/                         (the driver's and OpenSSL's source tarballs as built, for releases)
# Cached as scripts/build-mariadb.sh caches libmariadb: $AIRSQL_VENDOR_CACHE/mongoc-<SHA-256 of this script>, copied
# into vendor/mongoc, whose stamp holds the SHA-256; build.sh and test.sh run this when the stamp isn't the current one.
# CMake and OpenSSL are build-mariadb.sh's pins (checked below): the two libraries carry the same OpenSSL.
# No SASL (Kerberos), Snappy, zstd, AWS login or client-side encryption; zlib is macOS's; mongodb+srv uses macOS's
# resolver (libresolv).
set -euo pipefail
cd "$(dirname "$0")/.."

cmake_version=4.4.3
openssl_version=3.5.9
mongoc_version=2.5.8
# name, URL, SHA-256
downloads=(
    "cmake-$cmake_version-macos-universal.tar.gz"
    "https://github.com/Kitware/CMake/releases/download/v$cmake_version/cmake-$cmake_version-macos-universal.tar.gz"
    0c5d65251c14cc884bfa16bdbed3c263ce5bffe2e21c0d0d00962cb0610464fa
    "openssl-$openssl_version.tar.gz"
    "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz"
    603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
    "mongo-c-driver-$mongoc_version.tar.gz"
    "https://github.com/mongodb/mongo-c-driver/releases/download/$mongoc_version/mongo-c-driver-$mongoc_version.tar.gz"
    ea63ec9535f1a425b288b2d72ac3a57c7f3b5d606afde73ff532a175a0774f55
)
for pin in cmake_version openssl_version; do
    grep -qx "$pin=${!pin}" scripts/build-mariadb.sh ||
        { echo "build-mongoc: $pin isn't build-mariadb.sh's; give both scripts the same pins." >&2; exit 1; }
done
archs=(arm64 x86_64)
deployment_target=13.0
# As in build-mariadb.sh: OpenSSL's openssl.cnf and default certificates would be read from here, which stays empty.
prefix=/var/empty/airsql
lib_name=libmongoc2.dylib

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CMAKE_PREFIX_PATH CPATH C_INCLUDE_PATH LIBRARY_PATH LDFLAGS CFLAGS CPPFLAGS
hash=$(shasum -a 256 scripts/build-mongoc.sh | cut -d' ' -f1)
# Next to the main checkout, also from a worktree (.claude/worktrees/<name>), so every worktree shares it.
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$PWD/.git")
base=${AIRSQL_VENDOR_CACHE:-$(dirname "$(dirname "$common")")/airsql-vendor-cache}
cache=$base/mongoc-$hash
step() { echo "build-mongoc: $*"; }

use_cache() {
    mkdir -p vendor
    rm -rf "vendor/mongoc.$$"
    cp -R "$cache" "vendor/mongoc.$$"
    rm -rf vendor/mongoc
    mv "vendor/mongoc.$$" vendor/mongoc
    step "vendor/mongoc from $cache (mongo-c-driver $mongoc_version, OpenSSL $openssl_version;" \
        "$(lipo -archs vendor/mongoc/universal/lib/$lib_name))"
    exit 0
}
[ -f "$cache/stamp" ] && use_cache

jobs=$(sysctl -n hw.ncpu)
mkdir -p "$base/dl"
work=$(mktemp -d "$base/work.XXXXXX")
log=$work/logs
mkdir -p "$work/src" "$log"
logged() {
    local name=$1; shift
    if ! "$@" > "$log/$name.log" 2>&1; then
        tail -40 "$log/$name.log" >&2
        echo "build-mongoc: $name failed (log: $log/$name.log)" >&2
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
        echo "build-mongoc: $name does not have the expected SHA-256 ($sha); not using it." >&2
        rm -f "$file"
        exit 1
    fi
    tar -xzf "$file" -C "$work/src"
done
cmake=$work/src/cmake-$cmake_version-macos-universal/CMake.app/Contents/bin/cmake
openssl_src=$work/src/openssl-$openssl_version
mongoc_src=$work/src/mongo-c-driver-$mongoc_version

# libbson hides its symbols unless it is built as a dynamic library: built static here, its API must stay visible for
# the export list below.
sed -i '' '/^set(CMAKE_C_VISIBILITY_PRESET hidden)$/d' "$mongoc_src/src/libbson/CMakeLists.txt"
! grep -q 'CMAKE_C_VISIBILITY_PRESET hidden' "$mongoc_src/src/libbson/CMakeLists.txt" ||
    { echo "build-mongoc: libbson's visibility setting moved; update this script." >&2; exit 1; }

# AirSQL's helper, linked into the library: the certificates the server sent on a TLS stream, so AirSQL checks them
# with SecTrust against the member's name (peerChain in Sources/AirSQLCore/Mongo/MongoConnection.swift), as TLSCheck
# does for MySQL. The stream's TLS state is private to the driver; this builds against the driver's own private headers
# of this version.
cat > "$work/src/airsql_mongoc.c" <<'EOF'
#include <mongoc/mongoc.h>
#include <openssl/ssl.h>
#include <stdlib.h>
#include <string.h>
#include "mongoc-stream-tls-private.h"
#include "mongoc-stream-tls-openssl-private.h"

/* Fills `ders` and `lengths` with up to `max` certificates (DER, malloc'd: free each) the server sent on `stream`'s
   TLS, its own first; returns how many (those filled before memory ran out), or -1 when the stream has no finished
   TLS. */
__attribute__((visibility("default"))) int
airsql_mongoc_peer_chain(mongoc_stream_t *stream, unsigned char **ders, int *lengths, int max)
{
   mongoc_stream_tls_t *tls = (mongoc_stream_tls_t *)mongoc_stream_get_tls_stream(stream);
   if (!tls || !tls->ctx) {
      return -1;
   }
   SSL *ssl = NULL;
   BIO_get_ssl(((mongoc_stream_tls_openssl_t *)tls->ctx)->bio, &ssl);
   STACK_OF(X509) *chain = ssl ? SSL_get_peer_cert_chain(ssl) : NULL;
   if (!chain) {
      return -1;
   }
   int count = 0;
   for (int i = 0; i < sk_X509_num(chain) && count < max; i++) {
      unsigned char *der = NULL;
      int length = i2d_X509(sk_X509_value(chain, i), &der);
      if (length <= 0) {
         continue;
      }
      unsigned char *copy = malloc((size_t)length);
      if (copy) {
         memcpy(copy, der, (size_t)length);
      }
      OPENSSL_free(der);
      if (!copy) {
         break;
      }
      ders[count] = copy;
      lengths[count++] = length;
   }
   return count;
}
EOF
# What the library exports: the driver's API and the helper; OpenSSL and everything else stays inside.
printf '%s\n' '_bson_*' '_mongoc_*' '_airsql_mongoc_*' > "$work/exports"

for arch in "${archs[@]}"; do
    stage=$work/stage/$arch
    out=$work/out/$arch

    step "OpenSSL $openssl_version ($arch)"
    mkdir -p "$work/build/openssl-$arch"
    (cd "$work/build/openssl-$arch" &&
        logged "openssl-$arch-configure" perl "$openssl_src/Configure" "darwin64-$arch-cc" no-shared no-tests no-apps \
            no-docs no-legacy no-module no-dso no-engine no-ssl3 no-comp no-zlib --prefix="$prefix" \
            --openssldir="$prefix/ssl" --libdir=lib -mmacosx-version-min=$deployment_target &&
        logged "openssl-$arch-build" make -j"$jobs" &&
        logged "openssl-$arch-install" make install_sw DESTDIR="$stage")

    # Static libraries only: one dynamic library is linked below from them.
    step "mongo-c-driver $mongoc_version ($arch)"
    logged "mongoc-$arch-configure" "$cmake" -S "$mongoc_src" -B "$work/build/mongoc-$arch" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-fmacro-prefix-map=$work/src/=" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
        -DCMAKE_IGNORE_PATH="/opt/homebrew/bin;/opt/homebrew/lib;/opt/homebrew/include;/usr/local/bin;/usr/local/lib;/usr/local/include" \
        -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON \
        -DBUILD_VERSION=$mongoc_version \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_PIC=ON \
        -DENABLE_SSL=OPENSSL -DOPENSSL_ROOT_DIR="$stage$prefix" -DOPENSSL_USE_STATIC_LIBS=ON \
        -DENABLE_SASL=OFF -DENABLE_SNAPPY=OFF -DENABLE_ZSTD=OFF -DENABLE_ZLIB=SYSTEM \
        -DENABLE_CLIENT_SIDE_ENCRYPTION=OFF -DENABLE_MONGODB_AWS_AUTH=OFF -DENABLE_SRV=ON \
        -DUSE_BUNDLED_UTF8PROC=ON -DENABLE_SHM_COUNTERS=OFF -DMONGO_USE_LLD=OFF \
        -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_UNINSTALL=OFF -DENABLE_MAN_PAGES=OFF -DENABLE_HTML_DOCS=OFF
    logged "mongoc-$arch-build" make -C "$work/build/mongoc-$arch" -j"$jobs"
    logged "mongoc-$arch-install" make -C "$work/build/mongoc-$arch" install DESTDIR="$stage"

    include=$stage$prefix/include
    mkdir -p "$out/include"
    cp -R "$include"/bson-$mongoc_version/* "$include"/mongoc-$mongoc_version/* "$out/include/"
    # Compiled as the driver's own sources are, against its source tree.
    logged "helper-$arch" clang -c -O2 -arch "$arch" -mmacosx-version-min=$deployment_target -DMONGOC_STATIC \
        -DBSON_STATIC -DMONGOC_COMPILATION -DMCOMMON_NAME_PREFIX=_mongoc_mcommon \
        -I"$mongoc_src/src/libmongoc/src" -I"$mongoc_src/src/libmongoc/src/mongoc" -I"$mongoc_src/src/libbson/src" \
        -I"$mongoc_src/src/common/src" -I"$work/build/mongoc-$arch/src/libmongoc/src" \
        -I"$work/build/mongoc-$arch/src/libbson/src" -I"$work/build/mongoc-$arch/src/common/src" -I"$include" \
        -o "$work/build/airsql_mongoc-$arch.o" "$work/src/airsql_mongoc.c"
    lib=$out/$lib_name
    # Both archives carry common-oid.c.o, whose symbols have no per-library prefix: one copy goes.
    cp "$stage$prefix/lib/libbson2.a" "$work/build/libbson2-$arch.a"
    ar -d "$work/build/libbson2-$arch.a" common-oid.c.o
    logged "link-$arch" clang -dynamiclib -arch "$arch" -mmacosx-version-min=$deployment_target \
        -install_name "@rpath/$lib_name" -o "$lib" \
        -Wl,-force_load,"$stage$prefix/lib/libmongoc2.a" -Wl,-force_load,"$work/build/libbson2-$arch.a" \
        "$work/build/airsql_mongoc-$arch.o" "$stage$prefix/lib/libssl.a" "$stage$prefix/lib/libcrypto.a" \
        -lresolv -lz -Wl,-exported_symbols_list,"$work/exports" -Wl,-dead_strip

    # The library as the app needs it: the @rpath install name, only macOS's own libraries besides itself, and none of
    # OpenSSL's symbols exported (libmariadb exports its own copy's).
    id=$(otool -D "$lib" | tail -n 1)
    [ "$id" = "@rpath/$lib_name" ] || { echo "build-mongoc: the install name is $id ($arch)" >&2; exit 1; }
    others=$(otool -L "$lib" | awk 'NR > 2 {print $1}' | grep -v -e '^/usr/lib/' -e '^/System/Library/' || true)
    [ -z "$others" ] || { echo "build-mongoc: $lib_name ($arch) links $others, which macOS doesn't have" >&2; exit 1; }
    exported=$(nm -gU "$lib" | awk '{print $3}')
    leaked=$(grep -v -e '^_bson_' -e '^_mongoc_' -e '^_airsql_mongoc_' <<< "$exported" || true)
    [ -z "$leaked" ] || { echo "build-mongoc: $lib_name ($arch) exports $(head -5 <<< "$leaked")" >&2; exit 1; }
    for symbol in _mongoc_client_set_stream_initiator _mongoc_stream_tls_new_with_hostname _bson_new_from_json \
        _bson_as_relaxed_extended_json _airsql_mongoc_peer_chain; do
        grep -qx "$symbol" <<< "$exported" || { echo "build-mongoc: $symbol isn't exported ($arch)" >&2; exit 1; }
    done
done

if grep -rl --include=flags.make --include=link.txt -e /opt/homebrew -e /usr/local "$work/build"; then
    echo "build-mongoc: the build picked up Homebrew files (see the files above); not using it." >&2
    exit 1
fi

result=$work/result
mkdir -p "$result/universal/lib" "$result/source"
lipo -create $(for arch in "${archs[@]}"; do echo "$work/out/$arch/$lib_name"; done) \
    -output "$result/universal/lib/$lib_name"
codesign --force --sign - "$result/universal/lib/$lib_name"
cp -R "$work/out/${archs[0]}/include" "$result/universal/"
cp "$base/dl/mongo-c-driver-$mongoc_version.tar.gz" "$base/dl/openssl-$openssl_version.tar.gz" "$result/source/"
echo "$hash" > "$result/stamp"
[ -d "$cache" ] || mv "$result" "$cache"
rm -rf "$work"
step "built $cache"
use_cache
