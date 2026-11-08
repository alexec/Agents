---
name: release-live-builds-220
description: "Alex 2026-10-04 (#220): live app, Agents Host and Remote ship as Release builds; run-app walks stay Debug"
metadata:
  type: project
---

Alex decided #220 on 2026-10-04: ship Release builds for the live app (window + Agents Host) and the Remote; keep Debug for run-app walks on scratch roots.

**Why:** every live perf number (CPU reports, signposts) was unoptimised Debug code, so it didn't reflect what users would see.

**Built 2026-10-04:** branch agents/fix-github-issue-220 at 40f9b089 (unmerged, not shipped) adds a `Live` config (optimised, dev-signed) because `Release` is the App Store archive config (Apple Distribution) that devicectl/~/Applications can't run. Products move to `build/DD-*/Build/Products/Live` and `Live-iphoneos`. `ship.sh --build-only` builds without installing. A cold Live host build takes ~27 min. Gains measured 5–20%; switch/chat-open timings are still to be measured on an unlocked Mac. The live app loses DEBUG-only scratch hooks.

**How to apply (original plan):** a lane changes `.agents/skills/ship-app/scripts/ship.sh` (it builds `-configuration Debug` around lines 178–182) to Release, leaves run-app on Debug, and re-measures perf budgets on Release. Until it lands, live numbers are Debug. Compare perf only like for like. See [[ship-app-skill]], [[robustness-performance-priority]].
