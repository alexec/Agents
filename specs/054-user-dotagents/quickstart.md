# Quickstart: proving 054 works

Everything here runs on a scratch home. The real home is never laid out by these steps.

## 1. Unit and integration tests

```sh
cd Packages/AgentsKit && swift test --filter 'PersonalDotAgents|PersonalLayout'
```

Expected: every acceptance scenario in [spec.md](spec.md) US1–US4 passes against a temporary
home. `PersonalLayoutTests` also proves a scratch root with no `AGENTS_PERSONAL_HOME` changes
nothing in `$HOME` (SC-006) and that a reconcile over 100 skills takes under 50 ms (SC-005).

## 2. The runtimes see it: rerun the probe against the app's own layout

```sh
specs/054-user-dotagents/probe/run.sh setup
# lay out the scratch home with the built code, not by hand:
AGENTS_PERSONAL_HOME=/tmp/dotagents-probe/home <built agentsd> --root /tmp/054-root --lay-out-home-and-exit
for r in claude codex grok cursor copilot; do specs/054-user-dotagents/probe/run.sh $r; done
specs/054-user-dotagents/probe/run.sh clean
```

(`--lay-out-home-and-exit` is a test hook the tasks add. If it is not wanted, start the scratch
daemon and let it reconcile at start.)

Expected, as in research R1 pass 3: HERON-7 x1 for all five; OSPREY-3 x1 for all but Cursor.
`clean` removes the borrowed sign-ins.

## 3. Through the app itself (ACP, not the CLIs)

With the run-app skill, launch a scratch copy with `AGENTS_PERSONAL_HOME` set to the probe home
(and the probe's sign-in borrowing in the daemon's environment). Start one agent per installed
runtime in a scratch project and send the probe prompt from `probe/ask.txt`. Expected: the same
answers as step 2. This is what confirms the Claude ACP adapter loads user settings (R1 Limits).

## 4. Adoption and clashes

On the probe home, before laying out:

```sh
H=/tmp/dotagents-probe/home
mkdir -p $H/.claude/skills/mine $H/.claude/skills/heron-probe $H/.claude/skills/synced
echo x > $H/.claude/skills/mine/SKILL.md; echo y > $H/.claude/skills/heron-probe/SKILL.md
touch $H/.claude/skills/synced/.bucket-test
```

Lay out. Expected: `mine` moved to `~/.agents/skills/mine` and linked back; `heron-probe` (a
clash) left as a real folder in both places; `synced` untouched. Delete the `mine` link and lay
out again: it is not put back. Remove `~/.agents/skills/mine`: the record entry is dropped.

## 5. MCP servers and plugins reach each runtime (Stories 6, 7)

Automated: `swift test --filter 'SessionServers|MCPBridge|PersonalPlugins'` covers R10's order,
drops and capability filter, the bridge against a fixture stdio server (overlapping calls, 404
on a wrong bearer, route end kills the process), and the Codex fingerprint (unchanged → no add;
changed → add; gone → remove), with a fake `codex` on `PATH`.

Live, on the probe home laid out by the built code (step 2), plus `probe/run.sh setup-mcp` for
the plugin and servers. Put `heron-mcp` (stdio) and `egret-mcp` (http, served by
`probe/mcp-server.py egret-mcp --http 8799`) in `$H/.agents/mcp.json`. Then, on a scratch copy of
the app with `AGENTS_PERSONAL_HOME=$H`, start one agent per runtime and send
`probe/ask.txt`'s MCP question. Read `/tmp/dotagents-probe/log/mcp.log`, not the model's answer.
Expected:

- `heron-mcp` and `egret-mcp` logged `tools/list` for Claude, Codex, Grok, Cursor **and
  Copilot** (through the bridge);
- the plugin's `plover-mcp` logged for Claude, Codex (after the app's own `codex plugin add`)
  and Grok (sent in `mcpServers`);
- on Copilot, `finish_turn` ends the turn with an outcome: the app's own tools now reach
  Copilot through the bridge;
- after touching a file in the plugin, the next Codex start adds it again (`daemon.log`), and a
  second start with nothing changed does not.

Break `mcp.json` (remove a comma): an agent still starts on each runtime, without the personal
servers, and `daemon.log` names the problem without any value from the file.

## 6. Settings ▸ Shared

Gate first: Alex approves the wireframes in [look/](look/README.md) before any view code.

On the scratch copy from step 5, open Settings ▸ Shared and screenshot each page (overview,
Instructions, Skills, MCP servers, Plugins, Other files), then again with `mcp.json` broken. Expected:
each page matches its approved frame, with reach from the rule table: Copilot shows "through
the bridge" for stdio servers, Cursor and Copilot "no way in" for plugins, and Gemini "not
checked yet". No env or header value appears anywhere. Reveal in Finder and Edit open the right
file. On a scratch root without `AGENTS_PERSONAL_HOME`, the tab says the shared folder is off for
this copy of the app.
