#!/bin/bash
# Builds build/airsql.mcpb, the MCP bundle for Claude Desktop and other mcpb clients: mcpb/manifest.json and the
# plugin's launcher (it starts the installed AirSQL with --mcp), zipped with fixed dates so the same sources give the
# same file. No downloaded tool runs. Check the manifest after editing more than its version:
#   npx @anthropic-ai/mcpb validate mcpb/manifest.json
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(cat VERSION)
for file in mcpb/manifest.json plugins/airsql/.claude-plugin/plugin.json; do
    grep -q "\"version\": \"$version\"" "$file" || { echo "$file doesn't say version $version (VERSION)." >&2; exit 1; }
done
grep -q '"entry_point": "server/airsql-mcp"' mcpb/manifest.json || { echo "The manifest's entry_point moved." >&2; exit 1; }

out=build/mcpb
rm -rf "$out" build/airsql.mcpb
mkdir -p "$out/server"
cp mcpb/manifest.json "$out/"
cp plugins/airsql/scripts/airsql-mcp "$out/server/"
chmod 755 "$out/server/airsql-mcp"
(cd "$out" && touch -t 202001010000 manifest.json server server/airsql-mcp \
    && zip -X -9 -q ../airsql.mcpb manifest.json server/airsql-mcp)
shasum -a 256 build/airsql.mcpb | sed 's| build/| |' > build/airsql.mcpb.sha256
echo "build/airsql.mcpb ($(wc -c < build/airsql.mcpb | tr -d ' ') bytes): $(cut -d' ' -f1 build/airsql.mcpb.sha256)"
