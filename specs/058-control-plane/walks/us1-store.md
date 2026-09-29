# Walk: US1, the App Store window (T053)

2026-09-28, on the scratch root `/tmp/cpstore`, with commit 4022b3fd plus the `MachineID`
line in the walk's pairing log.

## Set-up

- `agents-control serve --port 18801 --self-signed /tmp/cpstore/tls`, with
  `AGENTS_STORE=file:///tmp/cpstore/store`.
  - The pin is `0ySHs8WE5w4Hdj2Jo1Q2O7c25huQL3ZoCcLP7GrgHDU`.
- A scratch agentsd on `/tmp/cpstore/host`, joined with a host code.
  - The control plane logged `host store-walk host enrolled as mac`, because it runs on
    the same machine as the control plane.
- The AgentsStore build (sandboxed, AgentsKitCore only), launched with a clean
  environment:

  ```
  env -i HOME=$HOME PATH=/usr/bin:/bin USER=$USER open -n -g --env AGENTS_CONTROL=<operator code> \
      /tmp/store-dd/Build/Products/Debug/Agents.app --args -ApplePersistenceIgnoreState YES
  ```

  - With `AGENTS_CONTROL` set, the window pairs on first run: a walk hook in
    `AppModel+MacHost.swift`, store build only.

## What was checked

| Check | Result |
|---|---|
| Pairing from the sandbox | Passed. The window logged `walk: paired as 4FC0D60E-…`; the control plane logged `Alex's MacBook Air paired as operator`. |
| The window's socket | One socket: `localhost → localhost:18801 ESTABLISHED`, the WebSocket over TLS with a pin, from `URLSession`. |
| Reaching the host | Passed. The host logged `uplink: a channel opened for an operator`, so the window's calls travel through the control plane to the `mac` host. |
| Child processes | None (`pgrep -P <pid>`). |
| Sandbox violations | None for the window's pid in `/usr/bin/log`. The only line was launchservicesd refusing to bring it forward, because the screen was locked. |
| Where the pairing is kept | `~/Library/Containers/com.alexecollins.agents.store/Data/Library/Application Support/Agents/`, holding `control-client.json` and `control-client-key`. |
| `MachineID` in the sandbox | Works. It reads `8AB85821-…`, which is the `IOPlatformUUID` and matches the host's `machineID` in the store, so `ThisMacHost` keeps using it. |
| The grep gate (`scripts/check-store-window.py`) | Passes. It also runs as a build phase of AgentsStore. |

## Found and fixed

- **The first launch could not pair.** `open` passes the launching shell's environment
  through, and the Agents app that hosts this session sets `AGENTS_ROOT`.
  - `StoreLocations.default` followed that to the real app's root, and the sandbox refused
    the write.
  - The fix: the store window's `ControlConfig` now keeps its pairing in its own container
    (`applicationSupportDirectory`), whatever `AGENTS_ROOT` says. It never reads a daemon's
    root.

## Still open

- **Screenshots of each step, clicking Reveal, and opening the shared skills page.** The
  screen was locked for the whole walk (idle more than 19 minutes), so these wait for an
  unlock. The route itself is proven over the socket above.
- **The Local Network prompt.** Opening the store build from Finder and dialling a control
  plane on another machine needs a second machine and a person at the screen.
- **A real Claude turn from the store window.** This needs the screen.

## Deviations from the tasks

- **T050:** the window's key is a file in the container, not an item in the keychain.
  - The container is the window's alone, and an unsigned build's keychain items raise
    SecurityAgent prompts (memory: seeded Keychain items).
  - The keychain comes with a signed build.
- **T049b:** the store build has a stand-in `HostSet`, filled from the control plane's host
  list (`hosts.controlled`), instead of each view reading control hosts directly.
  - The developer build's `HostSet` stays until T106.
