#!/bin/bash
# Writes AirSQL's software bill of materials (SPDX 2.3, ported from AirSCP's scripts/sbom.sh): the third-party code the
# app ships, which is MariaDB Connector/C with OpenSSL linked into it statically, as scripts/build-mariadb.sh pins them
# (version, download, SHA-256), and mongo-c-driver (with the utf8proc it bundles) over its own static copy of that
# OpenSSL, as scripts/build-mongoc.sh pins it; the app links those libraries (Contents/Frameworks/libmariadb.3.dylib and
# libmongoc2.dylib) dynamically. AirSQL has no package-manager dependencies, and CMake only builds the libraries. The purls (pkg:git with the release tag) are
# what OSV-Scanner looks up in security.yml; the CPEs are for scanners that use NVD. security.yml writes one for each
# scan and release.yml attaches one to every release, so it always matches the pins.
#   scripts/sbom.sh [file]    (default: build/sbom.spdx.json)
# shellcheck disable=SC2154 # downloads, the versions and plugins are the build scripts' (the evals below)
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-build/sbom.spdx.json}
mkdir -p "$(dirname "$out")"

# The pins exactly as build-mariadb.sh and build-mongoc.sh define them: their lines from cmake_version= to the end of
# downloads=(…) (build-mongoc.sh checks that CMake's and OpenSSL's are the same), and the login plugins libmariadb builds
# in.
eval "$(sed -n '/^cmake_version=/,/^)/p' scripts/build-mariadb.sh)"
mariadb_downloads=("${downloads[@]}")
eval "$(sed -n '/^cmake_version=/,/^)/p' scripts/build-mongoc.sh)"
downloads+=("${mariadb_downloads[@]}")
eval "$(grep '^plugins=' scripts/build-mariadb.sh)"
for ((i = 0; i < ${#downloads[@]}; i += 3)); do
    case ${downloads[i]} in
        cmake-* | mariadb-connector-c-* | mongo-c-driver-* | openssl-*) ;;
        *) echo "sbom.sh: a build script downloads ${downloads[i]}, which this SBOM doesn't list yet: add it" >&2; exit 1 ;;
    esac
done
# The utf8proc that mongo-c-driver 2.5.8 bundles (its src/utf8proc-<version>), built in with USE_BUNDLED_UTF8PROC.
utf8proc_version=2.11.3
[ "$mongoc_version" = 2.5.8 ] ||
    { echo "sbom.sh: mongo-c-driver is $mongoc_version now: set utf8proc_version to the one it bundles" >&2; exit 1; }
# pin <file> <1 for its URL, 2 for its SHA-256>
pin() {
    local i
    for ((i = 0; i < ${#downloads[@]}; i += 3)); do
        if [ "${downloads[i]}" = "$1" ]; then echo "${downloads[i + $2]}"; return; fi
    done
    echo "sbom.sh: no build script downloads $1" >&2
    exit 1
}
version=$(tr -d '[:space:]' < VERSION)
mariadb_url=$(pin "mariadb-connector-c-$mariadb_version-src.tar.gz" 1)
mariadb_sha=$(pin "mariadb-connector-c-$mariadb_version-src.tar.gz" 2)
openssl_url=$(pin "openssl-$openssl_version.tar.gz" 1)
openssl_sha=$(pin "openssl-$openssl_version.tar.gz" 2)
mongoc_url=$(pin "mongo-c-driver-$mongoc_version.tar.gz" 1)
mongoc_sha=$(pin "mongo-c-driver-$mongoc_version.tar.gz" 2)

cat > "$out" <<EOF
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "AirSQL $version",
  "documentNamespace": "https://github.com/kleash/airsql/releases/download/v$version/sbom.spdx.json",
  "comment": "The third-party code AirSQL ships: MariaDB Connector/C with OpenSSL linked into it statically, one library (AirSQL.app/Contents/Frameworks/libmariadb.3.dylib), and mongo-c-driver (libmongoc and libbson, with its bundled utf8proc) with its own static copy of the same OpenSSL, hidden inside, another (AirSQL.app/Contents/Frameworks/libmongoc2.dylib); the app links both dynamically. They are built from these pinned, checksummed sources by scripts/build-mariadb.sh and scripts/build-mongoc.sh with CMake $cmake_version (a build tool, not shipped). The libraries link macOS's own zlib. AirSQL's own code is Swift, compiled with Apple's Swift toolchain (the release workflow uses the Command Line Tools') against the macOS 26 SDK and run on the Swift runtime that is part of macOS; it has no package-manager dependencies. Written by scripts/sbom.sh.",
  "creationInfo": {
    "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "creators": ["Tool: scripts/sbom.sh"]
  },
  "packages": [
    {
      "SPDXID": "SPDXRef-AirSQL",
      "name": "AirSQL",
      "versionInfo": "$version",
      "supplier": "Person: kleash",
      "downloadLocation": "https://github.com/kleash/airsql/releases/download/v$version/AirSQL-$version.zip",
      "homepage": "https://kleash.github.io/airsql/",
      "filesAnalyzed": false,
      "licenseConcluded": "Apache-2.0",
      "licenseDeclared": "Apache-2.0",
      "copyrightText": "Copyright 2026 kleash",
      "primaryPackagePurpose": "APPLICATION",
      "externalRefs": [
        {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "pkg:git/github.com/kleash/airsql@v$version"}
      ]
    },
    {
      "SPDXID": "SPDXRef-MariaDB-Connector-C",
      "name": "MariaDB Connector/C",
      "versionInfo": "$mariadb_version",
      "supplier": "Organization: MariaDB Corporation",
      "downloadLocation": "$mariadb_url",
      "homepage": "https://mariadb.com/kb/en/mariadb-connector-c/",
      "filesAnalyzed": false,
      "checksums": [{"algorithm": "SHA256", "checksumValue": "$mariadb_sha"}],
      "licenseConcluded": "LGPL-2.1-or-later",
      "licenseDeclared": "LGPL-2.1-or-later",
      "copyrightText": "Copyright MySQL AB, Monty Program AB, MariaDB Corporation AB and the other authors named in its source",
      "comment": "AirSQL uses it under the LGPL version 3, as its 'any later version' allows (NOTICE says why). Built in: the login plugins ${plugins[*]}; every other plugin and LOAD DATA LOCAL INFILE are left out (scripts/build-mariadb.sh). Every release attaches this source tarball.",
      "primaryPackagePurpose": "LIBRARY",
      "externalRefs": [
        {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "pkg:git/github.com/mariadb-corporation/mariadb-connector-c@v$mariadb_version"},
        {"referenceCategory": "SECURITY", "referenceType": "cpe23Type", "referenceLocator": "cpe:2.3:a:mariadb:connector\\\\/c:$mariadb_version:*:*:*:*:*:*:*"}
      ]
    },
    {
      "SPDXID": "SPDXRef-OpenSSL",
      "name": "OpenSSL",
      "versionInfo": "$openssl_version",
      "supplier": "Organization: OpenSSL",
      "downloadLocation": "$openssl_url",
      "homepage": "https://www.openssl.org",
      "filesAnalyzed": false,
      "checksums": [{"algorithm": "SHA256", "checksumValue": "$openssl_sha"}],
      "licenseConcluded": "Apache-2.0",
      "licenseDeclared": "Apache-2.0",
      "copyrightText": "Copyright The OpenSSL Project Authors",
      "comment": "libcrypto and libssl only, linked statically into Connector/C and, as a second, hidden copy, into libmongoc2 (no shared libraries, engines, modules or legacy algorithms; scripts/build-mariadb.sh and build-mongoc.sh). Every release attaches this source tarball.",
      "primaryPackagePurpose": "LIBRARY",
      "externalRefs": [
        {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "pkg:git/github.com/openssl/openssl@openssl-$openssl_version"},
        {"referenceCategory": "SECURITY", "referenceType": "cpe23Type", "referenceLocator": "cpe:2.3:a:openssl:openssl:$openssl_version:*:*:*:*:*:*:*"}
      ]
    },
    {
      "SPDXID": "SPDXRef-mongo-c-driver",
      "name": "mongo-c-driver",
      "versionInfo": "$mongoc_version",
      "supplier": "Organization: MongoDB, Inc.",
      "downloadLocation": "$mongoc_url",
      "homepage": "https://www.mongodb.com/docs/languages/c/c-driver/current/",
      "filesAnalyzed": false,
      "checksums": [{"algorithm": "SHA256", "checksumValue": "$mongoc_sha"}],
      "licenseConcluded": "Apache-2.0",
      "licenseDeclared": "Apache-2.0",
      "copyrightText": "Copyright MongoDB, Inc.",
      "comment": "libmongoc and libbson, linked from static builds into one library with OpenSSL hidden inside; no SASL, Snappy, zstd, AWS login or client-side encryption (scripts/build-mongoc.sh).",
      "primaryPackagePurpose": "LIBRARY",
      "externalRefs": [
        {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "pkg:git/github.com/mongodb/mongo-c-driver@$mongoc_version"},
        {"referenceCategory": "SECURITY", "referenceType": "cpe23Type", "referenceLocator": "cpe:2.3:a:mongodb:c_driver:$mongoc_version:*:*:*:*:*:*:*"}
      ]
    },
    {
      "SPDXID": "SPDXRef-utf8proc",
      "name": "utf8proc",
      "versionInfo": "$utf8proc_version",
      "supplier": "Organization: JuliaStrings",
      "downloadLocation": "$mongoc_url",
      "homepage": "https://github.com/JuliaStrings/utf8proc",
      "filesAnalyzed": false,
      "licenseConcluded": "MIT",
      "licenseDeclared": "MIT",
      "copyrightText": "Copyright Steven G. Johnson, Jiahao Chen, Tony Kelman, Jonas Fonseca and other contributors; Public Software Group e. V., Berlin, Germany",
      "comment": "The copy mongo-c-driver bundles (src/utf8proc-$utf8proc_version), built into libmongoc2.",
      "primaryPackagePurpose": "LIBRARY",
      "externalRefs": [
        {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "pkg:git/github.com/juliastrings/utf8proc@v$utf8proc_version"}
      ]
    }
  ],
  "relationships": [
    {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-AirSQL"},
    {"spdxElementId": "SPDXRef-AirSQL", "relationshipType": "DYNAMIC_LINK", "relatedSpdxElement": "SPDXRef-MariaDB-Connector-C"},
    {"spdxElementId": "SPDXRef-MariaDB-Connector-C", "relationshipType": "STATIC_LINK", "relatedSpdxElement": "SPDXRef-OpenSSL"},
    {"spdxElementId": "SPDXRef-AirSQL", "relationshipType": "DYNAMIC_LINK", "relatedSpdxElement": "SPDXRef-mongo-c-driver"},
    {"spdxElementId": "SPDXRef-mongo-c-driver", "relationshipType": "STATIC_LINK", "relatedSpdxElement": "SPDXRef-OpenSSL"},
    {"spdxElementId": "SPDXRef-mongo-c-driver", "relationshipType": "STATIC_LINK", "relatedSpdxElement": "SPDXRef-utf8proc"}
  ]
}
EOF
echo "sbom.sh: wrote $out (AirSQL $version: Connector/C $mariadb_version, OpenSSL $openssl_version," \
    "mongo-c-driver $mongoc_version, utf8proc $utf8proc_version)"
