---
name: scratch-copies-share-the-real-apps-defaults
description: "Since #1029 (PR #1039, 2026-10-15) a walk/branch copy of the window keeps its defaults in its own domain via WindowDefaults.store; never use UserDefaults.standard or a bare @AppStorage in App/ or Shared/UI."
metadata:
  type: project
  modified: 2026-10-15T14:09:15.936Z
---

Every copy of the window is one bundle ID (`com.alexecollins.agents.host` since #4225; the App Store
window's `com.alexecollins.agents.store` went in #4229): one standard defaults domain. Since #1029 (PR #1039, merged 2026-10-15), every window key goes through
`WindowDefaults.store` (App/Sources/WindowDefaults.swift). That is `.standard` for Alex's window,
`<bundle>.walk.<walk>` for a run-app window (`--walk`), and `<bundle>.root.<name>` for a branch build
on another root. `scripts/check-window-defaults.py` (an AgentsHost pre-build phase) fails on a bare
`@AppStorage` or `UserDefaults.standard`. The Remote has its own `WindowDefaults` (`.standard`) for
Shared/UI.

Removal: every launch sweeps walk domains whose `walks/<walk>` folder is gone and root domains not
launched for 7 days (plist file included). run-app `stop.sh` deletes its walk's domain. A scratch
Agents Host keeps its settings in `<root>/hostSettings.<suffix>.json`.

**Why:** walks wrote Alex's real window's selected project, new-session project and folds (seen
2026-10-15: `/tmp/run-m984/work`, `/tmp/run-huddle/work`).

**How to apply:** any new window key goes through `WindowDefaults.store` with a plain name (no
`.root:` or `.walk:` suffix: the domain is the scope). On 2026-10-15, with Alex's go-ahead, the #1029
lane removed the old scratch keys. The real window's `newSessionProject` and `sidebar.folds` still
held /tmp values from walks on older code; they were left alone. Related:
[[drive-a-scratch-window-by-pid-with-ax]], [[launch-the-app-with-a-clean-environment]].
