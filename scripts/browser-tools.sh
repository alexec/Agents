#!/usr/bin/env bash
# Writes Go/internal/agentsd/browsertools.json: the tools that the pinned @playwright/mcp
# lists, with the flags agentsd starts it with (#3534). The `agents` server lists them from
# this file, so a session sees the browser tools before Node or Chromium is on the machine.
# Run it after a change to the pin in Go/internal/agentsd/browsertoolset/manifest.json;
# TestTheBrowserToolsMatchThePin fails until it is run.
#
# Needs Node and npm on this Mac. Usage: scripts/browser-tools.sh
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
manifest="$repo/Go/internal/agentsd/browsertoolset/manifest.json"
out="$repo/Go/internal/agentsd/browsertools.json"
version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["packageVersion"])' "$manifest")

work=$(mktemp -d "${TMPDIR:-/tmp}/browser-tools.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"
npm init -y >/dev/null
npm install --silent --no-audit --no-fund "@playwright/mcp@$version" >/dev/null

# The same flags as browserArgs in browsertools.go, with an endpoint nobody listens on:
# Playwright lists its tools without connecting.
{
	printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"browser-tools.sh","version":"1"}}}'
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
	printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
	sleep 5
} | node node_modules/@playwright/mcp/cli.js --cdp-endpoint ws://127.0.0.1:9/none --output-dir "$work/out" --file-paths absolute --no-webmcp >list.jsonl

python3 - "$version" "$out" <<'PY'
import json, sys
version, out = sys.argv[1], sys.argv[2]
tools = None
for line in open("list.jsonl"):
    m = json.loads(line)
    if m.get("id") == 2:
        tools = m["result"]["tools"]
if not tools:
    sys.exit("browser-tools.sh: Playwright listed no tools")
with open(out, "w") as f:
    json.dump({"package": "@playwright/mcp", "version": version, "tools": tools}, f, indent=1, ensure_ascii=False)
    f.write("\n")
print(f"browser-tools.sh: {len(tools)} tools from @playwright/mcp {version}")
PY
