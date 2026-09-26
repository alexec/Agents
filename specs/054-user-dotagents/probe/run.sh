#!/bin/zsh
# The 054 runtime probe (research R1). Nothing in the real home is written.
#
#   run.sh setup            scratch home: one skill and AGENTS.md in ~/.agents, sign-ins borrowed
#   run.sh <runtime>        claude | codex | grok | cursor | copilot, headless, HOME=scratch
#   run.sh clean            delete the scratch home, and the sign-ins copied into it
#
# Links and candidate files for passes 2 and 3 are placed by hand under $P/home; see research.md.
P=/tmp/dotagents-probe; H=$P/home
REAL=$HOME
CX="$REAL/Library/Application Support/Agents/tools/codex/current/lib/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"

case $1 in
  setup)
    rm -rf $P; mkdir -p $H/.agents/skills/heron-probe $P/proj $H/.codex $H/.grok $H/.cursor $H/Library
    printf -- '---\nname: heron-probe\ndescription: A probe skill. Use when asked to name the heron probe word; the word is HERON-7.\n---\nThe heron probe word is HERON-7.\n' \
      > $H/.agents/skills/heron-probe/SKILL.md
    printf '# Personal instructions\n\nThe osprey probe word is OSPREY-3.\n' > $H/.agents/AGENTS.md
    cp $REAL/.codex/auth.json $H/.codex/; cp $REAL/.grok/auth.json $H/.grok/
    cp $REAL/.cursor/cli-config.json $REAL/.cursor/agent-cli-state.json $H/.cursor/
    ln -s $REAL/Library/Keychains $H/Library/Keychains
    (cd $P/proj && git init -q .)
    exit ;;
  clean) rm -rf $P; exit ;;
esac

Q="$(cat ${0:A:h}/ask.txt)"
TOK=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
GHT=$(gh auth token 2>/dev/null)
cd $P/proj
for v in ${(k)parameters[(I)CLAUDE*]} ANTHROPIC_BASE_URL; do unset $v; done
export HOME=$H
case $1 in
  claude)  CLAUDE_CODE_OAUTH_TOKEN=$TOK $REAL/.local/bin/claude -p "$Q" </dev/null ;;
  codex)   "$CX" exec --skip-git-repo-check "$Q" 2>&1 | tail -4 ;;
  grok)    $REAL/.local/bin/grok -p "$Q" ;;
  cursor)  $REAL/.local/bin/cursor-agent --trust -p "$Q" ;;
  copilot) GH_TOKEN=$GHT /opt/homebrew/bin/copilot -p "$Q" ;;
esac
