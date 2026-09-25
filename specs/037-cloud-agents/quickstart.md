# Quickstart: Proving Cloud Agents

## Prerequisites

- 034-ios-artifacts merged into `main` (the `files/*` methods), and this branch rebased onto it.
- For the Linux build: the swift.org toolchain matching Xcode's Swift version, and its Static
  Linux SDK:
  ```
  swift sdk install <static-linux-sdk URL for that version> --checksum <sum>
  swift sdk list        # shows x86_64-swift-linux-musl and aarch64-swift-linux-musl
  ```
- For the real-server walks: a Linux box (x86-64 or ARM64) reachable with key-based `ssh`, with
  one agent CLI installed and logged in there. That box is Alex's to provide.

## 1. Linux build (Phase 0 gate)

```
scripts/build-linux-agentsd.sh --check
file App/Resources/servers/agentsd-linux-*   # "statically linked", right arch
```
Then, by hand, on the server:
```
scp App/Resources/servers/agentsd-linux-<arch> box:/tmp/agentsd
ssh box '/tmp/agentsd --version && /tmp/agentsd --root /tmp/ar --serve --detach'
ssh -N -L /tmp/box.sock:/tmp/ar/daemon.sock box &
# drive /tmp/box.sock the way driving-agentsd-by-hand does: runtimes/list, projects/add, agents/start
```
**Pass**: a one-line prompt completes, and `shell/attach` gives a working terminal.

## 2. The SSH layer, no server needed

```
swift test --filter Hosts
```
Covers, through the fake `ssh` fixture and the Mac `agentsd`: resolve → unknown key → trust →
master → probe → install → start → forward → `agents/list`. Also: the checksum mismatch leaves
nothing; update waits for `turnsInFlight == 0`; newer server refused; remove with and without the
checkbox; the stderr classifier against captured fixtures; `sendID` repeat returns the first
result.

## 3. The window against the fake host (Phase 2 look gate)

Using the run-app skill on a scratch root, with `AGENTS_SSH=<fixture path>` so `HostSet` uses the
fake `ssh`:

1. Settings ▸ Servers ▸ **+**, type `fakebox`. **Expect** the checklist, then state B with a
   fingerprint, then C with the runtimes the Mac has (the fake host is this Mac).
2. **New project ▸ fakebox ▸ Choose Folder…**, pick a folder. **Expect** a FAKEBOX heading with
   the project under it; the header reads `on fakebox`.
3. Start an agent; ask it to create a file. **Expect** the file in the fake server home, not the
   project's Mac path, and the files pane shows it.
4. Kill the fake master's pid. **Expect** within 1 s `Offline · HH:mm`, the strip, Send disabled,
   and the draft kept. Within one backoff step: reconnected, strip gone, transcript complete.

Screenshots go in `specs/037-cloud-agents/walk/`.

## 4. Real server (Phase 6, Alex)

| Check | How | Pass |
|---|---|---|
| SC-001 | Fresh box, stopwatch from Add a server to an agent's first reply | < 2 min, nothing typed on the box |
| SC-002/003 | Start a 5-min task, close the lid for 10 min, open | The task finished; the window is current within 10 s |
| SC-005 | `devbx`, a box with the key removed from the agent, a changed host key, a macOS host, a box with no CLI | Each message within 30 s; `ls -a ~` on the box shows no `.agents-server` after the failures |
| SC-006 | `ss -ltnp` on the box before and after | No new listener |
| SC-007 | Install an older build, connect with the newer one, once idle and once mid-turn | Swaps when idle; waits, then swaps, when busy; transcript intact |
| Edge | Two Macs on one box; reboot the box mid-idle | Both see the same agents; after the reboot the daemon comes back on connect |
