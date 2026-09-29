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

## The screen walk (2026-09-29, after unlock)

Screenshots are in `walks/us1-store/`.

| Step | Result |
|---|---|
| Frame K, unpaired (`frame-K.png`) | Matches the approved frame: two cards and the waiting line. |
| Frame K2 (`frame-K2.png`) | `dns-sd -R "Alex's MacBook Air" _agents-control._tcp` stood in for Agents Host's advertisement, and K turned into K2 by itself. |
| Pairing through the sheet (`pair-sheet.png`) | Pair, a fresh operator code inserted into CODE, then Connect. The control plane logged `paired as operator`, and the window went to the host's projects (`paired-2.png`). |
| A real Claude turn (`turn-3.png`, `turn-5.png`) | Sent from the store window's composer. The permission card showed in the window and was answered Yes there. Claude wrote `/tmp/cpstore/work/hello.txt` ("hello from the store window"), and the chat ended with Claude's summary. |
| Reveal in Finder (`files-2.png`) | Pressed on a zip in the Files pane. The host's `mac/reveal` opened Finder on `/private/tmp/cpstore/work`. |
| Shared page (`shared-1.png`) | Answered by the host: "The shared folder is off for this copy of the app". A scratch host keeps `~/.agents` alone, so the route is proven but the Skills page itself needs a real host. |
| Child processes and sandbox denials | None, across all four window launches. |
| The Local Network prompt | It never appeared on this Mac: not while browsing Bonjour, and not while dialling 127.0.0.1. A second machine is still needed to see it. |

### Found on screen and fixed

- **The walk hook paired a throwaway model.**
  - It was called from `AgentsApp.init`, where the `@State` model isn't yet the window's.
  - It now runs from K's `.task`.
- **Frame K made the window 6,054 points tall.**
  - Laid out at no width, the words fixed to their height push the window's minimum up.
  - A minimum width of 520 on the column fixes it: the window resizes to 720 again.
- **The Files pane told the store window "On This Mac. Open it there."**
  - It offered no Reveal or Open, because in the store build it treats every host as a server.
  - Showing is now decided by `isOnThisMac` (`elsewhere`), while reading still goes through the host.
  - `OpenElsewhere` sends Reveal and Open through `mac/reveal` and `mac/open` on the file's host, instead of calling `NSWorkspace` itself.
- **The gate missed `NSWorkspace.shared.open(<variable>)`.**
  - It now flags every `open(`.
  - A chat's resource links go through the window's `openURL`, and the store window sends `file://` links to the host.
  - Web and System Settings links carry `store-ok`.
- **The scratch host was started wrongly.**
  - It ran with `--serve`, which made it a server that asks to be lent Claude's sign-in, and carried this session's `CLAUDE_*` variables.
  - A Mac host runs without `--serve`, as `LocalServices` starts it. That is a walk set-up error, not a product one.

## Still open

- **The Local Network prompt,** against a control plane on another machine.
- **The shared Skills page** against a host whose shared folder is on (a real Agents Host, T055).
- **The window's first open height** (1410) is the screen's rather than `defaultSize`'s 720. It resizes freely.

## Deviations from the tasks

- **T050:** the window's key is a file in the container, not an item in the keychain.
  - The container is the window's alone, and an unsigned build's keychain items raise
    SecurityAgent prompts (memory: seeded Keychain items).
  - The keychain comes with a signed build.
- **T049b:** the store build has a stand-in `HostSet`, filled from the control plane's host
  list (`hosts.controlled`), instead of each view reading control hosts directly.
  - The developer build's `HostSet` stays until T106.
