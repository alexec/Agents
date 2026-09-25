# 037 walk — scratch root against the fake ssh (2026-09-25)

A scratch window (`/tmp/run-037`) launched with `AGENTS_SSH` pointing at
`Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/ssh/ssh`, so the "server" `fakebox` is a folder on
this Mac running this Mac's own `agentsd`. Driven by accessibility actions while Alex was away.

| Shot | What it shows |
|---|---|
| 01-no-servers | With no server the list is exactly today's: no headings. |
| 02-add-server-name | Add a server, state A. |
| 03-trust | State B: first connection, the fixture's real host-key fingerprint, fetched through ssh. |
| 04-ready | State C after Trust: installed, started, runtimes found. The list behind now has THIS MAC and FAKEBOX (green). |
| 05-server-folder | New project ▸ fakebox ▸ Choose Folder…: the server's home, listed by `files/browse`. |
| 06-server-project | ml-pipeline added on fakebox: under FAKEBOX, "on fakebox" in the header. It is in the server daemon's projects.json, not the Mac's. |

Proved without a screenshot (screen locked by then), from `<root>/hosts/hosts.log`:

- Relaunching the window reconnects to the server by itself.
- An app rebuild changed the helper's checksum, and the server was updated: new binary installed,
  old daemon asked to quit, new one started. (This found a bug, fixed: the window had reconnected to
  the old daemon on its way out. It now waits for the old socket to go.)
- Killing the server's daemon (not ssh) is noticed through the notification stream ending: offline,
  a retry a second later, a new daemon, connected.

Found and fixed during the walk:

- Two connects at once (start and the network monitor) raced two masters; a connect is now one at
  a time.
- The heading flicked to a spinner on every retry instead of "Offline · time"; it now keeps saying
  Offline until the server is back.
- The ssh master outlived the window on quit; it is stopped on quit, and a new master closes any old
  one at the same control path. A force-quit or crash still leaves it running until the next launch.

Still to see: the offline heading and the offline strip (T039), a real agent on the fake server, the
server files pane.

Noticed, not yet changed: the server folder sheet lists hidden folders (`.agents-server`, `.git`).

# On a real server (Alex's)

Everything above ran against a fake: a folder on this Mac and this Mac's own `agentsd`. None of it
has run on Linux. These are the checks that need a real server — any Linux box, x86-64 or ARM64,
reachable with key-based `ssh` from this Mac, with one agent CLI (say Claude Code) installed and
logged in there.

Before starting: run `scripts/build-linux-agentsd.sh`, then build and launch the app from this
branch. Nothing here touches your real agents; a scratch root is fine.

| # | Check | Do this | Passes when |
|---|---|---|---|
| 1 | First connection (SC-001) | Settings ▸ Servers ▸ Add a server, type the ssh alias. Time it to an agent's first reply. | The fingerprint matches `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the box; the four steps tick; your runtime is listed; under 2 minutes; you typed nothing on the box. |
| 2 | The daemon runs on Linux (T005) | New project ▸ <server> ▸ Choose Folder…, pick a repo, start an agent: "Create hello.txt and run uname -a". | hello.txt exists on the box, not the Mac; the reply says Linux; the files pane shows hello.txt; the terminal pane works. |
| 3 | Lid closed (SC-002/003) | Start a 5-minute task, close the lid for 10 minutes, open it. | The window is current within 10 s with no clicks; the task finished while you were away; its whole transcript is there. |
| 4 | Failures (SC-005) | Add `devbx` (typo); a host whose key is not in the agent (`ssh-add -D` first); a macOS host; a box with no CLI. | Each says its sentence within 30 s; `ls -a ~` on the box shows no `.agents-server` after the failed ones. |
| 5 | No listener (SC-006) | `ss -ltnp` on the box before adding it and after an agent has run. | Nothing new listening. |
| 6 | Update (SC-007) | Rebuild the Linux binaries after any change and reconnect: once idle, once with an agent mid-turn. | Idle: new binary, conversations intact. Mid-turn: orange "Update waiting", then the swap once the turn ends. |
| 7 | Reboot | `sudo reboot` the box while idle; wait; reconnect. | The window comes back on its own and the daemon is started again. |
| 8 | Remove | Settings ▸ Servers ▸ Remove…, with and without the checkbox. | Projects leave the list; the daemon is gone on the box; with the checkbox `~/.agents-server` is gone; your repos are untouched. |

## A Linux box on this Mac (2026-09-25)

`colima start` runs Docker; `docker start agents-devbox` brings the box back after a reboot. It is
Debian bookworm with openssh-server, one user `agents` who logs in with `~/.ssh/id_ed25519` only,
listening on 127.0.0.1:2222 and nowhere else. Its Dockerfile is in `/tmp/037-devbox/`.

In Add a server, type `agents@127.0.0.1:2222`. From a terminal:
`ssh -p 2222 agents@127.0.0.1`. Node 22, Claude Code and `@agentclientprotocol/claude-agent-acp`
are installed there globally; `agents` is not signed in to Claude yet.

Walked with the real `/usr/bin/ssh` on scratch root `/tmp/run-037r` (screenshots in `linux/`):

1. Add a server showed the key fingerprint, and it matched `ssh-keygen -lf` inside the box
   (`01-connect.png`). Trust and continue installed the aarch64 agentsd (`install.json` has
   the checksum, `--serve` is running) and the heading came up with a green dot.
2. New project ▸ 127.0.0.1 ▸ Choose Folder… browsed the box's real home; `~/src/hello` was
   added as a project (`02-folder.png`, `03-project.png`), and Claude's model menu came from
   the adapter running on Linux.
3. A turn (started over the forwarded socket with `rpc.py`: setting the prompt field over
   AX does not reach its binding, so Send stayed disabled, and Alex was at the keyboard)
   went through session/create on the box and stopped with the adapter's
   `Authentication required`. The window listed it at once as hello · 1 stopped
   (`04-needs-sign-in.png`), but says only "Claude stopped answering", not that Claude
   needs signing in on the server.

To finish it: `ssh -p 2222 agents@127.0.0.1`, run `claude`, sign in with `/login`, quit, then
send a turn in the hello project.

After merging main (2026-09-25): relaunching on the new build updated the box by itself (new
binary, old daemon quit, new one answering, about 2 s in `hosts.log`), and `shell/attach` over the
forward gave a login bash on `/dev/pts/0` in `~/src/hello` that ran a command and echoed it back.
