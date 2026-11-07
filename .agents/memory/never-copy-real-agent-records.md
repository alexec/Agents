---
name: never-copy-real-agent-records
description: "Never seed a scratch root with copies of the real root's agents/ or archive records; the scratch daemon resumes the live sessions in the real repo."
metadata:
  type: feedback
  modified: 2026-10-04T17:52:32.035Z
---

Never seed a scratch root by copying `~/Library/Application Support/Agents/agents/` (or any real agent records, even just agent.json without transcripts). On 2026-10-04 (#227) a scratch agentsd on such a copy resumed the live sessions (wave merge agent, #204, the project lead) as duplicates working in the real worktrees, and started an agent for one of them. The project lead stopped it.

**Why:** a daemon resumes every non-archived agent it finds, and their cwd is the real repo; duplicates could merge or ship twice.
**How to apply:** seed synthetic agents with run-app's `--seeded` / scripts/seed-archived.swift or the review's tools/rp-seed, with folders under the scratch root. Reading the real records (python, read-only) is fine; starting a daemon on them is not. This supersedes the "copy the live root's agents/" advice in [[agents-app-hosts-this-session]].
