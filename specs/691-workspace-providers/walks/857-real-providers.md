# Walk: workspace providers for real (#857, 2026-10-13)

What #857 asked for, and where each part stands:

| Part | Where | Result |
|---|---|---|
| 1. A misbehaving fake provider | `MisbehavingProviderTests` (PR #862, merged) | done before this walk |
| 2. Docker through the window | Mac window and web page, below | walked; Start fails without a known host key (#960), and the sidebar and the web lose a stopped box (#961, #962, #963) |
| 2. Docker on the Remote | — | **not walked**: no Simulator GUI here, and pairing Alex's iPhone or iPad with a scratch control plane takes it off the real one. The Remote's strip (`R/Chat/HostOfflineStrip.swift`) shares the words (`S/OfflineWords.swift`) and the control call (`hosts/start`) walked here |
| 3. Codespaces | control calls, below | walked with a real codespace; see its findings |
| 4. DigitalOcean | — | **left for later**: Alex chose to skip it (no doctl sign-in) |

## Set-up

- **Control plane, host and window:** a scratch set-up from `run-app`
  (`launch.sh --slug w857b --lan`), built from main at 8f82c766d, with the Linux hosts from
  `scripts/build-linux-agentsd.sh`. Nothing touched the live app.
- **The box:** a throwaway container from the devbox image,
  `docker run -d --name w857-box --hostname w857-box -p 127.0.0.1:2224:22 agents-devbox`, joined
  with the command Add a Server shows. No volume, so no Claude sign-in: no runtime can start there.
- **Driving:** the Mac window by accessibility presses on its pid (`button.swift`, `menu.swift`,
  `ui.swift`), text typed as key events posted to the pid only; the web page in headless Chrome
  (`Web/test/walk/cdp.mjs`, a throwaway profile); the Codespaces part through the control plane's
  own calls as the window makes them (`Web/test/walk/operator.mjs`), because the Mac locked.
- **A session to put a strip on:** one synthetic record ("w857 seeded chat") written into the box's
  `~/.agents-server/root/agents/`, made from the test fixture as `rp-seed.py` does. No real record
  was copied.
- **ssh:** after the first Start (below), the control plane was restarted with
  `AGENTS_SSH_CONFIG` pointing at a config of the walk's own: the box's port with the devbox
  `known_hosts`, and the codespace's entry from `gh codespace ssh --config`. Nothing in `~/.ssh`
  was changed by hand.

## Docker, on the Mac window

| Step | Seen |
|---|---|
| Settings ▸ Control plane ▸ Providers ▸ **Add Provider…** | kinds first: Docker, DigitalOcean, Codespaces, Coder, Workstations, Your commands, MCP server |
| **Docker**: Name `Walk 857 Docker`, Containers `w857-box`, ssh `agents@127.0.0.1 -p 2224`, **Add** | the card: "Walk 857 Docker · command provider · docker", "Listed 3:18 PM", and `w857-box` "Running · not a host" with **Add as Host…** |
| Hosts ▸ `···` on w857-box ▸ **Link to Workspace…** | the sheet lists "Walk 857 Docker" ▸ "w857-box, Running", Start when used, Stop when idle After 30 minutes |
| **Link** | the row: "Linux · arm64 · Agents dev · Walk 857 Docker: w857-box", "Stops after 30 minutes idle · Starts when used", **Stop** |
| **Stop** | container `exited` in 2 s; `stop … ok in 0s` |
| Main window, the box's chat | greyed, no strip; the sidebar foot says "w857-box is offline" (**#961**) |
| **Start** on the Hosts row, host key unknown | "Starting…" with a spinner. At 2 min `ssh start w857-box: failed: hostKeyUnknown`, then 8 more minutes of "Starting…", then `didn't connect in 10 minutes` (**#960**) |
| After that | container running, agentsd down; the row says Offline with only **Stop**: no way to try again but Stop, then Start (on #960) |
| **Stop**, **Start** again, key known | online in **123 s**: the container starts, agentsd stays down (no systemd), and the control plane starts it over ssh at 2 min |
| With a session there: **Stop**, then open the session | the strip: "w857-box is stopped. Agents there are paused until it starts." with **Start** and **Try now**; and an alert "Could not finish that / closed", with "This chat's history did not load: closed" (**#963**) |

`control.log`:

```text
provider: added walk-857-docker-sv1j (commands, preset docker), 1 workspaces
workspace: w857-box linked to walk-857-docker-sv1j/w857-box
workspace: stop w857-box (walk-857-docker-sv1j/w857-box) by client aa0de4c0: ok in 0s
workspace: ssh start w857-box: failed: hostKeyUnknown
workspace: start w857-box (walk-857-docker-sv1j/w857-box) by client aa0de4c0: failed: didn't connect in 10 minutes
…
workspace: ssh start w857-box: ok
workspace: start w857-box (walk-857-docker-sv1j/w857-box) by client aa0de4c0: ok in 123s
```

## Docker, on the web page

| Step | Seen |
|---|---|
| Pair a browser code, New Session in `w857-box:chat` | "No runtime can start on this host." (the box has no sign-in), so the seeded session stands in |
| The seeded session, box online | title "w857 seeded chat", its one message, Pin, Archive |
| Box stopped from the Mac | the strip: "w857-box is stopped. Agents there are paused until it starts." with **Start**; the history line is worded ("That host is offline. What's shown is from when it was last heard."). But the sidebar says **No projects yet**, the header says **New session**, and the foot "w857-box is offline" (**#962**, **#961**) |
| **Start** on the strip | "Waiting for w857-box to connect… 0:03", "… 0:43", "… 1:43"; online in **121 s**, the strip gone and the history loaded |

## Codespaces

A throwaway private repo `alexec/w857-codespace` and one `basicLinux32gb` (2-core) codespace,
`w857cs`, both made for the walk and deleted after. The Mac locked, so the window's calls were
made through `operator.mjs`, as the Providers page makes them.

| Step | Seen |
|---|---|
| `providers/add` Codespaces, repo `alexec/w857-codespace` | listed in 386 ms: `w857cs`, state from gh's "Shutdown" read as **stopped**, `tunnel: true` |
| `hosts/install` to `cs.w857cs-….main` (gh's ssh entry), tunnel on | **"ssh failed without saying why."**, running or not (**#964**: gh's `LogLevel quiet` hides "Host key verification failed") |
| The same with `LogLevel quiet` taken out of the walk's config | `needsTrust` with the fingerprint; trusted, the install ran, "tunnel to w857cs: up", and the host joined in **about 65 s** as Linux x86-64 |
| `hosts/link` | linked; the row said the workspace was **stopped** with Start, while the host was online (the list was from before the install woke it) |
| `hosts/stop` | Shutdown, `stop … ok in 41s`; the tunnel went down with it |
| `hosts/start` | the codespace was Available and the tunnel up within a minute, but agentsd did not come back (no systemd: PID 1 is `docker-init`). At 10 min: "…the provider gives no ssh destination to start it with. Make agentsd start on boot (loginctl enable-linger)." The window's Codespaces form has no ssh field (**#965**) |
| `providers/update` with `ssh: cs.w857cs-….main`, Stop, Start | `ssh start w857cs: failed: hostKeyUnknown` at 2 min, then the 10-minute give-up. The key trusted at install isn't kept anywhere the ssh start reads (**#965**) |

So for a codespace, Stop works. Start boots the codespace but never brings its host back.

## Shots

[857-mac-add-docker.png](857-mac-add-docker.png) (Add Docker, filled),
[857-mac-hosts-linked.png](857-mac-hosts-linked.png) (the linked row),
[857-mac-strip-stopped.png](857-mac-strip-stopped.png) (the Mac strip and the "closed" alert),
[857-web-strip-stopped.png](857-web-strip-stopped.png) (the web strip, "No projects yet"),
[857-web-online.png](857-web-online.png) (the web page once Start brought the box back).

## Bugs filed

- #960: a failed ssh start waits 8 more minutes and says "hostKeyUnknown"; afterwards only Stop.
- #961: the sidebar says a stopped workspace "is offline", and offers no Start.
- #962: web: a stopped workspace's project leaves the sidebar, and its chat is titled "New session".
- #963: Mac: opening a chat on a host that just stopped shows a "Could not finish that: closed" alert.
- #964: Add a Server over ssh to a codespace fails, "ssh failed without saying why".
- #965: Codespaces: Start never brings a stopped codespace's host back.

## Left for later

- **The Remote's strip**, on a device (see the table at the top).
- **Pressing Start on the Mac's strip.** It was seen, with Start and Try now, but the Mac locked
  before it was pressed. The web strip's Start, the same `hosts/start`, was walked to online.
- **DigitalOcean**: the doctl preset and the shipped `@digitalocean/mcp` map on a droplet.
- **Codespaces end to end**, once #964 and #965 are fixed.

## Clean-up

The scratch set-up (`stop.sh`), the headless Chrome profile, the `w857-box` container and its
entry in the devbox `known_hosts`, the codespace and the repo were all removed. An earlier
lane's leftovers from 2026-10-12 (its scratch control plane, host and `w857-box`, still
running) were stopped first. That lane had seen the same `hostKeyUnknown` start. `gh codespace ssh`
left its own key, `~/.ssh/codespaces.auto`, which gh reuses.
