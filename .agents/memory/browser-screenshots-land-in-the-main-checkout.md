---
name: browser-screenshots-land-in-the-main-checkout
description: browser_take_screenshot writes only under ~/Agents (or its own cache); a bare file name lands in Alex's main checkout
metadata:
  type: project
---

`browser_take_screenshot` refuses `/tmp`: its allowed roots are the browser's output cache and `/Users/alexcollins/Agents`. A bare `filename` such as `web-x.png` is written to the main checkout's root, among Alex's files (#3921, 2026-11-12).

**Why:** a screenshot left there is an untracked file in Alex's checkout, and could be committed by someone else.

**How to apply:** give a path in your own worktree's ignored `build/` (`.agents/worktrees/<lane>/build/web-x.png`), then move it to `/tmp/run-<slug>-…` for `pr-shots.sh`. See [[use-browser-tool-not-chrome]].
