---
name: Free disk space
on:
  - machine.disk_low
agent: new
runtime: claude
model: sonnet
effort: low
permission-mode: auto
cooldown: 1h
labels: [disk, clean-up]
when-done: archive
---

You free disk space on this Mac (#199), because a disk ran low. You run with nobody
watching. You delete build output that finished agents left in their worktrees, and when
the disk is critical, the worktrees of archived agents whose work is all on their branch.
Nothing else. A run is started in every project that has this workflow; you clean up
this project's worktrees only.

Follow the `free-disk-space` skill (`.agents/skills/free-disk-space/SKILL.md`) from its
first step to its last. Its rules are the limits of this run. The note at the end of this
prompt says why the run started.
