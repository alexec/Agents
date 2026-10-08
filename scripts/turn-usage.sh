#!/bin/zsh
# What every turn used, for every agent on this Mac, so a change to what agents are sent
# can be compared before and after on real agents (#465). Read only.
#
#   scripts/turn-usage.sh                 one line per runtime: turns and token totals
#   scripts/turn-usage.sh --since DATE    only turns recorded on or after DATE (2026-10-08)
#   scripts/turn-usage.sh --turns         one JSON line per turn instead
#
# Each turn's usage is the runtime's own report, read from the agents' transcripts, where
# the app has kept every one (`usageRecorded`); `turns.jsonl` carries the same per turn
# from #465 on. Shares are of all input: uncached + cache reads + cache writes.
# AGENTS_ROOT picks another store (a scratch root).
set -euo pipefail

root=${AGENTS_ROOT:-"$HOME/Library/Application Support/Agents"}
since=""
per_turn=0
while (( $# )); do
  case $1 in
    --since) since=$2; shift 2 ;;
    --turns) per_turn=1; shift ;;
    *) print -u2 "usage: $0 [--since YYYY-MM-DD] [--turns]"; exit 2 ;;
  esac
done

turns() {
  local runtime
  for dir in "$root"/agents/*/(N); do
    [[ -f $dir/transcript.jsonl ]] || continue
    runtime=$(jq -r '.runtimeID // "?"' "$dir/agent.json" 2>/dev/null || print '?')
    grep -h '"usageRecorded"' "$dir/transcript.jsonl" | jq -Rc \
      --arg runtime "$runtime" --arg agent "${${dir%/}:t}" --arg since "$since" '
      fromjson? // empty
      | select(.kind.usageRecorded and ($since == "" or .at >= $since))
      | .kind.usageRecorded._0 as $u
      | {agent: $agent, runtime: $runtime, at: .at,
         input: ($u.inputTokens // 0), output: ($u.outputTokens // 0),
         cachedRead: ($u.cachedReadTokens // 0), cachedWrite: ($u.cachedWriteTokens // 0)}' || true
  done
}

if (( per_turn )); then
  turns
  exit 0
fi

turns | jq -rs '
  def pct(a; b): if b > 0 then ((a * 1000 / b) | floor) / 10 else null end;
  group_by(.runtime)[]
  | {runtime: .[0].runtime, turns: length,
     input: (map(.input) | add), cachedRead: (map(.cachedRead) | add),
     cachedWrite: (map(.cachedWrite) | add), output: (map(.output) | add)}
  | (.input + .cachedRead + .cachedWrite) as $all
  | "\(.runtime)\tturns \(.turns)\tuncached \(.input)\tcache read \(.cachedRead) (\(pct(.cachedRead; $all))%)\tcache write \(.cachedWrite) (\(pct(.cachedWrite; $all))%)\toutput \(.output)\tper turn read \(.cachedRead / .turns | floor)"'
