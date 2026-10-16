# Go agentsd spike (#1125): how to test it

Every step uses scratch set-ups only: a scratch control plane, a scratch window, and the `agents-devbox` container. Nothing touches the live Agents Host or its control plane. The report is [report.md](report.md).

Run everything from the worktree `~/Agents/.agents/worktrees/do-spike-github-issue`.

## Before you start

- **Colima and the devbox:** `.claude/skills/test-servers/scripts/devbox.sh up`.
- **Go:** there is none on this Mac; `agentsd-go/go.sh` runs `go` in the `golang:1.25` image.
- **A scratch build of Agents Host and the window** in this worktree's `build/DD`. It is there already. To make it again: `.claude/skills/run-app/scripts/launch.sh --slug go1125 --lan` without `--no-build` (it takes the "build" lease).
- **Claude signed in on this Mac** (the Keychain). The Linux host borrows that sign-in; nothing has to be signed in on the box.
- **The toolsets on the box.** They are installed in `~/.agents-go/tools`. To install them again: `agentsd-go/devbox.sh tools`.

## A: the Go host on Linux, in the Mac window (stages 1, 2 and 4)

```sh
S=.claude/skills/run-app/scripts
CONTROL="build/DD/Build/Products/Debug/Agents Host.app/Contents/Helpers/agents-control"
$S/stop.sh /tmp/run-go1125 2>/dev/null       # the set-up the spike left running, if it is still there
eval "$($S/launch.sh --slug go1125 --lan --no-build --front)"
agentsd-go/devbox.sh join "$("$CONTROL" code --host --home $ROOT/control)"   # builds, copies, enrols
"$CONTROL" hosts --home $ROOT/control        # "devbox (Go)  Linux arm64  0.1.0-go"
```

In the scratch window (its title has `run-go1125`):
1. **The host.** "devbox (Go)" is listed under its own heading. Add a project from it: `/home/agents/src/hello`, then `/home/agents/src/go-stage4`.
2. **A Claude session** on the Go host, in `hello`: "Read the files here and say what this is, then run uname -a."
   - The first time, the window asks whether this Mac may lend its Claude sign-in to the server: say yes. That is today's lend flow; the Go host asks for it with `-32036`.
   - Watch the streamed text, the tool calls, the ending ("Finished") and the report line in the sidebar.
3. **A card.** "Write hi into hi.txt." The permission card shows in the window; Allow, and the turn goes on. Try Deny in another session.
4. **Stop.** "Run sleep 120", then Stop: the session ends Stopped.
5. **The app's tools.** "Use list_sessions, read_session on another session, then start_session to say pong." A new session appears and finishes.
6. **A terminal.** Control-` on the `hello` project: a shell on the box opens. Type `uname -a`. A second tab with "+".
7. **Files.** In a session's Files pane: browse, open README or `hi.txt`. An image, if you drop one in.
8. **Codex.** A Codex session in `hello`: "List the files with ls." The window lends this Mac's ChatGPT sign-in the same way.
9. **Workflows** (stage 4). The project `go-stage4` has `.agents/workflows/clock-check.md`, switched off at the moment.
   - The window should show it on the project's Workflows page, from `workflow/changed`. This page is the least sure: it was never looked at.
   - Run it by hand there. Its run calls the hosted `host_facts` tool: Allow the card, and the answer names the shared process's pid.
   - Switch it on: its `cron: "*/2 * * * *"` fires it every 2 minutes. Switch it off again afterwards: every run is a real turn.
10. **Landlock** (stage 4). `SANDBOX=1 agentsd-go/devbox.sh` restarts the Go host with every runtime under Landlock. Restarting drops the lent sign-in, and the window lends it again by itself. In `go-stage4`: "Use Bash to write inside.txt here and /home/agents/outside.txt." The first works and the second is "Permission denied". `agentsd-go/devbox.sh` (no `SANDBOX`) turns it off.

Without the screen, the same through the control plane:
```sh
GOOS=darwin agentsd-go/go.sh build -o out/agentsctl ./cmd/agentsctl   # into agentsd-go/out/
export AGENTSCTL=$ROOT/ctl.json
agentsd-go/out/agentsctl pair "$("$CONTROL" code --client --home $ROOT/control)"
agentsd-go/out/agentsctl hosts
agentsd-go/out/agentsctl turn -host <id> -cwd /home/agents/src/hello -allow "Say hello and run uname -a."
agentsd-go/out/agentsctl turn -host <id> -runtime codex -cwd /home/agents/src/hello -allow "ls"
agentsd-go/out/agentsctl call -host <id> workflows/run '{"folder":"file:///home/agents/src/go-stage4","workflowID":"clock-check"}'
agentsd-go/out/agentsctl watch -host <id>      # every notification the host sends
agentsd-go/devbox.sh log                       # the Go host's daemon.log on the box
```

## B: the schema-first wire (stage 3)

```sh
agentsd-go/schema/check.sh     # hold the "build" lease: the Swift part builds AgentsKitCore
```
It prints, for Go and for Swift: "Agent 196 found, 196 round-trip", "TranscriptEntry 108 found, 108 round-trip", and the same for the others. The Go host's records pass the schema check, and so does `tsc` on today's TypeScript types. `schema/gen.sh` makes the Go, Swift and TypeScript again from `daemon.schema.json`. `schema/bootstrap.sh` makes the schema again from today's `generated.ts`.

## C: the Go host as this Mac's own host (stage 5)

```sh
agentsd-go/mac.sh down go1125m 2>/dev/null   # the set-up the spike left running, if it is still there
agentsd-go/mac.sh up go1125m                 # control plane + Go host as `mac` + scratch window
```
In the window (its title has `run-go1125m`):
- **The host.** It is "This Mac (Go)".
- **A Claude session.** Add a project at `/private/tmp/run-go1125m/work`; `mkdir` it first, because the Go host takes any folder. Then a Claude session. It signs in through this Mac's Keychain, with no lend.
- **What is missing.** The pages that come from the Mac's own daemon (Activity, pins, events, leases, the Pool) are empty or say they failed: 19 Mac-only methods are not in the Go host.
- **sandbox-exec.** `mac.sh down`, then `mac.sh up go1125m --sandbox`. A write outside the work folder is refused.
- **Both hosts on one control plane.** `mac.sh up go1125m --lan`, then `agentsd-go/devbox.sh join "$("$CONTROL" code --host --home /tmp/run-go1125m/control)"`: the Go Mac host and the Go Linux host are both listed.

## Known not to work

- **No supervisor on the box.** A Go host that crashes stays down; the window then says "devbox (Go) is offline". `agentsd-go/devbox.sh` starts it again. One crash (a switched-off workflow firing) was found and fixed on 2026-10-16.

- **No lending from the Go Mac host.** It cannot lend its sign-in: `relay/grant` is not there. In A, the Swift Mac host lends.
- **No question forms.** Elicitations (Claude's AskUserQuestion, Codex's request_user_input) are not offered to the runtime, so no question card shows. What a runtime does instead was not tried.
- **The Files pane does not refresh by itself.** There is no `files/changed`.
- **No turn summaries.** `agents/turns` is empty, so a chat loads as one open turn. With a long chat that is slow, but it is right.
- **Lean records.** The Go host sends the whole agent every time, and sends every `agent/entry` to every channel. The window drops what it is not showing.
- **Restarts lose live state.** The lent sign-ins live in memory, so the window lends again after a restart. A turn that was running when the host stopped ends `daemonGone`; nothing is picked back up.
- **Hosted MCP.** No approval by digest; no restart of a crashed server; tools only (no resources or prompts).
- **Landlock and sandbox-exec.** The paths are fixed, not set per agent. No `sandboxFailure` record.
- **Workflows.** Only `new` mode, no queue, no cooldown, no approval. The event triggers are listed but never fire.
- **Toolsets.** They are installed by hand (`devbox.sh tools`), as nothing installs them on a control-plane host today.

## Clean up

```sh
$S/stop.sh /tmp/run-go1125; agentsd-go/mac.sh down go1125m; agentsd-go/devbox.sh stop
```
