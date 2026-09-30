# The suites against main (T103, T104)

2026-09-29 and 30, the branch after merging main twice (e682db9a, 14884087; main at 84519ec8).
Main ran in a detached worktree at `/tmp/cp-main`. The load average stayed about 11
throughout, from other work on the Mac.

## Builds (T103, T104)

After each merge, and again after the fixes below:
- the `Agents`, `AgentsStore`, `AgentsHost`, `Remote` and `RemoteWidget` schemes, with
  warnings as errors, as main now asks;
- both packages with their tests;
- the Linux gate: `build-linux-agentsd.sh --check` and `build-linux-control.sh`, x86_64 and
  aarch64.

All passed.

## The six-run comparison

`swift test` in `Packages/AgentsKit`, one run at a time, branch and main alternating so both
saw the same load:

| Run | Branch (2,973 tests) | Main (2,886 tests) |
|---|---|---|
| 1 | 1 issue | 12 |
| 2 | 4 | 27 |
| 3 | 2 | 30 |
| 4 | 41 | 15 |
| 5 | 10 | 25 |
| 6 | 2 | 33 |

Every run took about 40–45 s on both.

- **What still fails fails on both.** These are timing tests that miss under this load:
  `aQuietDirectLinkLosesAfterTheWindow` (6/6 on the branch, 5/6 on main),
  `a100SkillReconcileIsQuick`, `aWaitSurvivesTwentyRestarts` and
  `theSettlingPauseIsNotStartedAgainByARestart`.
- **Two failed once on the branch only:** `aHostEnrolsAndAPairedWindowReachesItThroughTheControlPlane`
  and `endingARouteStopsItsProcessAndFailsTheCallWaitingOnIt`. Each passes alone, and neither
  failed in the earlier runs.

`Packages/ControlPlane` (main has none): 52 tests, 12 runs, every one passed. A run takes
10 s with CryptoKit, and took 30 s before.

## Found and fixed

The first six branch runs all failed, with 17–53 issues, against three of six on main. Seven
tests failed on the branch every time and never on main, all at about 16 s.

- **Main's `RawHTTP` blocked the pool.** A stack sample of a full branch run showed six of the
  ten pool threads in `read` inside `RawHTTP.send`.
  - `Task.detached` still runs on the cooperative pool, and the MCP bridge it waits for needs
    that pool to answer.
  - With the branch's extra tests the pool ran dry, and every other test waited out its
    ten seconds.
  - It now reads off the pool (`offThePool`).
- **`ControlAgreement` computed P-256 in Swift on every platform.** That is about 185 ms a
  multiplication in a debug build, and eighty control tests dial at once.
  - Where CryptoKit is present it now does the curve. The Swift arithmetic is kept for
    Linux, as `portablePublicKey` and `portableSharedSecret`, and `ControlAgreementTests`
    holds it to CryptoKit's bytes and the known answers.
- **`noCallSiteNamesAStateColourItself`.** The store window's first run outlines its usual
  choice in the accent, as frame K was approved. It is on the allow-list now.
