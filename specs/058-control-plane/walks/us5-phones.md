# Walk 5: phone paths (US5, T079)

2026-09-29, on a scratch control plane:
- `agents-control serve --home /tmp/w5/control` at `https://127.0.0.1:18831`, self-signed;
- two scratch hosts: `walk5 mac` (the home host, `mac`) and `walk5 other`, with a project each
  (`p1`, `p2`).

## What was built

- **The Remote on the control plane (T076).**
  - `Remote/Sources/Link/ControlPlaneLink.swift`: the phone pairs with a version 2 device code
    and keeps its membership and a key of its own in its container.
  - It then dials the control plane's one address over `WebSocketLink`, which checks the pin
    from the code.
  - `RemoteApp` builds the model on that link once paired, and on today's `AwayLink` otherwise.
    The old path stays for a Mac that hasn't moved (until T112).
  - Scanning or pasting a control plane's device code pairs it and rebuilds the model on the new
    link.
  - A device the control plane refuses as forgotten or unknown forgets its membership and asks
    for a code again.
  - The rest of `RemoteModel` is unchanged. Bare lines on its connection go to the home host, as
    they went to the Mac, and every other host is reached over a second connection wrapped by
    `ControlLink`, as since the first build.
- **The fake device (T078).** `FakeDeviceLiveTests` now pairs with a device code and dials over
  `WebSocketLink` with the pin, exactly as the Remote does.

## Step 1: the fake device, directly

```
AGENTS_FAKE_DEVICE_CODE="$(agents-control code --client device --home /tmp/w5/control)" \
  swift test --package-path Packages/AgentsKit --filter FakeDeviceLiveTests
```

| What | Result |
|---|---|
| Pairing | Paired with "walk5 control plane" as a device. |
| Bare lines | `control/status` named the home host `mac`. `projects/list` gave `["p1"]`, and `credentials/lend` was refused (-32045). |
| The wrapped wire | `hosts/list` showed both hosts online. `walk5 other` gave `["p2"]`, `walk5 mac` gave `["p1"]`, and an operator-only call was refused on each. |
| The control plane's own calls | `clients/list` was refused (-32045). |

It took 1.2 s from pairing to the last call.

## Steps 1 (relayed) and 2: through agents-relay, and a notice

2026-09-29, on a second scratch set-up, `/tmp/w5r`:
- `agents-control serve --home /tmp/w5r/control` at `https://127.0.0.1:18832`, self-signed;
- one host, `walk5 mac` (`mac`), with a project `p1`;
- `agents-relay` as built by Xcode (signed as `com.alexecollins.agents.bridge`, with the
  bridge's iCloud container), joined with a host code under `AGENTS_ROOT=/tmp/w5r`, and with
  `AGENTS_RELAY_FOLDER=/tmp/w5r/icloud` standing in for iCloud, so nothing reached the person's
  iCloud.

```
AGENTS_FAKE_DEVICE_CODE="$(agents-control code --client device --home /tmp/w5r/control | tail -1)" \
AGENTS_FAKE_DEVICE_HOST_CODE="$(agents-control code --host --home /tmp/w5r/control | tail -1)" \
AGENTS_FAKE_DEVICE_RELAY=1 AGENTS_RELAY_FOLDER=/tmp/w5r/icloud \
  swift test --package-path Packages/AgentsKit --filter FakeDeviceLiveTests
```

| What | Result |
|---|---|
| The relay joins | Enrolled as `qmcdqc9l`, never the home host. `hosts/list` shows it with `relay: true`, and it is given no client channels. After a restart it came back with the same key in under a second. |
| The relay's key | `control/status` named it (`relayKey`) on the fake device's direct connection. |
| Relayed | The fake device dialled through the relay alone: connected in 7.8 s (the relay's idle poll is 5 s). The control plane logged "connected through the relay". `control/status` said `you` was the fake device, `projects/list` gave `["p1"]`, and `credentials/lend` was refused (-32045). |
| A notice | A host of the walk's own raised a need. The control plane chose the fake device (it had said it was away and may be notified) and sent `relay/deliver`. The relay sealed and posted it: in the mailbox 0.2 s later, with `alert: true`, and opened with the fake device's own key ("walk5 · A notice through the relay"). The withdrawal followed 0.2 s after it was said. |
| Nothing legible | No project name, method or headline anywhere under the stand-in iCloud. Frames were deleted once read; the mailbox held only the sealed item. |

## Found on the way

- **The fake device tried to open the relay host** as if it ran agents. The Remote, the Mac
  window's host list, first run and "This Mac" now all leave relay hosts out: the relay shares
  this Mac's machine ID, so it could have been taken for this Mac's host.
- **Across copies**, a relay host or a device enrolled at one copy was unknown at the others
  until the 15 s re-list. Opening a channel on the unknown relay tore down the device's whole
  session, and a need decided there had no device to go to. Pairing and enrolling are now
  announced to the peers at once (`CopiesTests.aNeedReachesTheRelayHeldByAnotherCopy`).
- **A device must have said it may be notified** (`presence/report` with `mayNotify`), or no
  notice is sealed to it. That rule was already there; the tests now say it as the Remote does.
- **The relay carries one session per device.** The Remote's second, wrapped connection would
  replace the first, so while relayed only the home host is reached. The others wait for the
  control plane's address, which is tried again every 30 s.

## Not walked, and why

- **Real CloudKit.** Every run stood a folder in for iCloud. Running the relay against the
  person's iCloud container would write to the live app's mailbox, and it must not run beside
  the old bridge's mailbox on one Mac.
- **The Remote's fallback on a device (T077).** It builds for the generic iOS simulator. Per
  the standing rule there is no throwaway simulator, and the look on the phone is Alex's.
- **Frame L's "Relay for my devices".** Still greyed: registering `agents-relay` as a launch
  agent from the window is not built.
