# 059 · Interop with the real `skills` CLI (T055, SC-005), 2026-09-26

Against the real skills.sh and GitHub, on throwaway homes, with a scratch app whose personal home
was the CLI's (`AGENTS_PERSONAL_HOME`).

| Check | Result |
|---|---|
| `npx skills add twostraws/swiftui-agent-skill -g -y --skill swiftui-pro` (default agents) → the app | Listed in Shared ▸ Skills with its source; update check `current`; not called edited |
| The app searches "swiftui" live | 99 results, in skills.sh's order, `expo` marked known |
| The app previews and adds `avdlee/…/swiftui-expert-skill` | commit `b24e68a`; 49 files from skills.sh checked against GitHub, 2 PNGs from GitHub; folder tree `4b58ee6b…` as measured in research R3 |
| `npx skills list -g` | Lists the app's `swiftui-expert-skill` with source `avdlee/swiftui-agent-skill` |
| The app adds it to a project; `npx skills list` there | Listed as a project skill with its source |
| `npx skills update -g -y` | "All global skills are up to date": the CLI accepts the app's recorded hash |
| Commit the project, clone it, delete `.agents/skills`, `npx skills experimental_install` | Restored; `diff -r` against the app's copy: identical |

## Found and fixed

- **"Edited" was a false alarm for the CLI's skill.** `twostraws/swiftui-agent-skill` has a
  symbolic link in the skill's folder. The CLI follows it when copying, so the folder on disk
  never hashes to the tree SHA the CLI records. The same happens to anything the app adds (the
  app leaves links out). "Edited" is now judged against:
  - a hash of the folder as written, which the app keeps in its sidecar;
  - for a project, the lock's `computedHash`, which the CLI also takes of the folder as written.

  A personal skill the CLI added has neither, and is no longer called edited on the tree SHA
  alone (test `aCLISkillWhoseFolderDiffersFromItsTreeIsNotCalledEdited`).

## Noted, not changed

- `npx skills add … --agent claude-code` (Claude only) copies the skill into
  `~/.claude/skills`, not `~/.agents/skills`, and still records it in `~/.agents/.skill-lock.json`.
  The app manages only what is in `~/.agents/skills`, so it doesn't list that skill as its own.
  054 leaves `~/.claude/skills` to Claude and its tools; the docs say so.
