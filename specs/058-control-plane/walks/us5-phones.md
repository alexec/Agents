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

## Not walked, and why

- **Relayed (step 1's second half), and the notice in CloudKit (step 2).** Both need `agents-relay`
  (T096) and the notices through it (T097), which are not built. T077, the Remote's fallback to
  the relay, waits on them for the same reason.
- **The Remote on a device or simulator (step 3).** It builds for the generic iOS simulator. Per
  the standing rule there is no throwaway simulator, and the look on the phone is Alex's to
  schedule.
