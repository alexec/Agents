---
name: flaky-stop-before-pickup-test
description: The AgentsKit suite is broadly flaky on this Mac under concurrent lane load — many different tests, not two; measure before blaming a branch.
metadata:
  type: project
---

The AgentsKit package suite fails **intermittently and broadly** on this Mac, not in one or
two known spots. Measured 2026-09-24 over six clean full-suite runs on each of two commits:

- pre-merge `3e0abba`: **4 of 6 runs failed**, across five different tests —
  `aCleanFinishAStopAndADeathSayNothing`, `eachNewProcessIsCountedFromNothing`,
  `stoppingMeansNoMoreEvents`, `aPickedUpAgentKeepsTheCommandsItsNewRuntimeDoesNotRepeat`,
  `aStoppedAgentIsPickedUpRatherThanCopied`
- post-merge `a354d19` (024 added): **3 of 6 runs failed**, same character

Most failures are `eventually` exhausting its 10s timeout, so a failing run often takes
~10–13s instead of ~3s. The cause is load: several agent lanes run on this Mac at once.

**Why:** a small sample lies badly here. Four pre-merge runs came up clean by luck, which
made a merge look like it had introduced `eachNewProcessIsCountedFromNothing` — six runs
showed it failing pre-merge too. Nearly reported a regression that did not exist.

**How to apply:** never conclude a branch broke the suite from one or two runs. Run the full
suite **at least six times on both commits** and compare the *sets* of failing names and the
failure rate. A test that fails on both sides is environmental. Re-running a single failing
test alone almost always passes and proves nothing. See [[three-lanes-one-tree]].

**2026-09-24:** `aStoppedAgentIsPickedUpRatherThanCopied` (DaemonTests) fails nearly every time
when run on its own with `--filter` (launchCount 3, expected 2), on main `20e1492` without 029
as well. It passes inside the full suite. It depends on test order, not on load; the full suite
is the verdict.
