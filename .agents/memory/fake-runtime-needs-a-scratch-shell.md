---
name: fake-runtime-needs-a-scratch-shell
description: "AGENTS_TEST_SEARCH_PATHS is dead since the Go host; a scratch app started the REAL grok. Put the fake first on a scratch SHELL's PATH and check runtimes/list."
metadata:
  type: feedback
  modified: 2026-10-23T01:14:01.945Z
---

The Go agentsd (since #1314) ignores `AGENTS_TEST_SEARCH_PATHS`, though
`scripts/install-fake-runtimes.sh` and specs still name it. On 2026-10-22 a scratch run
with it started the person's real Grok CLI (grok-4.7, read files in the scratch folder)
until stopped with `agents/stop`.

The Go host finds a runtime on its login shell's PATH (`$SHELL -lc 'printf %s "$PATH"'`,
`Go/internal/agentsd/runtimes.go` searchPaths), first match wins. What works: a scratch
script as `--env SHELL=/tmp/<x>/shell` that, on `-lc`, sets PATH with the fake runtime's
folder first and runs the command; otherwise execs zsh.

**Why:** a real runtime costs money and acts on files; the old override fails silently.
**How to apply:** before prompting a fake runtime on a scratch root, run
`rpc.py $ROOT call runtimes/list` and abort unless its `path` is the fake one. Related:
[[the-run-app-skill-is-how-to-test-a-change]].
