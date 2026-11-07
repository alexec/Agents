---
name: full-autonomy-goal
description: "Alex 2026-11-07 — the goal is full autonomy; every step that needs a human should become an automation, filed as work"
metadata:
  type: project
  modified: 2026-11-07T18:46:31.297Z
---

Alex, 2026-11-07: "one of our goals is essentially full autonomy, so whenever we encounter something that requires a human, we should be automating it."

**Why:** Alex's hands (codes, CAPTCHAs, passkeys, Allow presses, account set-up) were the main thing that stalled lanes and epics (#3411, #3415, #3420, #2227).

**How to apply:** when a lane hands Alex a step (`hand_to_person`, `alex-todo`, `## What Alex does`), treat it as a sign of missing automation: file (or ask the Product Owner to file) an issue under the autonomy epic that removes that step next time. Still ask Alex by a form for what stays Alex's by AGENTS.md (money, hard-to-undo, outside publishing) until a standing rule says otherwise. Tools so far: `browser_*`, `drive_screen`, `hand_to_person`, `~/.agents/mail` (.eml), email-mcp (#1780, Fastmail mailbox). Related: [[agentstest-mail-rule]], [[use-browser-tool-not-chrome]].
