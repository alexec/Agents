# Walk: Foundational (058 re-plan, 2026-09-28)

The Foundational checkpoint: one copy of `agents-control` serves a real `agentsd` and
clients over WebSockets, with its state in a folder. Scratch folders only
(`/tmp/cpsmoke`, `/tmp/cpjoin`). No window: the window moves in US1.

## The service on its own (`/tmp/cpsmoke`)

- `agents-control serve --self-signed` made a certificate with openssl, printed its pin, and
  listened on 127.0.0.1:18798.
- `/healthz` answered `ok` and `/readyz` answered `ready`.
- `agents-control code --host` and `code --client operator` printed version 2 codes. The store
  held only `codes/<id>.json`, with no secret in it.
- SIGTERM stopped it cleanly.

## A real host (`/tmp/cpjoin`)

1. **Enrolling.** `agentsd --serve --control-code '<host code>'` on a scratch root:
   - it enrolled over the WebSocket as `2bkm6gno`, and `agents-control hosts` listed it;
   - its uplink connected, and it saved `control-host.json` with the URL and pin.
2. **Restart, first try.** Stopping and restarting the copy crashed `agentsd`: the dialler
   left a NIO promise behind when a connect was refused, and a debug build traps on that.
   - Fixed in `ControlDial.connect` (868f4d8b).
   - A test now dials a port nobody listens on, three times.
3. **Restart, fixed build.** `agentsd --serve --control-network` joined again from its saved
   membership, with no code. Across a second restart of the copy it tried twice while the copy
   was down, then connected within 4 seconds of it returning.

## Tests standing in for a window

- `ControlServiceTests`, 10 tests, cover:
  - enrolment, pairing, and routing to a host;
  - a code used twice;
  - a device refused operator calls, at the control plane and at the host;
  - a forgotten client cut off and refused afterwards;
  - a store belonging to another key;
  - a restart;
  - `/healthz` and `/readyz`;
  - a pinned self-signed copy by NIO and by `URLSession`, and a wrong pin refused.
- The kit's control tests: 92 pass.
- `agentsd` and `agents-control` build for aarch64 musl, and the Remote builds for the
  generic simulator.

## Not walked

- The window through the service. That is US1's walk, T053.
