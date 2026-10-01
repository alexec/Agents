# Walk 4, steps 1–3: the move (US7, T088)

2026-09-29, on the scratch root `/tmp/w7`, from aa07c05c.

## Step 1: a root seeded the old way

- **The old daemon.** `agentsd` on `AGENTS_ROOT=/tmp/w7` with no control plane, and a
  project `p1`. One agent had a real Claude turn ("Write hello.txt…"), which finished and
  wrote the file.
- **The old bridge.** `agents-bridge` from this branch's build, with `AGENTS_BRIDGE_PORT=18799`
  and `AGENTS_BRIDGE_NO_MAILBOX=1`, which keeps its mailbox and relay off iCloud.
- **A fake iPhone paired the old way.** `FakeDeviceMoveLiveTests pair` used a pairing code
  from the daemon and announced its own key over the bridge. It then connected with that
  key, and saw `p1` and the agent.
- **The devbox in `hosts.json`**, as `agents@127.0.0.1:2222`.

## Step 2: Agents Host over it

The scratch Agents Host was launched with `AGENTS_ROOT=/tmp/w7`:
- `/tmp/w7` holds an old set-up, so it took it as the host's root, copying nothing (T083);
- the control plane's home was `/tmp/w7/control`, on port 18791.

It was driven by accessibility presses by pid and captured by window id, behind the windows
in use. Nothing came to the front.

| Step | Result |
|---|---|
| Frame L (`us7-move-L-strip.png`) | The strip: "You have agents from the earlier Agents app on this Mac." with Move Across…. Nothing is running yet. |
| Frame I (`us7-move-I-sheet.png`) | The sheet listed what is kept: "Your agent and its conversation stay on this Mac, as this Mac's host", "Fake iPhone keeps working, without pairing again", "devbox is added as a host, over your ssh as now", and that work on this Mac carries on after a restart. |
| Move Across (`us7-move-adding-devbox.png`, `us7-move-done.png`) | It stepped through letting the old daemon go, starting the control plane and this Mac's host, moving the devices, and "Adding devbox as a host…". It ended with "Moved. Your devices are told where the control plane is the next time they connect." and "devbox joined as a host". |
| Frame L after (`us7-move-L-after.png`) | No strip. "Running at https://alexs-macbook-air.local:18791 · 1 client · 2 hosts". This Mac: "Running your agents · 1 project". |

## Step 3: what was kept

| Check | Result |
|---|---|
| The root | It is the same folder, now held by Agents Host's `agentsd` (pid 61053 in `daemon.lock`). The old daemon quit when asked, and left its agents running. |
| Every agent, with its history | `agents/list` gave the one agent, `finished`, with its 60 transcript entries. |
| The store | `clients` lists `Fake iPhone · iPhone · device`, with the key it paired with. `hosts` lists `mac` and the devbox (`7skk0v19`). |
| What the move wrote beside the old files | `control-moved.json` (the address, pin, control key and name). `hosts.json` became `hosts.json.moved`. Nothing else in the root changed. |
| The devbox | Joined over the person's own ssh with the one-line command from `code --host --command`. Its host runs from `~/.agents-server` on the devbox. |
| The fake iPhone, `again` | It connected over the old bridge with its old key, which reached the new daemon on the same socket. It said which device it was, and was told: "the control plane Alex's MacBook Air is at https://alexs-macbook-air.local:18791". It then dialled that address over a WebSocket, with the pin, as itself, using the key it paired under. `control/status` named it and home host `mac`. `hosts/list` showed both hosts online. It saw `p1` and its agent on `mac`, and the devbox's project and agent. |

## Not walked

- **Step 4 (US9, a second Mac).** It belongs to US9 (T094–T095).
- **The Remote on a phone following `control/moved`.** It builds for the generic simulator.
  The fake device does what it does. The phone look is Alex's.
- **Ending the old link from frame L.** The move never stops the old bridge, so the old
  `DirectLink` keeps running, and a device still on it is told the new address whenever it
  connects. There is no button yet to say the old way is finished; quitting the earlier app
  does it.
- **A bucket store.** This walk used the store on this Mac. `agents-control move` writes to
  whichever store the copy uses, and `MoveTests` covers the path in memory.
