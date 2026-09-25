# 042 walk notes

## Baseline (T002)

`swift test` in `Packages/AgentsKit` at `6246cb0` (this branch with `main` `0ea158d` merged in,
before any 042 code), run once in a detached copy at `/tmp/042-base`, on 2026-09-25:

- 1729 tests in 187 suites, all passed, exit 0.

A later failure is this lane's only if it is new against this, and only after six runs on
both commits (the suite is flaky under load).
