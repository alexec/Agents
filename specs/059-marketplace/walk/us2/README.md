# 059 · US2 walk (2026-09-26)

A scratch app (`/tmp/run-059`) with its own personal home, pointed at `walk/fixture-server.py`.
Project `work` is a git repository with one skill of its own (`run-app`).

- **Frame D** (`d-project-crop.png`): the project page's **Skills** section sits after Workflows,
  with a count, **Reveal in Finder**, **Add skill…**, the "committed with the project" line, and
  the project's own `run-app`.
- **The sheet from a project** (`c-project-detail.png`): Add to starts on "work (project)",
  **Goes to** is the project's `.agents/skills/nested`, the dots say "every agent in this
  project", and the button reads **Add to work**. The script warning is shown as for You.
- **After Add** (`d-after-add-crop.png`): `nested` is listed with `skills.sh`, its source and
  commit, above `run-app`, and the count is 2.
- **On disk:**
  - the skill's four files and `skills-lock.json` (the CLI's project shape, `computedHash`
    43d79cc…) are untracked;
  - nothing is staged and no commit was made;
  - `.claude/skills → ../.agents/skills` is there;
  - nothing went to the personal `~/.agents`.

  The other untracked files (AGENTS.md, CLAUDE.md, .claude/plugins) are 054's project layout,
  made when the project was added.
- **Not walked on screen:**
  - a worktree's page; the unit test `aWorktreeGetsItsOwnCopy` covers the worktree getting its
    own copy;
  - switching Add to in the sheet and watching the **added** marks follow.
- **Not built here:** Remove on a project skill (US3). The project half of Add to offers one
  project, the one the sheet was opened for or the selected one, not a list of every project.
