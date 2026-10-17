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
archived: true
---

A pull request's checks failed. The event's data says which PR, branch and jobs.
Use the `github` server's `get_job_logs` (with `run_id` and `failed_only: true`) to read
each failed job. If it is a test known to be flaky under load, use `actions_run_trigger`
with `method: rerun_failed_jobs`. Otherwise fix it on the PR's branch in a worktree, push,
and use `add_issue_comment` on the PR to say what you changed.
