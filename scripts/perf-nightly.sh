#!/bin/bash
# The night's performance times (#4784): on a seeded scratch root on this Mac, the host's
# answers (scripts/perf-budgets.py), the window's cold start, first list, project switch and
# chat open (scripts/perf-window.sh), and the web page's first list, session open and long
# transcript (Web/test/walk/budgets.mjs), and the .perfBudget tests (scripts/perf-tests.sh), each against the `night` budgets in
# scripts/perf-budgets.json. A run over budget files a `feature:performance` issue with the
# numbers, or comments on the one still open. The Performance budgets workflow runs it.
#
#   scripts/perf-nightly.sh [--no-build] [--no-issue] [--keep]
#
# --keep leaves the scratch set-up up at the end, to look at; take it down with
# .agents/skills/run-app/scripts/stop.sh /tmp/run-perf-night.
#
# Run it on a quiet Mac, under the "build" lease: a time measured beside a build measures the
# build. It builds Agents (Debug) with run-app's launch.sh, unless --no-build, and takes the
# scratch set-up down at the end, also when a step fails. The report goes to
# ~/.agents/reviews/performance-nightly/<date>.md. The window's switches and chat opens need
# Accessibility permission for the process that runs this; without it only its cold start is
# timed. The phone on Wi-Fi and cellular is Alex's check (docs/how-to/performance-budgets.md).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUNAPP="$REPO/.agents/skills/run-app/scripts"
SLUG=perf-night
ROOT="/tmp/run-$SLUG"
BUILD=1
ISSUE=1
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --no-issue) ISSUE=0 ;;
    --keep) KEEP=1 ;;
    *) echo "usage: perf-nightly.sh [--no-build] [--no-issue] [--keep]" >&2; exit 2 ;;
  esac
done

# Not /tmp/run-*: stop.sh removes the files beside a root it stops.
OUT=$(mktemp -d /tmp/perfnight-out.XXXXXX)
REPORTS="$HOME/.agents/reviews/performance-nightly"
mkdir -p "$REPORTS"
DAY=$(date +%F)
REPORT="$REPORTS/$DAY.md"

# A set-up a run before left behind.
[ -e "$ROOT" ] && "$RUNAPP/stop.sh" "$ROOT" >/dev/null 2>&1
finish() { [ "$KEEP" = 1 ] || "$RUNAPP/stop.sh" "$ROOT" >/dev/null 2>&1 || true; rm -rf "$OUT"; }
trap finish EXIT

# The seeded root (perf-budgets.py's): 41 live sessions in `work`, a 100k-entry transcript among
# them, and one in `big`, a repository of 40,000 files.
mkdir -p "$ROOT/work"
git -C "$ROOT/work" init -q
python3 "$REPO/scripts/seed-big-repo.py" "$ROOT/big" >/dev/null || { echo "perf-nightly: seeding the big repo failed" >&2; exit 1; }
swift "$REPO/scripts/seed-archived.swift" --root "$ROOT" --live --count 40 --folder "$ROOT/work" --transcript-bytes 200000 >/dev/null
swift "$REPO/scripts/seed-archived.swift" --root "$ROOT" --live --count 1 --folder "$ROOT/big" >/dev/null
LONG=$(swift "$REPO/scripts/seed-archived.swift" --root "$ROOT" --live --count 1 --folder "$ROOT/work" --transcript-bytes 1000)
python3 "$REPO/scripts/seed-long-transcript.py" "$ROOT" "$LONG" 100000 >/dev/null
python3 - "$ROOT/agents/$LONG/agent.json" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
record["title"] = "Long transcript 100k"
json.dump(record, open(sys.argv[1], "w"))
PY

flags=(--slug "$SLUG" --seeded)
[ "$BUILD" = 1 ] || flags+=(--no-build)
"$RUNAPP/launch.sh" "${flags[@]}" >"$OUT/launch.txt" 2>&1 || { cat "$OUT/launch.txt" >&2; echo "perf-nightly: launch failed" >&2; exit 1; }
WEB_URL=$(sed -n 's/^WEB_URL=//p' "$OUT/launch.txt")
python3 "$RUNAPP/rpc.py" "$ROOT" call folders/add "{\"folder\": \"file://$ROOT/work\"}" >/dev/null
python3 "$RUNAPP/rpc.py" "$ROOT" call folders/add "{\"folder\": \"file://$ROOT/big\"}" >/dev/null
sleep 5

over=0
"$REPO/scripts/perf-budgets.py" "$ROOT" --markdown >"$OUT/host.md" 2>&1 || over=1
"$REPO/scripts/perf-window.sh" "$SLUG" work big "Seeded live agent 20" "Long transcript 100k" >"$OUT/mac.txt" 2>&1 || over=1
HOSTAPP="$REPO/build/DD/Build/Products/Debug/Agents.app"
CODE=$("$HOSTAPP/Contents/Helpers/agents-control" code --client --browser --home "$ROOT/control" 2>/dev/null | tail -1)
SESSION=$(grep -l '"Seeded live agent 20"' "$ROOT"/agents/*/agent.json | head -1 | xargs dirname | xargs basename)
HOSTID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["host"])' "$ROOT/control-host.json")
node "$REPO/Web/test/walk/budgets.mjs" "$ROOT" "$WEB_URL" "$CODE" "$HOSTID" "file://$ROOT/work/" "$SESSION" "$LONG" >"$OUT/web.txt" 2>&1 || over=1
# The tests marked .perfBudget (#225), held to their times only on a quiet Mac.
"$REPO/scripts/perf-tests.sh" >"$OUT/tests.txt" 2>&1 || over=1

{
  echo "# Performance budgets at night, $DAY"
  echo
  echo "On this Mac, on a seeded scratch root (41 live sessions, a 100k-entry transcript, a 40,000-file repository), at $(git -C "$REPO" rev-parse --short HEAD). Budgets: \`scripts/perf-budgets.json\` (#4784)."
  echo
  echo "## The host's answers"
  echo
  cat "$OUT/host.md"
  echo
  echo "## The Mac window"
  echo
  echo '```'
  cat "$OUT/mac.txt"
  echo '```'
  echo
  echo "## The web page"
  echo
  echo '```'
  cat "$OUT/web.txt"
  echo '```'
  echo
  echo "## The .perfBudget tests"
  echo
  echo '```'
  grep -E "perf-tests:|✘|✔ Test .*passed|failed|error:" "$OUT/tests.txt" | tail -40
  echo '```'
} >"$REPORT"
cat "$REPORT"

if [ "$over" = 1 ] && [ "$ISSUE" = 1 ]; then
  title="Performance budgets over at night"
  open=$(gh issue list --state open --label feature:performance --search "in:title \"$title\"" --json number --jq '.[0].number // empty')
  if [ -n "$open" ]; then
    gh issue comment "$open" --body-file "$REPORT" >/dev/null && echo "perf-nightly: commented on #$open"
  else
    body="$OUT/issue.md"
    { echo "The night's run (scripts/perf-nightly.sh, #4784) found a time over its budget, or one it could not measure. Each run while this is open adds its numbers below. Find the change that made it slower (\`git log\` since the last run under budget) and fix it, or, when the budget is wrong, change it in \`scripts/perf-budgets.json\` and say why."; echo; cat "$REPORT"; } >"$body"
    gh issue create --title "$title" --label feature:performance --label bug --label size:S --body-file "$body"
  fi
fi
exit "$over"
