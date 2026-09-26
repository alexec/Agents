# US3 walk — a server joins through the control plane (2026-09-26)

Built from `b5f32c41`, plus the two fixes in the commit that adds this file. The walk used:

- a fresh scratch root, `/tmp/run-sv`, where Run one on this Mac started the control plane and host as launchd jobs;
- the devbox (`agents@127.0.0.1:2222`, Debian arm64, Claude signed in), with its key already in `~/.ssh/known_hosts`.

Main's Linux `agentsd` builds were copied into the worktree's `App/Resources/servers`. They are a build output, not in git, and nothing on the server side changes in 058.

## What was seen

1. **Add a Server** ([us3-add-a-server.png](us3-add-a-server.png)): Settings ▸ Control plane ▸ Hosts ▸ Add a Server… asks for anything the control plane's ssh can reach.
2. **Install.** Connect sent `hosts/install` to the control plane, which did the rest on its own ssh:
   - resolved and checked the host key (already known, so no trust question);
   - probed the system and installed the Linux `agentsd` (sha `9b0a0d3b…`, replacing a test build);
   - started the daemon and forwarded its socket to `<control root>/hosts/<id>.sock`;
   - made the server a host.
   The sheet said "127.0.0.1 is a host now". Hosts showed it as "Linux · ARM64 · Agents 0.1.0+1 · reached over ssh" ([us3-devbox-joined.png](us3-devbox-joined.png)).
3. **A real turn on Linux, through the control plane.** `projects/add` and `agents/start` (Claude, in `~/src/hello`) were sent with `h: <devbox>` to the control plane's socket. Claude read the README and ran `uname -a`, which came back `Linux d900157ec616 6.8.0-117-generic … aarch64`, and the turn finished.
4. **The window sees the server** ([us3-window-sees-devbox.png](us3-window-sees-devbox.png)). The scratch window listed the devbox's project `src`, "on 127.0.0.1", with its agent; `hello` was archived by an earlier test run. The window reaches the server through the control plane with a client of its own per host, and holds no ssh connection.
5. **Remove** (from the Hosts page, then again over the socket):
   - the host went from `hosts.json` and its ssh master stopped;
   - the devbox's daemon kept running (pid 4857), so its agents are left alone (FR-014);
   - the window dropped the server's projects ([us3-after-remove.png](us3-after-remove.png)).

## Found and fixed on the way

- **The server stayed in the window after Remove**, now "on a server". The window now drops a removed host's projects and agents.
- **A re-added server sometimes didn't appear in the window.** The host was said to be online before it was on record, so a window listing hosts in between missed it. It's now announced again once enrolled. Re-walked: it appeared within 5 seconds, and went on Remove.

## Tests

`SSHUplinkTests` (2), against a real `DaemonServer` on a socket:
- each channel is a connection of its own;
- a device's channel is bound to that device and refused `credentials/lend` by the daemon;
- the binding's own answer is not passed on;
- closing a channel ends its connection, and the server going ends the other channel.

Control-plane suites: 73 pass.

## Not walked

- **The host-key trust question.** The devbox's key was already trusted. The first-trust path (`needsTrust`, then Trust and continue) is built but was not seen.
- **Runtime installs on the server (Claude's toolset, 043/056).** The control plane installs only `agentsd`. The Mac's sign-in relay needs a stream channel (R9, R10).
- **A server dropping and coming back.** `ServerConnection` reconnects as it does for the window, but the control plane has no network monitor yet to prompt it.
- **Linux dialling out (spike S1).**
