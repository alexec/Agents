---
name: driving-agentsd-by-hand
description: How to launch a scratch agentsd and drive agents/start over daemon.sock without the runtimes dying — env, cwd URL, and npx cold-start collisions.
metadata:
  type: feedback
---

Driving a scratch `agentsd` directly (not through the app) to prove something needs three
things right, each of which fails in a way that looks like a product bug:

1. **Do not launch it with `env -i`.** The runtime then answers
   `Error(code: -32000, message: "Authentication required")` and every agent dies as
   `processDied` within a second. Pass the real environment with only the leak removed:
   `env $(env | grep -o '^CLAUDE_[A-Z_]*' | sed 's/^/-u /') …/agentsd --root /tmp/scratch`.
   [[launch-the-app-with-a-clean-environment]] is about `open`-ing the **app**, which is a
   different thing — macOS gives a second bundle copy its arguments and not its environment,
   so `--root` is what survives there.
2. **`cwd` in `agents/start` must be a `file://` URL.** A bare path decodes to a non-file
   `URL` and the daemon dies in `NSTask` with
   `'*** -[NSConcreteTask setCurrentDirectoryURL:]: non-file URL argument'`. The app always
   sends a file URL, so this is a hand-driving hazard only.
3. **Stagger concurrent starts by a few seconds.** Three cold `npx` runtime launches at once
   collide and all three die before any turn begins.

Also: the daemon exits ~10s after it is holding nothing with nobody connected, so start it
and connect in the *same* command — a separate tool call is long enough for it to go.

**Why:** each of these presents as "the feature is broken" — dead agents, a crashed daemon,
no assertion held — when it is the harness. Diagnosing them cost most of an hour on 024.

**How to apply:** when a hand-driven walk shows agents dying instantly, read
`daemon.log` for `Authentication required` and the daemon's stderr for an `NSException`
before suspecting the code under test. See also [[the-agents-app-hosts-these-sessions]] —
kill only the scratch daemon, by the pid in its own `daemon.lock`.
