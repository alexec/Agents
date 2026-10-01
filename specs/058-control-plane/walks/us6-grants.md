# Walk: US6, grants over two copies (T082)

2026-09-29, on the scratch set-up `/tmp/w6`, from the branch at 65b5ac9c plus the fixes below.

## Set-up

- **Two copies of `agents-control`** on this Mac:
  - one bucket, `s3://agents-walk/w6` in the `agents-minio` container on `127.0.0.1:19000`;
  - one key file;
  - each terminating TLS itself with the one self-signed certificate in `/tmp/w6/tls`, so both
    have the same pin;
  - copy A on `https://127.0.0.1:18851`, copy B on `https://127.0.0.1:18852`, each with its
    own address as its peer URL.
- **A scratch `agentsd`**, `walk6 mac`, joined with a host code. It became `mac`, with a
  project `p1`.
- **`agents-relay`** (the Xcode build, signed as the bridge), joined with a host code, with
  `AGENTS_RELAY_FOLDER=/tmp/w6/icloud` standing in for iCloud.
- **The App Store window** (`AgentsStore`), launched with `env -i … open -n -g`.
  - It paired at copy A through the walk hook (`AGENTS_CONTROL`).
  - The pairing Walk 2 had left in its container was moved to `/tmp/w6/container-before`
    first.
- **The fake iPhone** (`FakeDeviceLiveTests` with `AGENTS_FAKE_DEVICE_RELAY=1` and
  `AGENTS_FAKE_DEVICE_HOLD`), held connected through the relay.
- **`Walk6LiveTests`**, which pairs `walk6 iPad` and two more operator windows:
  - it connects the iPad at copy B for 3 s;
  - it holds `walk6 other window` connected at copy B;
  - it races grant changes on the iPad from copies A and B.

The window was driven by accessibility presses by pid, and captured by window id, behind the
windows in use. The window came to the front once, after the first press; it was hidden at
once and shown again behind.

## The steps

| Step | Result |
|---|---|
| D · Overview (`us6-grants-D-overview.png`) | This Mac, 2 hosts online, and 5 clients with 3 operators. It said "Reachable away from home: Off" although a relay host was online; that is fixed below. |
| E · Hosts (`us6-grants-E-hosts-before-fix.png`) | It listed only This Mac under a count of 2. The relay host shares this Mac's machine ID and fell through both filters. Fixed below. |
| N · Clients (`us6-grants-N-clients.png`) | As approved. *This window* is "connected directly". The Fake iPhone is *away*, "connected through **walk6 relay mac** (iCloud relay)". `walk6 iPad` is "seen 9 minutes ago". `walk6 other window`, connected at copy B, is "connected directly" in the window at copy A, so the copies tell each other who is connected. |
| Promote (`us6-grants-F-promoted.png`) | Pressing Operator on `walk6 iPad` promoted it. |
| Forget across copies (`us6-grants-F-forget.png`, `-forgotten.png`) | *Forget walk6 other window?*, then Forget, in the window at copy A. Copy B logged `applied clientForgotten`, and no connection was left to copy B's port a moment later. The row went, and the count went to 4. |
| G · Pair a Mac (`us6-grants-G-pair-a-mac.png`) | The sheet shows an operator code carrying copy A's address and the shared pin, good for 4:56. |
| The store unreachable (T081, `us6-grants-store-down.png`) | With MinIO stopped, demoting `walk6 iPad` was refused. The window said: "The control plane can't reach where it keeps its records, so nothing was changed. Agents that are running carry on." It took about 25 s, the S3 client's retries. The iPad stayed an operator in the store. |
| Race (Walk 2 step 9) | Three rounds of two grant changes at once, from copies A and B. Rounds 1 and 2: one was refused `changedElsewhere` (-32093), and the other went through. Round 3: both went through, one after the other. The store ended with the second copy's change. |
| The last operator across copies | Walked as the test `CopiesTests.theLastOperatorHoldsAcrossCopies` (below), not on screen. |

## Found and fixed

- **The last operator did not hold across copies.**
  - Two operators demoting each other at the same moment, at two copies, both went through,
    and no operator was left. It happened in every round of the new test.
  - Each copy checked its own reading of the records, and each record is written on its own.
  - Now `v1/operators.json` lists the operators. Every change of who is an operator rewrites
    it conditionally, so one of the two is refused (57293443).
- **Copies that terminate TLS themselves could not link.**
  - A peer dial checked the other copy's self-signed certificate against the system roots.
  - It now uses the pin the copies share (f0e423cf).
- **The relay host was missing from Hosts (frame E).**
  - It is now listed with "Relays your devices through iCloud", or "Relaying switched off".
- **"Reachable away from home" said Off with a relay host online.**
  - `control/status` now says it is on whenever a relay host is relaying.
- **A refused grant change left the clicked segment lit.**
  - The iPad's picker still showed Device after the store refused the change.
  - The record had not changed, so a picker drawn only from a Binding did not redraw.
  - The picker is now redrawn after every action.

## The fixes, seen (19:2x, after Alex was back)

The set-up was started again on the same bucket, root, relay folder and window container. The
system had switched to dark appearance in between.

| Look | Result |
|---|---|
| E · Hosts (`us6-grants-E-hosts.png`) | The relay host has its own row: "walk6 relay mac · Relays your devices through iCloud", with Check again and Remove…. (This Mac shows offline here: the restarted scratch `agentsd` exited with the shell that started it. That is the walk's doing, not the app's; the first pass had it online.) |
| D · Overview (`us6-grants-D-away-on.png`) | "Reachable away from home: On · Through your iCloud account, sealed to each device". |
| A refused change (`us6-grants-picker-pressed.png`, `us6-grants-picker-refused.png`) | With MinIO stopped, Device was pressed on an operator. The segment showed Device while the call was out. When the refusal came back, it returned to Operator, with the words about the store under the list. |
