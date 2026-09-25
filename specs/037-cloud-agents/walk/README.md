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
