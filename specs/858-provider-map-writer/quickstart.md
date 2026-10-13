# Quickstart: walk Write It for Me

On a scratch set-up (run-app skill), never the real control plane. The steps need the default
runtime signed in on this Mac.

## By the socket (SC-001, SC-002)

`Walk858LiveTests` drives the control plane as the Add Provider sheet does. It presses Write It
for Me five times for each kind and gives each draft to Add:

- an MCP server whose tools don't follow the contract, `Packages/ControlPlane/Tests/Fixtures/walk858-mcp.py`
  (`machines-get`, `machine-on`, `machine-off`, items with `uid`, `label` and `power`). It needs
  the secret `TEST_TOKEN`, and puts its value in a tool description (SC-003);
- Your commands for `cws`, `Packages/ControlPlane/Tests/Fixtures/cws`, a stand-in CLI with
  `--help`, `list --json`, `start` and `stop`.

```sh
S=.claude/skills/run-app/scripts
eval "$($S/launch.sh --slug w858 --no-window \
  --control-env "PATH=$PWD/Packages/ControlPlane/Tests/Fixtures:/usr/bin:/bin:/usr/sbin:/sbin" \
  --control-env WALK858_LOG=/tmp/run-w858-calls.log)"
AGENTS_WALK858_URL=$CONTROL_URL AGENTS_WALK858_HOME=$ROOT/control \
AGENTS_WALK858_TOOL="$PWD/build/DD/Build/Products/Debug/Agents Host.app/Contents/Helpers/agents-control" \
scripts/build-cache.sh swift test --package-path Packages/ControlPlane --filter Walk858
grep -rl s3cret-value-858 $ROOT     # SC-003: only control/provider-secrets.json
$S/stop.sh $ROOT
```

A start or stop question is answered Don't; a check question Run Check. `WALK858_LOG` has each
`cws` run (a stdio server is given only its secrets, so the MCP server logs nothing).

## In the window (L10)

1. Launch the same set-up with the window. Settings ▸ Control plane ▸ Providers ▸ Add
   Provider… ▸ MCP server. Command `/usr/bin/python3`, argument the path of `walk858-mcp.py`.
   Add a secret `TEST_TOKEN` = `s3cret-value-858`.
2. Press **Write It for Me**. See the step line (L10b). Open Details….
3. See the draft fill the Tool map field and "✓ Listed 2: …" (L10d). Press **Add**. See the card
   list the two machines.
4. Your commands: CLI `cws`, Write It for Me. See `ran cws --help`, the Config editor, and
   "✓ Listed 2".
5. A start question (L10c) comes only when the agent asks to prove a start; Don't must call no
   `machine-on`.
