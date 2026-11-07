---
name: merge-wave-never-waits-for-build-lease
description: "As the merge agent, build at once instead of waiting in line for the \"build\" lease"
metadata:
  type: feedback
  modified: 2026-10-04T20:44:59.376Z
---

As the merge-wave agent, never wait in line for the "build" lease. Just build (Alex, 2026-10-04, wave 16).

**Why:** the merge wave matters more than the lanes holding the lease. Waiting 30+ minutes behind them stalled the wave.

**How to apply:** when merging a wave, run the build steps straight away even if lease_resource says the lease is held. Still take it when it's free and release it after, so lanes see the load. Lanes still follow [[build-lease]].
