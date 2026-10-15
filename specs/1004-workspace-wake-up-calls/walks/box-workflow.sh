#!/bin/bash
# The walk's workflow on the devbox (#1004): `box-workflow.sh ROOT HH:MM` adds ~/src/hello as a
# project on the box's host and gives it a workflow due once a day at HH:MM, approved;
# `box-workflow.sh ROOT check` prints the workflow's row as the host lists it.
set -euo pipefail
ROOT="$1"; WHAT="$2"
here="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$here/.claude/skills/test-servers/scripts"
FOLDER=file:///home/agents/src/hello
if [ "$WHAT" = check ]; then
  "$T/server-rpc.sh" "$ROOT" call workflows/list "{\"folder\":\"$FOLDER\"}"
  exit 0
fi
"$T/server-rpc.sh" "$ROOT" call projects/add "{\"folder\":\"$FOLDER\"}" >/dev/null || true
"$T/devbox.sh" ssh "mkdir -p ~/src/hello/.agents/workflows && printf -- '---\nname: Wake-up walk\non:\n  - schedule:\n      at: [\":${WHAT#*:}\"]\n      between: \"${WHAT%:*}:00-${WHAT%:*}:00\"\nagent: new\n---\n\nSay hello.\n' > ~/src/hello/.agents/workflows/wake-up-walk.md"
sleep 3
# Approved as the person would, with the digest it waits on (a file written after the host began).
DIGEST="$("$T/server-rpc.sh" "$ROOT" call workflows/list "{\"folder\":\"$FOLDER\"}" | python3 -c '
import json, re, sys
text = sys.stdin.read()
found = re.findall(r"\"awaitingApproval\"\s*:\s*\{[^}]*\"digest\"\s*:\s*\"([^\"]+)\"", text)
print(found[0] if found else "")')"
[ -z "$DIGEST" ] || "$T/server-rpc.sh" "$ROOT" call workflows/approve \
  "{\"folder\":\"$FOLDER\",\"workflowID\":\"wake-up-walk\",\"digest\":\"$DIGEST\"}"
"$T/server-rpc.sh" "$ROOT" call workflows/list "{\"folder\":\"$FOLDER\"}"
