# US1 walk — the window through the control plane (2026-09-26)

Scratch roots only: control plane at `/tmp/cpw/control` (the bridge with
`AGENTS_CONTROL_ROOT`, port 8799, no mailbox), host at `/tmp/cpw/host`
(`agentsd --control /tmp/cpw/control/hosts.sock`), and the window run with
`--root /tmp/cpw/host --control-root /tmp/cpw/control`. Builds from `d92c4607`, then
`9f2bfc92`.

## Over the sockets

- `control/status`, `hosts/list` (host `mac` online, dialOut, machine id), `clients/list`
  (the window as "This Mac", operator): all answered by the control plane.
- `projects/list` and `runtimes/list` with `h: mac` came back from the host tagged `mac`.
- `h: nowhere` came back as `noSuchHost` (-32071).

## With the window

- The window started **no daemon**. The only `agentsd` was the host.
- A project added through the control plane appeared in the window at once.
- **Found and fixed (`9f2bfc92`):** the window said "Claude on this server needs a
  token". The daemon took "never exits when idle" to mean "is a server", so a Mac host
  kept up for the control plane asked for a lent key. `onServer` is now separate from
  `exitsWhenIdle`.
- A real Claude turn, started through the control plane: the window showed it under
  "Needs attention" ([us1-question.png](us1-question.png)). The permission was answered
  through the control plane, `hello.txt` was written, and the window showed it done and
  unread ([us1-done.png](us1-done.png)).
- Control plane stopped: the host logged "the control plane went; 1 channels closed"
  and kept retrying. The window said "Not connected to the daemon" and kept its list
  ([us1-control-down.png](us1-control-down.png)).
- Control plane started again: the host rejoined by itself within its backoff, and the
  window reconnected by itself ([us1-reconnected.png](us1-reconnected.png)).

## Not covered by this walk

- US1.4 (the host stops while the control plane stays up) is covered in memory by
  `ControlEndToEndTests.aHostThatGoesEndsItsClientsConnectionAndOnlyThatOne`. It was not
  walked on screen.
- Frame H's own strip (T028). The window still says "Not connected to the daemon".
- The "Install your agents" sheet stayed up throughout. It was left alone because a
  scratch copy shares the real app's defaults.
