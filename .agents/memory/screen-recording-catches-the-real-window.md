---
name: screen-recording-catches-the-real-window
description: "ScreenCaptureKit \"including app\" takes every process with the bundle id, so a scratch recording caught Alex's real Agents window; filter windows by pid"
metadata:
  type: feedback
  modified: 2026-10-16T16:43:23.845Z
---

On 2026-10-16 (#1078 videos) `record.swift` used `SCContentFilter(display:including: [app])` for the scratch window's app. Alex's real Agents window has the same bundle id, was in front at the same place, and its real sessions (Go migration, #1126 …) were recorded into u3.mp4. The file was local only and was deleted at once.

**Why:** an `SCRunningApplication` filter covers every process with that bundle id, not one pid. A scratch copy and the real window are the same app to it.

**Fixed for good (2026-10-16):** scripts/video now records frames from the scratch window's walk socket (shots drawn in its own process, ~12 fps, locked screen fine), so no other window can be in them; record.swift is gone. Each take also fails if the window shows "alex", the global CLAUDE.md or ASD-STE100, and the root has a disk-free-override.

**How to apply (any other capture):** filter by windows whose `owningApplication.processID` is the scratch pid (and refresh the list for popovers). Look at a contact sheet of every recording before keeping it. Also: a scratch window opens off screen (no AX, no capture) while Alex's front app is full screen; ask Alex to leave full screen. Related: [[drive-the-scratch-app-only-when-alex-is-away]], [[never-copy-real-agent-records]].
