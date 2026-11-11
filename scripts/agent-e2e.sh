#!/bin/bash
# Tier B of mongo-plan Phase 3's end-to-end test: a real agent (Claude Code, headless) answers the shop questions over
# AirSQL's MCP server, and its answers are compared with testenv/mongo/seed/shop-answers.json (docs/dev/agent-e2e.md).
# Opt-in, as it spends tokens: AIRSQL_AGENT_E2E=1 scripts/agent-e2e.sh. Needs the Mongo lab (testenv/mongo/up.sh).
# Builds the app, runs it on a throwaway store (its own HOME and AIRSQL_SUPPORT_DIR, so passwords stay in memory),
# with saved connections to the lab's standalone and to its replica set through the SOCKS proxy (agent access Schema +
# read), and kills it at the end. AIRSQL_E2E_TARGET=solo|rs|both picks where the questions go (default both),
# AIRSQL_E2E_MODEL the model (default haiku). Transcripts and summary.txt (a block per target): build/agent-e2e/.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${AIRSQL_AGENT_E2E:-}" != 1 ]; then echo "skipped: set AIRSQL_AGENT_E2E=1 (it spends tokens)"; exit 0; fi
if ! command -v claude >/dev/null; then echo "skipped: Claude Code (claude) isn't installed"; exit 0; fi
case ${AIRSQL_E2E_TARGET:-both} in solo | rs) targets=$AIRSQL_E2E_TARGET ;; both) targets="solo rs" ;;
    *) echo "AIRSQL_E2E_TARGET is solo, rs or both" >&2; exit 2 ;; esac

./build.sh --native
out="$PWD/build/agent-e2e"
rm -rf "$out" && mkdir -p "$out"
# Short: the agent socket's path must fit in 103 bytes.
scratch=$(mktemp -d /tmp/airsql-e2e.XXXXXX)
mkdir -p "$scratch/home" "$scratch/support"
app="$PWD/build/AirSQL.app/Contents/MacOS/AirSQL"
pid=""
finish() {
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    rm -rf "$scratch"
}
trap finish EXIT

# The lab CA, in the main checkout's testenv (one lab serves every worktree).
ca="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)/testenv/.certs/ca.pem"
cat > "$scratch/support/airsql.json" <<EOF
{"connections": [{"id": "$(uuidgen)", "name": "Shop lab", "engine": "mongodb", "host": "127.0.0.1", "port": 44370,
                  "user": "airsql", "tls": {"mode": "off"}, "agentAccess": "schemaRead"},
                 {"id": "$(uuidgen)", "name": "Shop lab RS", "engine": "mongodb", "host": "mongo-rs1", "port": 27017,
                  "replicaSet": "rs0", "user": "airsql", "route": "proxy",
                  "proxy": {"kind": "socks5", "host": "127.0.0.1", "port": 44310, "user": "airsql"},
                  "tls": {"mode": "verifyIdentity", "caFile": "$ca"}, "agentAccess": "schemaRead"}],
 "settings": {"agentsAllowed": true}}
EOF
cat > "$out/mcp.json" <<EOF
{"mcpServers": {"airsql": {"command": "$app", "args": ["--mcp"], "env": {"AIRSQL_SUPPORT_DIR": "$scratch/support"}}}}
EOF

HOME="$scratch/home" AIRSQL_SUPPORT_DIR="$scratch/support" "$app" >"$out/app.log" 2>&1 &
pid=$!
export AIRSQL_BIN="$app" AIRSQL_SUPPORT_DIR="$scratch/support" E2E_OUT="$out" E2E_ROOT="$PWD" E2E_CWD="$scratch/home"
export E2E_MODEL="${AIRSQL_E2E_MODEL:-haiku}"
status=0
for target in $targets; do
    E2E_TARGET=$target python3 -I scripts/agent-e2e.py connect
    E2E_TARGET=$target python3 -I scripts/agent-e2e.py run || status=1
done
exit $status
