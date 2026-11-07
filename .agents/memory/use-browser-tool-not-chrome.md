---
name: use-browser-tool-not-chrome
description: "Alex 2026-11-06 — drive web pages with the app's browser_* tools, not the private Chrome that the sign-up skill's cdp.mjs starts"
metadata:
  type: feedback
  modified: 2026-11-07T04:42:29.415Z
---

Use the app's own browser tools (`browser_navigate`, `browser_snapshot`, `browser_click`, `fill_secret`, `hand_to_person`, …) for web work such as sign-ups, not a Chrome started by `.agents/skills/sign-up/cdp.mjs`.

**Why:** Alex said "use your browser tool, not chrome" on 2026-11-06, after the #3477 Slack sign-up was done in the cdp.mjs Chrome on port 9231. The sign-up skill still describes cdp.mjs, so it is out of step with this.

**How to apply:** For a sign-up or any page, lease nothing by hand (the browser tools take the browser lease) and use the browser_* tools. Use `hand_to_person` for CAPTCHAs and codes, and `fill_secret` for passwords. Do not run tokens through Bash checks unless they are needed. Related: [[accept-terms-for-alex]], [[privacy-cards-alex-enters]].
