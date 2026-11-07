---
name: pid-scroll-events-do-not-leave-follow-mode
description: "Scroll events posted to the app's pid move the chat but never count as the reader scrolling; reading mode needs HID-tap events with the window in front."
metadata:
  type: feedback
  modified: 2026-09-26T04:42:10.303Z
---

CGEvent scroll-wheel events sent with `postToPid` (even with continuous + scroll-phase fields set) do scroll the chat, but `onScrollPhaseChange` never sees `.interacting`, so ChatTranscript stays in follow mode and snaps straight back to the foot. To test "scrolled up to read" (paging back, nothing trimmed while reading) the scratch window has to be frontmost, the pointer moved over the chat, and the events posted to `.cghidEventTap` with phases began/changed/ended (field 99 = 1/2/4, `scrollWheelEventIsContinuous` = 1).

**Why:** found proving the transcript trim on 2026-09-25; the pid route wasted two attempts.

**How to apply:** that takes the screen, so lease `screen` and ask Alex first if he is active (he said yes, and a minute was enough); hide the scratch app afterwards to give his window back. See [[drive-a-scratch-window-by-pid-with-ax]], [[drive-the-scratch-app-only-when-alex-is-away]].
