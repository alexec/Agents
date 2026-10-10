---
name: Fix failed checks
on:
  - checks.failed:
      repo: alexec/Agents
agent: new
cooldown: 5m
labels: [ci]
permission-mode: auto
enabled: false
when-done: archive
---

A pull request's checks failed. The event's data says which PR, branch and jobs.
Use the `ci` server's `failed_log` to read each failed job. If it is a test known to be
flaky under load, use `rerun_failed`. Otherwise fix it on the PR's branch in a worktree,
push, and use `comment_on_pr` to say what you changed.
