# Walk: US1 and US2 on the devbox (2026-10-12)

## Set-up

- **Control plane:** a scratch one from `run-app` (`launch.sh --slug w691 --lan --control-env
  AGENTS_WORKSPACE_COMMANDS=<debug workspace-commands>`), built from this branch.
- **Box:** the `agents-devbox` container from `test-servers`.
- **Driver:** `Walk691LiveTests`, as the Providers page and the strip would drive it. It pairs
  a window with a code and calls the same control methods.

```sh
AGENTS_WALK691_URL=$CONTROL_URL AGENTS_WALK691_HOME=$ROOT/control \
AGENTS_WALK691_TOOL="build/DD/Build/Products/Debug/Agents Host.app/Contents/Helpers/agents-control" \
scripts/build-cache.sh swift test --package-path Packages/ControlPlane --filter Walk691
```

## What happened

| Step | Seen |
|---|---|
| Add the box over ssh (`ssh://agents@127.0.0.1:2222`) | online in 0.5 s |
| Add a provider: docker preset, `agents-devbox`, ssh `agents@127.0.0.1 -p 2222` | checked and listed: `agents-devbox running` |
| Link to Workspace… | the row carries `workspace.workspaceName = agents-devbox` |
| `docker stop` outside Agents, then a list | the row says **stopped** within 0.5 s, `canStart` true |
| **Start**, pressed twice | one start: phases `provider` → `connecting` → `sshStart` |
| The box has no systemd, so agentsd stays down | at 2 minutes the control plane starts it over ssh; online at 121.9 s |
| **Stop** | **stopped** within 0.5 s |

`control.log` had:

```text
provider: added walk-691-docker-… (commands, preset docker), 1 workspaces
workspace: w691-devbox linked to walk-691-docker-…/agents-devbox
workspace: ssh start w691-devbox: ok
workspace: start w691-devbox (walk-691-docker-…/agents-devbox) by client …: ok in 121s
```

## Found and fixed on the way

The first run pressed **Stop** the moment the host showed online. The start's task was still
listing, and a press of the other kind was taken as joining it, so the Stop was dropped
without a word. Now:

- A start is done as soon as its host connects, before it lists again.
- A Stop while a start is under way (or a Start while a stop is) is refused: "devbox is
  starting. Stop it once it has started."

Tests: `stopWhileStartingIsRefusedNotDropped`, `stopTheMomentAStartedHostIsOnlineIsHeard`.

## The Mac's screens, on the scratch window

With `AGENTS_WALK691_KEEP=1` the walk stops with the box linked and stopped. Settings was opened
by accessibility presses on the scratch window's pid, which takes no focus.

- **Hosts** ([mac-hosts.png](mac-hosts.png)), as L2: "Stopped · Linux · arm64 · Agents dev ·
  Walk 691 Docker: agents-devbox", then "Stops after 30 minutes idle · Starts when used",
  with **Start** and `···`.
- **Providers** ([mac-providers.png](mac-providers.png)), as L3: the provider's card with
  "command provider · docker", when it was listed, and its workspace "linked to w691-devbox".
  The container shows Running here because something outside the walk had started it again
  (its restart policy is `unless-stopped`); the page lists afresh when it opens.

## Not walked here

- **The strip** on the Mac, Remote and web, and the Add Provider and Link sheets. A strip
  needs a chat or project on the stopped host, and the sheets need typing, which goes to
  whatever app is in front. They were built, and their tests and builds pass. The PR carries
  `needs-walk` for them.
- **Providers other than docker.** doctl, codespaces, coder and workstations are checked by
  their command lines only (`PresetTests`); none was run against a real account.
