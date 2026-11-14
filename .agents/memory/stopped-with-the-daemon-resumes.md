---
name: stopped-with-the-daemon-resumes
description: "a lane \"stopped with the daemon\" was often not picked up: a start that died lost the list (#4917, fixed); wait ~10 min, then archive it and start a new lane in its worktree"
metadata:
  type: feedback
  modified: 2026-11-02T15:43:23.715Z
---

A wait that clears with "stopped with the daemon" does not mean the lane is gone: after Agent Loops restarts, the lane starts again by itself in its worktree.

**Why:** 2026-11-02, #3256: the Scrum Master started a second lane in the same worktree; it committed, rebased and stopped the first lane's scratch app and fixture server before it saw the first lane, and a build failed on the shared build.db lock.

2026-11-04 to 11-06: after several restarts, lanes (#3438, #3489, #3617, the #3420 lead) stayed "Needs you: Stopped with the daemon" for 10+ minutes and never came back; archiving them (worktree kept) and starting a new lane there that first commits and pushes what is left worked every time.

2026-11-06 20:28: the #3653 lead came back after ~15 min, after the Scrum Master had already asked to archive it and queued a second lead (now a duplicate). Wait 20+ min, and check read_session's last activity, before replacing a lead.

2026-11-12, #4917: the cause. A start that died before it picked the agents up (an install makes 1–15 such starts) lost the list: it was in memory only, and the start wrote alive.json without it. Since #4917, alive.json keeps it (`pickUp`) until each agent is picked up. If a lane still stays stopped after that fix, file a new bug with the daemon log around the restart.

**How to apply:** after "stopped with the daemon", check list_sessions for that id (Working again?) and wait on it; start a new lane only if it is still stopped some minutes later. Related: [[a-stopped-lane-may-be-alex]].
