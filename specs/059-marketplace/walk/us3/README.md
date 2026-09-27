# 059 · US3 walk (2026-09-26)

A scratch app (`/tmp/run-059`) with its own personal home, pointed at `walk/fixture-server.py`.
The stand-in has a second commit, `9ca8b54`, made by real git in `make-http-fixtures.py`. In
it, `nested`'s SKILL.md gains a line and a new `references/y.md` appears; `plain` is untouched.
`POST /_advance` moves HEAD to that commit.

Set-up over the socket: `nested` and `plain` added to You and `nested` added to project `work`,
all at `d43951d`, then `/_advance`.

- **The check** (`a-update-available.png`): Shared ▸ Skills shows **update** on `nested` only.
  The daemon logged `update-check 2 skills → available: nested`. `plain`'s folder was the same
  at the new commit, so its recorded commit moved forward to `9ca8b54` with no update shown.
  The row's accessibility label says "update available".
- **Update** (`c-update.png`): the sheet lists "changed SKILL.md" and "new references/y.md",
  shows the new text in the reader, and offers **Update**. After it (`a-after-update.png`):
  - the chip is gone and Taken at reads `9ca8b54`;
  - the reader shows the new line;
  - `y.md` is on disk;
  - the lock kept `installedAt` and moved `updatedAt`;
  - the old copy is in `/tmp/run-059/trash/`, not the person's Trash.
- **Remove** (`a-remove-confirm.png`, `a-after-remove.png`): asks "Move plain to the Trash?",
  then removes the folder and its lock entry and puts the folder in the scratch Trash.
- **Project page** (`d-project-update.png`, `d-project-after-remove.png`): the row shows
  **update**, **Update…** and **Remove**. The project's check reused the cached answer for
  that source rather than asking again within the hour. Update from there brought in `y.md` and
  a new `computedHash`. Remove emptied `.agents/skills` and left `skills-lock.json` with no
  skills.
- **Fixed after the first shots:**
  - The detail's four buttons wrapped. Forcing them to full width then pushed the whole window
    sideways. Update and Remove now have a row of their own.
  - The detail's SKILL.md didn't reload after an update.
  - The Update sheet showed "Installs 0", because an update comes from the lock, not a search.
- **Not walked on screen:** the "your edits will be lost" confirmation (unit-tested as
  `edited`). Also, the check asks each source at most once an hour, so a page opened before
  the source moves shows no update until then; that is FR-018, working as specified.
