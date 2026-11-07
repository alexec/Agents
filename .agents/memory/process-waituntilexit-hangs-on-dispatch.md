---
name: process-waituntilexit-hangs-on-dispatch
description: Foundation Process.waitUntilExit can block for ever on a GCD worker thread after the child has exited; end on terminationHandler instead.
metadata:
  type: reference
---

On 2026-09-24 (027, `GitProcess.run`) a `git` child exited, its pipes hit EOF, and
`process.waitUntilExit()` on a `DispatchQueue.global()` thread never returned — the test
run sat at 0% CPU until killed; `sample <pid>` showed it parked in `-[NSConcreteTask
waitUntilExit]`.

**How to apply:** when a daemon-side subprocess must be awaited, set
`process.terminationHandler` (leave a DispatchGroup / resume a continuation there) and
drain pipes on their own queues; do not call `waitUntilExit` off the main thread.
`LoginShellPath.readFromLoginShell` still uses the old pattern — don't copy it.
A filtered `swift test` that hangs silently is worth `sample`-ing before anything else.
