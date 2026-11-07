---
name: honest-basic-terms
description: Alex 2026-10-22 — use the most honest basic terms (machine, machine provider, folder, worktree, project); a big rename is fine before 1.0; project ≠ repo
metadata:
  type: project
---

Alex (2026-10-22): the product's nouns must be the most honest and basic ones, and a big rename across the codebase is fine before 1.0. Umbrella #2313, with #2314 (workspace provider → machine provider), #2315 (project → folder), #2316 (host/server → machine for the computer; Agents Host keeps its name), #2317 (project = what people work on: an org record folders join, with tracker, review, CI, reporting; needs a spec). All in milestone 0.11.1 Honest terms, between 0.11 and 0.12 (Alex, 2026-10-22), parked until 0.11 ships. #2315 must land before #2317.

**Why:** "project" was used for one folder on one machine, the JetBrains sense; Jira/GitLab/Azure DevOps use it for the thing people work on. A project is not a repository: the repo only carries `.agents/` between clones. "Workspace" is Coder's and GitHub's word for a machine.

**How to apply:** in issues and docs say machine, machine provider, folder, worktree, project as #2313 defines them. Do not argue rename cost as a reason to keep a word. See [[v0-breaking-changes-ok]], [[local-first-no-cloud-login]].
