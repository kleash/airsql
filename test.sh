#!/bin/bash
# Runs the Swift Testing suite. Command Line Tools have no XCTest and keep Testing.framework
# outside the default search paths, so point the compiler, linker and rpath at it.
# Extra arguments go to `swift test` (e.g. ./test.sh --filter DriverTests).
# AIRSQL_LAB=1 ./test.sh also runs the tests against the lab (the Compose project airsql-lab): as it runs when all of it
# does, else after testenv/up.sh, which only the main checkout runs (testenv/AGENT.md).
set -euo pipefail
cd "$(dirname "$0")"

version=$(swift --version 2>&1) || true
if [[ ! $version =~ Swift\ version\ ([0-9]+)[0-9.]* ]] || (( BASH_REMATCH[1] < 6 )); then
    echo "The tests use Swift Testing, which needs Swift 6 or later (this Mac has ${BASH_REMATCH[0]:-no Swift})." >&2
    echo "The app itself builds with Swift 5.9 or later: ./build.sh" >&2
    exit 1
fi
# libmariadb, as build.sh gets it: when vendor/out is missing or was made by another version of its script.
[ "$(cat vendor/out/stamp 2>/dev/null)" = "$(shasum -a 256 scripts/build-mariadb.sh | cut -d' ' -f1)" ] || scripts/build-mariadb.sh
# One lab serves every checkout: used as it is while every service of it runs, else started by testenv/up.sh (which
# refuses in a worktree).
if [[ ${AIRSQL_LAB:-} == 1 ]]; then
    docker=/Applications/Docker.app/Contents/Resources/bin/docker
    [[ -x $docker ]] || docker=docker
    lab=("$docker" compose -f testenv/docker-compose.yml)
    running=$("${lab[@]}" ps --services --status running 2>/dev/null | sort) || true
    [[ -n $running && $running == "$("${lab[@]}" config --services | sort)" ]] || testenv/up.sh
fi
clt=$(xcode-select -p)
fw=$clt/Library/Developer/Frameworks
il=$clt/Library/Developer/usr/lib
# The run must reach Swift Testing's last line ("✔/✘ Test run with N tests …"): an AppKit call that stops the main
# run loop once ended AirSCP's test process early with status 0, so tests after it never ran.
log=$(mktemp -t airsql-test)
trap 'rm -f "$log"' EXIT
status=0
swift test \
    -Xswiftc -F -Xswiftc "$fw" \
    -Xlinker -F -Xlinker "$fw" \
    -Xlinker -rpath -Xlinker "$fw" \
    -Xlinker -rpath -Xlinker "$il" \
    "$@" 2>&1 | tee "$log" || status=$?
if [[ $status == 0 && " $* " != *" list "* && " $* " != *" --list-tests "* ]] && ! grep -qE '^. Test run with [0-9]+ tests? ' "$log"; then
    echo "The test process ended before Swift Testing's summary: a test stopped it (see the last test that started above)." >&2
    status=1
fi
exit $status
