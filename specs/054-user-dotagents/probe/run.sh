#!/bin/zsh
# The 054 runtime probe (research R1). Nothing in the real home is written.
#
#   run.sh setup            scratch home: one skill and AGENTS.md in ~/.agents, sign-ins borrowed
#   run.sh <runtime>        claude | codex | grok | cursor | copilot, headless, HOME=scratch
#   run.sh clean            delete the scratch home, and the sign-ins copied into it
#   run.sh setup-mcp        after setup: a personal plugin in ~/.agents/plugins, handed over the way
#                           each runtime could take it, and a server named `shared` in every
#                           runtime's own MCP config, to see who wins a clash (research R9)
#   run.sh install-plugins  after setup-mcp: `codex plugin add` and `copilot plugin install`
#   run.sh acp <runtime>    the same runtimes over ACP, as the app starts them: acp.py
#   run.sh acp-all          every runtime, one after another, results in $P/log/<runtime>.json
#   run.sh apps-setup       the #186 MCP Apps probe's own scratch home, /tmp/mcp-apps-probe
#   run.sh apps <runtime>   claude | codex | copilot | opencode over ACP with an MCP Apps tool: apps.py
#   run.sh apps-clean       delete the MCP Apps scratch home
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
  setup-mcp)
    S=${0:A:h}/mcp-server.py; PL=$H/.agents/plugins/heron-plugin
    mkdir -p $PL/.claude-plugin $PL/skills/plover-skill $PL/commands $H/.agents/.claude-plugin \
      $H/.cursor/plugins/local $H/.gemini/extensions $H/.copilot $H/.claude
    printf '{"name":"heron-plugin","version":"1.0.0","description":"The 054 probe plugin."}\n' > $PL/.claude-plugin/plugin.json
    printf -- '---\nname: plover-skill\ndescription: A plugin skill. Use when asked for the plover word; it is PLOVER-5.\n---\nThe plover word is PLOVER-5.\n' > $PL/skills/plover-skill/SKILL.md
    printf -- '---\ndescription: Say the plover command word, PLOVER-6.\n---\nSay PLOVER-6.\n' > $PL/commands/plover-cmd.md
    printf '{"mcpServers":{"plover-mcp":{"command":"python3","args":["%s","plover-mcp"]}}}\n' $S > $PL/.mcp.json
    printf '{"name":"heron-plugin","version":"1.0.0","mcpServers":{"plover-mcp":{"command":"python3","args":["%s","plover-mcp"]}}}\n' $S > $PL/gemini-extension.json
    # Codex finds ~/.agents/plugins/marketplace.json with the HOME folder as its root, so sources
    # start ./.agents; Copilot is added at ~ and looks for .claude-plugin/marketplace.json there.
    printf '{"name":"personal","owner":{"name":"probe"},"plugins":[{"name":"heron-plugin","source":"./.agents/plugins/heron-plugin"}]}\n' > $H/.agents/plugins/marketplace.json
    mkdir -p $H/.claude-plugin; ln -sf ../.agents/plugins/marketplace.json $H/.claude-plugin/marketplace.json
    ln -sf ../../../.agents/plugins/heron-plugin $H/.cursor/plugins/local/heron-plugin
    ln -sf ../../.agents/plugins/heron-plugin $H/.gemini/extensions/heron-plugin
    # `shared` in each runtime's own config, tagged so the log says which copy started.
    J='{"mcpServers":{"shared":{"command":"python3","args":["'$S'","shared-from-own-config"]}}}'
    for f in .claude.json .cursor/mcp.json .copilot/mcp-config.json .gemini/settings.json; do print -r -- $J > $H/$f; done
    printf '\n[mcp_servers.shared]\ncommand = "python3"\nargs = ["%s", "shared-from-own-config"]\n' $S >> $H/.codex/config.toml
    exit ;;
  install-plugins)  # the one-time installs Codex and Copilot need (research R9); writes their config
    export HOME=$H GH_TOKEN=$(gh auth token 2>/dev/null)
    "$CX" plugin add heron-plugin@personal
    /opt/homebrew/bin/copilot plugin marketplace add $H && /opt/homebrew/bin/copilot plugin install heron-plugin@personal
    exit ;;
  acp)
    for v in ${(k)parameters[(I)CLAUDE*]} ANTHROPIC_BASE_URL; do unset $v; done
    export CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
    export GH_TOKEN=$(gh auth token 2>/dev/null) PROBE_REAL_HOME=$REAL npm_config_cache=$REAL/.npm HOME=$H
    exec python3 ${0:A:h}/acp.py $2 $3 ;;
  acp-all)
    for r in claude grok copilot cursor codex gemini; do $0 acp $r > $P/log/$r.json 2>&1; sleep 3; done
    exit ;;
  apps-setup)  # its own scratch home, so the 054 one is left as it is
    A=/tmp/mcp-apps-probe; rm -rf $A; mkdir -p $A/home/.codex $A/home/Library $A/proj $A/log
    cp $REAL/.codex/auth.json $A/home/.codex/
    (cd $A/proj && git init -q .)
    exit ;;
  apps)
    for v in ${(k)parameters[(I)CLAUDE*]} ANTHROPIC_BASE_URL; do unset $v; done
    export CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
    export GH_TOKEN=$(gh auth token 2>/dev/null) PROBE_REAL_HOME=$REAL npm_config_cache=$REAL/.npm HOME=/tmp/mcp-apps-probe/home
    exec python3 ${0:A:h}/apps.py $2 ;;
  apps-clean) rm -rf /tmp/mcp-apps-probe; exit ;;
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
