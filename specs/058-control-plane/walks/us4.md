# US4 walk — the iPhone and iPad through the control plane (2026-09-26)

Built from `44efb389`, plus the fix in the commit that adds this file.

Set-up, on a fresh scratch root `/tmp/run-dv`:
- Run one on this Mac, so the control plane and host run as launchd jobs.
- The bridge's direct link on port 8799, now **off Bonjour**.
- A project `work` on this Mac's host, and the devbox added as a host through the control plane.

The fake device is `FakeDeviceLiveTests`, a live test run only when pointed at a scratch control plane. It pairs and connects exactly as the Remote does:

    AGENTS_FAKE_DEVICE_CONTROL=/tmp/run-dv/control AGENTS_FAKE_DEVICE_PORT=8799 \
      swift test --filter FakeDeviceLiveTests

## What the fake iPhone did, over the bridge's TLS direct link

1. It asked this Mac's host for a pairing code through the control plane, as the window's Pair a Device does. It announced itself with the code, then connected with its own key.
2. **Today's Remote (bare lines):**
   - `projects/list` came back as `["work"]`, from this Mac's host, as a device.
   - A bare `control/status` was answered by the control plane: "Alex's MacBook Air, home host mac". This is how the new Remote finds out there is one.
   - `credentials/lend` was refused (-32045).
3. **The wrapped wire, over one more connection:**
   - `hosts/list` returned `127.0.0.1 (online)` and `Alex's MacBook Air (online)`.
   - The devbox's projects were `["src"]` and the Mac's were `["work"]`, both read as a device.
   - An operator-only call was refused on each host, and `clients/list` was refused by the control plane (-32045).
4. **In the window's Settings** ([us4-clients-fake-iphone.png](us4-clients-fake-iphone.png)), "Fake iPhone" is a client with a Device grant and a working Operator/Device picker.
   - The first build listed it twice: once as a control-plane client, once as a device paired to the host. Fixed: a device is listed only until the control plane has met it.
5. **Forget** ([us4-after-forget.png](us4-after-forget.png)) took the iPhone off the control plane's `clients.json` and, through the bridge, off the host's `devices.json`. The bridge then listened for 0 devices, so its key opens nothing.

## Also in this change

- **The relay (away from home):** `RelayHostCore` can be given a device opener. With a control plane, the bridge hands it `attachDevice`, so a device away from home is the same client of the router. Tested by the relay suites passing; not walked (the scratch job has no iCloud mailbox).
- **The Remote:**
  - After connecting, it asks `control/status`. Against a control plane, it opens one more connection over the same link, with a client per other host.
  - Their projects and agents join the lists, tagged by host.
  - Calls that name an agent or folder on another host go to that host's client: sends, starts, stops and transcripts.
  - Against a bridge with no control plane, nothing changes.
  - It builds for the generic simulator. Seeing it on the phone is Alex's.
- **Scratch bridges stay off Bonjour** (`AGENTS_BRIDGE_NO_BONJOUR` in the scratch job). Before this, a walk's bridge advertised itself on the network with this Mac's name, where the person's own phone could find it first.

## Tests

`ControlDeviceTests` (3), in memory:
- a device's bare lines reach its Mac's host as a device, and a bare `control/status` finds the control plane;
- over the wrapped wire, a device reaches every host and is refused `credentials/lend` there;
- forgetting a device client tells the bridge.

135 tests across the control-plane, relay and role suites pass.

## Not walked

- The Remote app itself on a phone or iPad, including host headers in its project list (T054, not built). Its lists mix every host's projects without saying which host each is on.
- Relay sessions away from home through the control plane.
- Notices sealed by the control plane across hosts (T056, R6): hosts still seal their own.
