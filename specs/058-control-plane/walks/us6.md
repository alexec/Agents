# US6 walk: moving today's set-up across (2026-09-26)

Built from `abd27222`, plus the fixes in `e00a1638` and in the commit that adds this file. The final walk was on the fresh scratch root `/tmp/run-mw`. An earlier walk, on `/tmp/run-mv`, found the problems listed under "Found and fixed" below.

## The seed: everything done the old way

1. **A real turn.** A daemon on the root got a project `work`, and a real Claude turn wrote `notes.txt` and finished. Then the daemon was quit.
2. **The window, the old way.** The window was launched on the root with `env -i … open -n -g`. It started its own `agentsd` as its child (ppid = the window).
3. **The devbox, the old way.** `agents@127.0.0.1:2222` was in the root's `hosts.json`. The window reached it with its own ssh master (`<root>/hosts/devbox01.ctl`). Its log said `127.0.0.1: connected`, and the sidebar showed `src` under "127.0.0.1 ●".
4. **A phone, the old way.** An old-mode bridge ran on the root (port 8799, off Bonjour, no mailbox). It had no `--control-root`.
   - A fake iPhone (`FakeDeviceMoveLiveTests`, `AGENTS_FAKE_DEVICE_MOVE=pair`) took a pairing code from the root's own daemon, announced itself, and connected with its own key.
   - It saw `["work"]` and the agent.
   - Its key and what pairing gave it were kept in `<root>-fake/`, as a phone keeps them.

## The move

- **Before** ([us6-before.png](us6-before.png)): the strip is offered above the columns ("Agents now runs on a control plane…" and Move Across…). Nothing moves on its own.
- **Frame I** ([us6-i-sheet.png](us6-i-sheet.png)): the sheet listed what is kept:
  - "Your agent and its conversation stay on this Mac, as this Mac's host"
  - "Fake iPhone keeps working, without pairing again"
  - "127.0.0.1 is added as a host, over your ssh as now"
  - "Work on this Mac carries on after a restart"
- **The old bridge was stopped before pressing Move Across.** The control plane's job needs port 8799. On Alex's Mac the hand-started bridge on 8790 has to be stopped the same way (see "Open").
- **Move Across**, pressed by AX on the window's pid. It took about 2 seconds, through five screens of steps ([us6-moved.png](us6-moved.png)): "Moved. This window now works through the control plane on this Mac." What happened:
  - `daemon/quit` with `stopAgents:false` went to the window's own daemon. Then launchd's two scratch jobs started, and the host ran `agentsd --control …` from **the same root** (ppid 1).
  - `control/clients.json` has "Fake iPhone" (device, same id and key) and the window (operator). `control/hosts.json` has `mac` and the devbox, and `homeHost` is `mac`.
  - The devbox was added with `hosts/install` over the control plane's own ssh (`<root>/control/hosts/<id>.ctl`). The window's ssh master to it **stopped**.
  - `hosts.json` became `hosts.json.moved`, kept rather than deleted.
- **Reopened** ([us6-after-reopen.png](us6-after-reopen.png)): the window was quit and opened again.
  - It went straight to its projects, with no first run and no strip.
  - "This Mac" had `work` with the agent from before the move, and "127.0.0.1 ●" had `src`.
  - The only daemon for the root was launchd's.
- **The phone, after** (`AGENTS_FAKE_DEVICE_MOVE=again`): it connected with the key it paired with the old way, through the control plane's bridge.
  - Bare lines: `["work"]` and the same agent id. A bare `control/status` found the control plane, home host `mac`.
  - Wrapped: `hosts/list` gave both hosts online; `work` on the Mac and `src` on the devbox.
- **Clean-up:**
  - Both jobs were booted out; **the control plane's ssh master went with them**.
  - The window was quit, the roots removed, and the roots' defaults keys deleted.

## Found and fixed on the way

- **The strip covered the first row of every column.** A split view's columns run under a `safeAreaInset`. The strip now sits above the columns in a stack.
- **The sheet vanished before it could say "Moved".** It hung off the strip, which goes as soon as the window adopts the control plane. It now hangs off the window.
- **The window kept its own ssh to the devbox after the move.** The control plane had its own, so there were two masters to one server. On adopting, the window now hands its servers over (`HostSet.handOver`): it stops each master and drops their lists.
- **The control plane's ssh masters outlived it.** launchd's SIGTERM ended the bridge, but its ssh children kept running. It now stops them on SIGTERM (`ControlPlane.stop`). Seen gone at clean-up.
- **The control plane's hosts had no heading in the window.** A US3 gap that the move made plain: the sidebar grouped only the window's own ssh servers. It now groups every server the window lists (`HostSet.servers`), and so do the New Project menu and project stepping.
- **"All 1 agent", "Fake iPhone keep working":** the copy is now singular for one agent, device or server.

## Tests

`ControlMoveTests` (4):
- paired devices become device clients with their own keys, and the old root is only read;
- running it again changes nothing;
- a control root with clients of its own is refused;
- the window's servers are kept, renamed, not deleted.

`FakeDeviceMoveLiveTests` is the live half, used above.

## Open

- **The failure path, not walked:** Move Across while an agent is mid-turn. The daemon refuses the quit, and the sheet should say "Nothing has changed". It is written, not seen.
- **The real `SMAppService` path** (Login Items) is used only on the ordinary root. It waits for Alex's own move.
- **Alex's own move:** the hand-started bridge on 8790 has to be stopped first, and the Remote on the phone will then connect to the control plane's bridge. This happens only on his go-ahead (see the memory for the running pids).
