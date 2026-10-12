# Quickstart: walking workspace providers

This proves the P1 stories (US1, US2) end to end on a scratch set-up. Nothing here touches the
real control plane or Alex's droplets.

## Prerequisites

- **The devbox container**: `agents-devbox` from the `test-servers` skill (Colima + Docker,
  sshd on `127.0.0.1:2222`).
- **The command provider**, built with the "build" lease:
  `scripts/build-cache.sh swift build --package-path Packages/MCPServers --product workspace-commands`.
  Then point `AGENTS_WORKSPACE_COMMANDS` at its output (R5).
- **A scratch set-up**: from the `run-app` skill (scratch control plane, this Mac's host and the
  window).

## 1. The command provider alone

```sh
export WORKSPACE_COMMANDS_CONFIG='{"preset":"docker","containers":["agents-devbox"],"ssh":"alex@127.0.0.1 -p 2222"}'
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"workspaces_list","arguments":{}}}' \
  | "$AGENTS_WORKSPACE_COMMANDS"
```

**Expected**: `contract: 1` and one workspace, `agents-devbox`, with state `running` or
`stopped` to match `docker ps -a`.

## 2. Add the provider (US2)

On the scratch window, open Settings ▸ Control plane ▸ Providers ▸ Add Provider…. Choose
Commands, preset docker, container `agents-devbox`, ssh `alex@127.0.0.1 -p 2222`.

**Expected**:
- It is listed with one workspace, with the same state as docker reports.
- Adding a stdio server with no workspace tools (for example `ci-watcher`) is refused with
  "It has no workspaces_list, workspace_start or workspace_stop tool".

## 3. Link and Start (US1)

1. Add the devbox as a host (Add as Host…, or link an existing devbox host with Link to
   Workspace…).
2. Run `docker stop agents-devbox`, then Refresh.
3. **Expected**: the host row and a devbox chat's strip say **devbox is stopped** with
   **Start**, on the Mac, on the web page (`http://localhost:<scratch port>`) and, when it is
   paired, on the Remote.
4. Press **Start** on the web page.
5. **Expected**:
   - Every client shows **Starting devbox…**, then **Waiting for devbox to connect…**.
   - If agentsd isn't set to start on boot in the container, after 2 minutes the strip shows
     **starting it over ssh**.
   - The host then comes online and the strip goes away.
   - `control.log` has `workspace: start devbox … by client web-…: ok`.
6. Press **Start** twice quickly. **Expected**: one `docker start` in the provider's stderr.

## 4. Failure

Configure a workspace whose `start` is `false` (Custom commands).

**Expected**: the strip shows **Couldn't start …** with the command's stderr and **Start**.

## 5. Secrets

Add a Custom provider with a secret `TOKEN=hunter2` and a `start` of `test "$TOKEN" = hunter2`.

**Expected**:
- Start succeeds.
- `grep -r hunter2` over the scratch store, `control.log` and the web page's network log finds
  nothing.
- `provider-secrets.json` is mode 0600.

## Tests

```sh
scripts/build-cache.sh swift test --package-path Packages/MCPServers
scripts/build-cache.sh swift test --package-path Packages/ControlPlane --filter 'Provider|Workspace'
scripts/web.sh test
```
