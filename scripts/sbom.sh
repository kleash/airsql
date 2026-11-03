#!/bin/bash
# Writes AirSQL's software bill of materials (SPDX 2.3, ported from AirSCP's scripts/sbom.sh): the third-party code the
# app ships, which is MariaDB Connector/C with OpenSSL linked into it statically, as scripts/build-mariadb.sh pins them
# (version, download, SHA-256); the app links that library (Contents/Frameworks/libmariadb.3.dylib) dynamically. AirSQL
# has no package-manager dependencies, and CMake only builds the library. The purls (pkg:git with the release tag) are
# what OSV-Scanner looks up in security.yml; the CPEs are for scanners that use NVD. security.yml writes one for each
# scan and release.yml attaches one to every release, so it always matches the pins.
#   scripts/sbom.sh [file]    (default: build/sbom.spdx.json)
# shellcheck disable=SC2154 # downloads, the versions and plugins are build-mariadb.sh's (the evals below)
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-build/sbom.spdx.json}
mkdir -p "$(dirname "$out")"

# The pins exactly as build-mariadb.sh defines them: its lines from cmake_version= to the end of downloads=(…), and
# the login plugins it builds in.
eval "$(sed -n '/^cmake_version=/,/^)/p' scripts/build-mariadb.sh)"
eval "$(grep '^plugins=' scripts/build-mariadb.sh)"
for ((i = 0; i < ${#downloads[@]}; i += 3)); do
    case ${downloads[i]} in
        cmake-* | mariadb-connector-c-* | openssl-*) ;;
        *) echo "sbom.sh: build-mariadb.sh downloads ${downloads[i]}, which this SBOM doesn't list yet: add it" >&2; exit 1 ;;
    esac
done
# pin <file> <1 for its URL, 2 for its SHA-256>
pin() {
    local i
    for ((i = 0; i < ${#downloads[@]}; i += 3)); do
        if [ "${downloads[i]}" = "$1" ]; then echo "${downloads[i + $2]}"; return; fi
    done
    echo "sbom.sh: build-mariadb.sh doesn't download $1" >&2
    exit 1
}
version=$(tr -d '[:space:]' < VERSION)
mariadb_url=$(pin "mariadb-connector-c-$mariadb_version-src.tar.gz" 1)
mariadb_sha=$(pin "mariadb-connector-c-$mariadb_version-src.tar.gz" 2)
openssl_url=$(pin "openssl-$openssl_version.tar.gz" 1)
openssl_sha=$(pin "openssl-$openssl_version.tar.gz" 2)

cat > "$out" <<EOF
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "AirSQL $version",
  "documentNamespace": "https://github.com/kleash/airsql/releases/download/v$version/sbom.spdx.json",
  "comment": "The third-party code AirSQL ships: MariaDB Connector/C with OpenSSL linked into it statically, one library (AirSQL.app/Contents/Frameworks/libmariadb.3.dylib) that the app links dynamically, built from these pinned, checksummed sources by scripts/build-mariadb.sh with CMake $cmake_version (a build tool, not shipped). The library links macOS's own zlib. AirSQL's own code is Swift, compiled with Apple's Swift toolchain (the release workflow uses the Command Line Tools') against the macOS 26 SDK and run on the Swift runtime that is part of macOS; it has no package-manager dependencies. Written by scripts/sbom.sh.",
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
      "comment": "libcrypto and libssl only, linked statically into Connector/C (no shared libraries, engines, modules or legacy algorithms; scripts/build-mariadb.sh). Every release attaches this source tarball.",
      "primaryPackagePurpose": "LIBRARY",
      "externalRefs": [
        {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "pkg:git/github.com/openssl/openssl@openssl-$openssl_version"},
        {"referenceCategory": "SECURITY", "referenceType": "cpe23Type", "referenceLocator": "cpe:2.3:a:openssl:openssl:$openssl_version:*:*:*:*:*:*:*"}
      ]
    }
  ],
  "relationships": [
    {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-AirSQL"},
    {"spdxElementId": "SPDXRef-AirSQL", "relationshipType": "DYNAMIC_LINK", "relatedSpdxElement": "SPDXRef-MariaDB-Connector-C"},
    {"spdxElementId": "SPDXRef-MariaDB-Connector-C", "relationshipType": "STATIC_LINK", "relatedSpdxElement": "SPDXRef-OpenSSL"}
  ]
}
EOF
echo "sbom.sh: wrote $out (AirSQL $version: Connector/C $mariadb_version, OpenSSL $openssl_version)"
