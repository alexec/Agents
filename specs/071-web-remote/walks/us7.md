# US7 walk: the control plane goes away and comes back

**Date:** 2026-10-01

**Commit:** the T062 commit on `agents/write-spec-first-version`.

**How it was run:**
- The scratch root was `/tmp/run-webus7`, launched with `--no-window`.
- Headless Chrome 154 drove the page, using `Web/test/walk/us7.mjs`.
- `/tmp/us7-control.sh` stopped and started the scratch control plane, and froze and thawed its host.

**The turn:**
- A real Claude turn ran seven Bash commands.
- It was started on the host's own socket (`rpc.py start`), which allowed each permission as it came. That kept the agent working while the control plane was away.

## Results

| Scenario | Target | Measured |
|----------|--------|----------|
| 1. Control plane stopped mid-turn | **Can't reach the control plane** within 5 s, greyed out, sending off, draft kept | The banner showed in **0.2 s**: a stopped process closes the socket, so the page knows at once. The columns were at opacity 0.55, Send was off, and the session row and the chat were still there. The draft was kept, and more could be typed while it was away. |
| — | the agent works on | After 60.2 s away, the agent had finished, with 99 entries on the host. |
| 2. Control plane started again | reconnected and caught up within 5 s, no reload, nothing typed lost (SC-009) | It reconnected in **2.8 s** and was caught up, the turn's report on the page, in **2.8 s**. There was no reload (a marker set on `window` survived). The draft read "A draft typed before it went away. And more typed while it was away." Send was on again. |
| — | the page holds what the host holds | It ended with the host's last words. |
| 3. A host goes offline, the control plane stays | that host's projects greyed and saying so; the rest working | *THIS MAC* read "Offline: what's shown is from when it was last heard.", with its projects greyed. The open chat said "This host is offline. What's shown is from when it was last heard; nothing can be sent until it's back." Send was off, and there was no control-plane banner. After the thaw it was online again in **1.1 s**. |

The page had no errors of its own. Chrome logged its own `ERR_CONNECTION_REFUSED` for each retry during the outage, which is expected.

## What changed for this

**Faster heartbeat and retries.** The page's link now beats every 2 s and allows 2 s for an answer, so a hung control plane is noticed in 4 s. Retries are at most 4 s apart (`loopbackTiming` in `session.ts`), so a returning control plane is caught within 5 s. They were 5 s, 3 s and up to 10 s. That's affordable because the page and its control plane share a machine.

**Typing while down.**
- The prompt is never disabled, so typing goes on while the link is down; only Send and Attach are off.
- The columns are greyed without `pointer-events: none` on the whole of them, so the chat can still be read and scrolled. Only their controls are inert.

**An offline host.**
- The host is shown offline in the projects column, the chat and the new-session form.
- An answer refused because a host is offline says so, and the card stays waiting instead of reading "answered elsewhere".

## Not covered here

**How fast the host shows as offline.** The frozen host (SIGSTOP) took **63 s** to show as offline. That's the control plane's own timeout for a host's uplink (058), which no client can shorten. The spec gives scenario 3 no time limit. A host that exits closes its uplink, which the control plane hears at once.

## Screenshots (`walks/us7/`)

- `us7-1-before.png`: mid-turn, with the draft typed.
- `us7-2-down.png`: the banner, greyed, with the draft added to while down.
- `us7-3-back.png`: just back.
- `us7-4-done.png`: the finished turn, caught up.
- `us7-5-host-offline.png`: the host frozen.
