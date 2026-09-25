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
