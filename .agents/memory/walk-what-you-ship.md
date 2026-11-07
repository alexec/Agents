---
name: walk-what-you-ship
description: Never ship a build whose final code was not run on a scratch Mac app; a walk of an earlier commit does not cover later edits or a conflicted merge.
metadata:
  type: feedback
  modified: 2026-09-26T18:52:43.144Z
---

Before ship-app, the exact commit being shipped (after any last edit and after merging main in) must have been run on a scratch copy of the Mac app with the run-app skill, with the changed feature driven and seen. Tests and both-scheme builds are not enough, and "you'll see it on the real app" is never the test.

**Why:** 2026-09-26 I shipped 057 (ffb4d7c6) after walking only 10e824f4; the hover edit and a six-file conflict resolution with Send now (shared ChatActions, Remote) were never run. Alex: "How can we ship without testing on the Mac."

**How to apply:** after the last change to a lane, run it on a scratch root; if a merge of main had conflicts, walk both features the conflict touched. Don't offer "merge and ship, you look on the real app" as an option. If the screen can't be had (Alex active, Mac locked), say so and hold the ship rather than skip the walk. See [[drive-a-scratch-window-by-pid-with-ax]], [[ship-app-skill]], [[drive-the-scratch-app-only-when-alex-is-away]].
