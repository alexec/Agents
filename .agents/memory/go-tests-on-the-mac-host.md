---
name: go-tests-on-the-mac-host
description: Since #4709 Go runs on the Mac host; agentsd's tests need go.sh's clean env, its TMPDIR, go.mod's toolchain, and no store syncs
metadata:
  type: project
---

Since #4709 (2026-11-11) `Go/scripts/go.sh` runs the Mac's own Go, not Colima. Four things made agentsd's tests pass and run fast there; keep them:

- **A clean environment** (`env -i`, PATH of GOROOT/bin and the system only): a session's PATH has a real `codex` in `~/.local/bin` before a test's fake one.
- **TMPDIR = `~/Library/Caches/Agents-build/go/tmp`**: tests fail with TMPDIR under `/var/folders`, `/tmp` or `/private/tmp` (symlinks and `/private` paths), as CI's `$RUNNER_TEMP` never is.
- **GOTOOLCHAIN = go.mod's `go` line**: the Homebrew Go (1.27) failed an allocation bound under -race, and govulncheck built with 1.26 cannot read 1.27's stdlib.
- **`store.SyncWrites = false` in agentsd's TestMain**: on darwin Go's `File.Sync` is F_FULLFSYNC, about 3.7 ms a write against 0.2 ms for fsync(2); it doubled the package's time (335 s against 196 s).

**Why:** without them, `go-changed.sh` on an agentsd branch took 6m08s on the host against 2m41s in Colima, with dozens of failures that CI never sees.

**How to apply:** do not pass a caller's environment through go.sh. Point a new durable write at `store.WriteAtomically`, so tests skip its sync. Check a darwin-only test failure with `Go/scripts/go.sh`, not a bare `go test`. See [[check-go-darwin-before-arming]].
