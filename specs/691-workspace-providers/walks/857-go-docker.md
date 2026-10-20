# Walk: the Docker provider on the Go control plane (#857, 2026-10-19)

The walk of 2026-10-13 ([857-real-providers.md](857-real-providers.md)) ran on the Swift control
plane. The Go control plane replaced it (#1137, #1314), and #960–#965 were fixed since. This walk
does the Docker part again, on Go, on all three clients.

| Part | Where | Result |
|---|---|---|
| 1. A misbehaving fake provider | `Go/internal/controlplane/providers/connection_test.go` | ported with the Go control plane; this branch adds the two cases it did not have (below) |
| 2. Docker, Mac window | Add Provider, Link to Workspace, Stop, Start on the Hosts row | walked. **Bug found and fixed here**: Start over ssh failed for a provider's `user@host -p N` |
| 2. Docker, web page | the strip's Start | walked: online in 125 s |
| 2. Docker, Remote | the strip's Start, in the walk simulator | walked: online in 121 s |
| 3. Codespaces | — | **not walked**: needs a real codespace (#864) |
| 4. DigitalOcean | — | **not walked**: needs a droplet and a doctl sign-in (#865) |

## Set-up

- **Control plane, host and window:** `run-app` (`launch.sh --slug w857g --lan`) from this branch,
  and the Linux hosts from `scripts/build-linux-agentsd.sh`. After the fix, the control plane was
  started again from `Go/out/darwin/agents-control`, built from the branch, on the same home.
  Nothing touched the live app.
- **The box:** a throwaway container from the devbox image,
  `docker run -d --name w857g-box -p 127.0.0.1:2224:22 agents-devbox`, joined with the command Add
  a Server shows. No volume and no sign-in, so no runtime can start there.
- **A session to put a strip on:** one synthetic record, "w857g seeded chat", made from the test
  fixture and copied into the box's `~/.agents-server/root/agents/`. No real record was copied.
- **ssh:** for the last Start, the control plane had `AGENTS_SSH_CONFIG` pointing at a config of
  the walk's own, with the box's key at port 2224. Nothing in `~/.ssh` was changed.
- **Driving:** the Mac window through its walk socket (`walk.py`, in process, no focus); the web
  page in headless Chrome (`Web/test/walk/cdp.mjs`, a throwaway profile); the Remote in the
  "Agents Walk" simulator (`remote.sh up … -- -pair`); Stop through the control plane's own call
  (`operator.mjs`), as the Mac's row makes it.

## Docker, on the Mac window

| Step | Seen |
|---|---|
| Settings ▸ Control plane ▸ Providers ▸ **Add Provider…** | kinds first: Docker Containers, DigitalOcean Droplets, GitHub Codespaces, Coder Workspaces, Google Cloud Workstations, Your commands, MCP server |
| **Docker Containers**: Name `Walk 857 Docker`, Containers `w857g-box`, ssh `agents@127.0.0.1 -p 2224`, **Add** | the card: "Walk 857 Docker · command provider · docker", "Listed 4:51 PM", and `w857g-box` "Running · not a host" with **Link to w857g-box** and **Add as Host…** ([shot](857-go-mac-providers.png)) |
| Hosts ▸ `···` on w857g-box ▸ **Link to Workspace…** | the sheet: "Walk 857 Docker" ▸ "w857g-box, Running", Start when used, Stop when idle After 30 minutes |
| **Link** | the row: "Walk 857 Docker: w857g-box", "Stops after 30 minutes idle · Starts when used", **Stop** |
| **Stop** | container `exited`; `stop … ok in 0s`; the row says "Stopped" with **Start** |
| **Start**, before the fix | "Starting" for 2 min, then at once: "w857g-box started, but its agentsd didn’t connect, and starting it over ssh failed. hostname contains invalid characters", with **Start** ([shot](857-go-mac-ssh-bug.png)) |
| **Start**, with the fix, key not known | at 2 min, at once: "… starting it over ssh failed. The server’s host key isn’t in your known_hosts. Add it over ssh to see the key and trust it." (#960's fix holds: no 8 more minutes, in words) |
| **Start**, with the fix, key known (through the control plane's call) | online in **123 s**: the container starts, and the control plane starts agentsd over ssh at 2 min (the devbox has no systemd) |

The walk tool's `set` only reaches a SwiftUI field's value when a key press follows: the first
Add kept the default name and no containers. `walk.py … set` then `key tab` did it.

The Dock quit the scratch window at 17:07, while the Mac was in use. The rest was walked with no
window on the screen.

## Docker, on the web page

| Step | Seen |
|---|---|
| Pair a browser code; unfold `w857g-box:chat`; open the seeded chat | its one message |
| **Stop** (the control plane's call) | in 3 s, the strip: "w857g-box is stopped. Agents there are paused until it starts." with **Start**; the sidebar keeps the chat (#962's fix holds), and its foot says the same with **Start** (#961's fix holds) ([shot](857-go-web-strip-stopped.png)) |
| **Start** on the strip | "Waiting for w857g-box to connect… 0:04", "… 1:35"; the strip went at **125 s**, and the chat stayed |

While the box was stopped, the sidebar also showed "No projects yet": the scratch Mac had no
projects, and that card counts only the hosts that are online (`EmptyProjects`). This is as
designed.

## Docker, on the Remote

| Step | Seen |
|---|---|
| Pair with `-pair`; tap `w857g-box:chat`, then the seeded chat | its one message |
| **Stop** (the control plane's call) | the strip: "w857g-box is stopped. Agents there are paused until it starts." with **Start** ([shot](857-go-remote-strip-stopped.png)) |
| **Start** on the strip | "Waiting for w857g-box to connect…"; the strip went at **126 s**; the control plane said `ok in 121s` |

## The misbehaving fake provider

The Swift `MisbehavingProviderTests` (PR #862) came across to Go with the control plane:
missing tool, missing or unknown contract, odd items, text that isn't JSON, a noisy stdout,
refusals, a hung start, a crash mid-start. Two cases #857 names had no test. This branch adds
them:

- **A tool dropped after the provider was added**: the call is answered in the provider's own
  words ("Unknown tool: workspace_stop"), the next Check names the tool that is gone, and List
  still works.
- **Two workspaces with the same id**: the second is now left out, and the contract says ids are
  unique in a list. Before, both were kept, and a link or a start by id took the first.

"Says running but never boots" is `TestAHostThatDoesNotConnectIsStartedOverSSHThenGivenUp`.

## Bug fixed in this branch

The Go control plane's ssh start gave ssh a provider's `agents@127.0.0.1 -p 2224` as one host
name. The Swift one turned it into `ssh://agents@127.0.0.1:2224` first; the port lost that step.
Every preset with an ssh field and a port (Docker, the command presets) could never start a host
that does not start agentsd on boot. Now the hook converts it, with a test.

## Left

- **Codespaces** end to end, now that #964 and #965 are fixed: needs a real codespace (#864).
- **DigitalOcean**: the doctl preset and the shipped `@digitalocean/mcp` map on a droplet (#865).

## Clean-up

The scratch set-up (`stop.sh`), the `w857g-box` container, the headless Chrome profiles and the
walk's ssh config were removed. The walk simulator was shut down, and is kept.
