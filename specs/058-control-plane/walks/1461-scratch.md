# Walk: the public control plane with scratch clients (#1461)

2026-10-18, 17:00–17:30 local (00:00–00:30 UTC), from `main` at 109634d6. The control plane is
the one the v0.5 lead put on the Google Cloud VM `agents-control` the same day:
https://control.agentloops.dev, with its views at https://views.agentloops.dev, and a Let's
Encrypt certificate. No pin. Alex's live control plane, window, host and devices were not used,
and nothing was moved.

## Set-up

- **Codes:** `agents-control code --client`, `--client --browser` and `--host [--command]`, run in
  the VM's control container over `gcloud compute ssh` with the lead's service account. No code
  went into a log or a file kept here.
- **Scratch Mac host:** the Debug `agentsd` from `build/DD` (Go), root `/tmp/run-w1461`,
  `AGENTS_MACHINE_ID=w1461-walk-mac`, started with `--control-code`. It joined as `facr1n7z`
  and served its local socket in the app group (#1118). The socket's name comes from the
  control plane's key, so it is not the live host's.
- **Scratch window:** the `AgentsStore` Debug build from `build/DD`, not copied: a public
  certificate needs no ATS exception. Opened behind with `AGENTS_CONTROL=<client code>`,
  `AGENTS_MACHINE_ID=w1461-walk-mac` and `--walk run-w1461`, driven with `walk.py`.
- **Linux host:** the `agents-devbox` container, joined with the shown command
  (`curl -fsSL https://control.agentloops.dev/v1/install.sh | sh -s -- '<host code>'`).
- **Browser:** headless Chrome with a throwaway profile, `Web/test/walk/public1461.mjs`. No
  certificate flags.
- **A view:** `specs/054-user-dotagents/probe/mcp-server.py walk1461 --http 18461 --apps` in the
  scratch project's `.agents/mcp.json`, approved with `mcp/approve`.

## Steps

| Step | Result |
|---|---|
| 1. Scratch Mac host and window paired; a Claude turn from the window | **Passed.** The window listed the host's project. New Session, *Reply with exactly the one word: cloud*: the agent answered `cloud` and finished ([mac-1-turn.png](1461-scratch/mac-1-turn.png)). |
| 2. The devbox joined as a host; a turn on it | **Passed, with a manual install.** The box joined as `wwuoi2ro` (*fa0f264816b5 joined the control plane.*). The control plane gave it no Claude: *This control plane offers no toolsets* (**#1495**, fixed here). The box had no Node, and with 840 MB free it could not take the toolset (it wants 800 MB free), so Node 24.21.0 (checksum from the toolset's manifest) and `claude-agent-acp` 0.81.2 went into `~/.local` by hand. After the host started again, the window offered Claude, asked to lend this Mac's sign-in ([mac-2-lend.png](1461-scratch/mac-2-lend.png)), and the turn answered `devbox` ([mac-3-devbox-turn.png](1461-scratch/mac-3-devbox-turn.png)). |
| 3. Headless Chrome by a browser code; a session and a turn; an MCP App view | **Passed.** The page at https://control.agentloops.dev asked for a code ([web-1-pairing.png](1461-scratch/web-1-pairing.png)), connected ([web-2-paired.png](1461-scratch/web-2-paired.png)), opened *Walk1461 weather*, asked *Show* for the view ([web-3-show-ask.png](1461-scratch/web-3-show-ask.png)) and drew it in a frame from `https://views.agentloops.dev/sandbox.html` ([web-4-view.png](1461-scratch/web-4-view.png)). A turn from the page answered `browser` ([web-5-turn.png](1461-scratch/web-5-turn.png)). No page errors. The view says *waiting*: the probe's view never sends `ui/initialize`, so the page sends it no result. That is the probe, not the page. |
| 4. The window's link to the control plane cut; this Mac's host still answers | **Passed.** The window's pairing was pointed at a loopback proxy of the walk's own (`https://127.0.0.1:18462`, pinned), which was then stopped. Only the window lost the control plane; the host and the control plane stayed up (`/healthz` 200). The strip said *Can't reach the control plane… This Mac's agents still work here*, and a turn on this Mac's host answered `local` over the local socket ([mac-5-cut-turn.png](1461-scratch/mac-5-cut-turn.png)). For some seconds after the host's record said `finished`, the window still drew the turn as running ([mac-4-cut-running.png](1461-scratch/mac-4-cut-running.png)); see #1497. |
| 5. Every scratch client and host forgotten | **Done.** The two Chrome clients with **Forget…** and the devbox with **Remove…** in the window's Settings ▸ Control plane ([mac-6-clients-forgotten.png](1461-scratch/mac-6-clients-forgotten.png), [mac-7-hosts-removed.png](1461-scratch/mac-7-hosts-removed.png)). Settings has no Remove for *This Mac*, so the scratch Mac host went with `agentsctl call hosts/remove`, then the window with `clients/forget`, then `agentsctl` itself with `clients/forgetSelf`. After: `agents-control hosts` and `clients` list nothing. |

## Failed or found

- **#1495: the public control plane gives servers no toolsets.** `compose.public.yaml` mounts
  only `/servers`; the control plane looks for `/toolsets`. Fixed in this PR: the compose file
  mounts `App/Resources/toolsets`, and `deploy/gcp/up.sh` copies it to the VM. The VM needs a new
  `up.sh` run to have it.
- **#1496: the Runtimes page and Settings say *This Mac's host isn't answering***
  ([mac-runtimes-not-answering.png](1461-scratch/mac-runtimes-not-answering.png)). The window's
  `client` is always the host `mac`; a Mac host that joined with a host code has another id.
- **#1497: the window opens a new local connection to this Mac's host every 10–30 s.** The host
  logged `local: window … connected` again and again for as long as the window ran, while `lsof`
  showed two local connections open all the time.
- **#1498: Settings ▸ Control plane shows a public control plane as a local one.** *Reachable away
  from home: Off… on this network only*, version `dev`, port 8791 ([mac-overview.png](1461-scratch/mac-overview.png)),
  and *Sign-in relay needs this Mac on the same network* on the server's row ([mac-hosts.png](1461-scratch/mac-hosts.png)).
- **The devbox's disk is almost full** (96 %, 840 MB free in the Colima VM's 20 GB). The window
  says so on the box's project. Not a fault of the app; nothing was deleted to make room.
- **The Linux host says version `0.1.0+1`.** `build-linux-agentsd.sh` takes the version from
  `project.yml` when it is not a release build. Not filed.
- **The proxy for step 4 did not carry the window's link:** the control plane did not let the
  window in through `127.0.0.1` (its origin check, most likely), so the cut was the "away at
  launch" case of #1481, not a cut while connected. Both are this window only.

## Afterwards

The window, the scratch host, the probe server and the proxy stopped by their pids;
`stop.sh /tmp/run-w1461` removed the root, the walk's folder and its defaults. On the box:
`devbox.sh fresh`, and the hand-installed Node and `claude-agent-acp` removed (873 MB free after).
`scripts/leak-check.sh` with the Mac's Claude access and refresh tokens: clean in the root and on
the box. The Chrome profiles and `/tmp/w1461` removed. The walk window's key in the login keychain
(`control-client-key.walk.run-w1461`) was not looked for.
