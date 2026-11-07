---
name: mac-swipe-walk-needs-hid-and-a-wide-window
description: Walking a trackpad swipe on a scratch window needs HID-tap scroll events with the window in front, and a window wide enough for the sidebar.
metadata:
  type: feedback
---

Proving SwipeToShowPane (2026-09-29): scroll events sent with postToPid never reached an NSEvent local monitor. Events posted to `.cghidEventTap` did, once the scratch app was activated and the cursor warped over the chat (lease `screen`, ask Alex first if he's active). Activating the scratch app re-tiled its window to 1280pt at x=704, which is too narrow for the sidebar (SidebarFrame.fits). It looked as if the swipe did nothing. Re-read the window bounds after activating, and widen it with AX kAXSize/kAXPosition.

**Why:** two misses came from the window having moved and one from the narrow width, not from the code.
**How to apply:** tools were in /tmp/nits-tools (sel = AX select row, hid = activate+warp+HID swipe, size = AX move/resize). Log to a file rather than NSLog, because the scratch app's NSLog never showed in `log show`. The scratch app writes sidebar.isOpen into Alex's defaults, so restore it afterwards. Related: [[pid-scroll-events-do-not-leave-follow-mode]], [[scratch-copies-share-the-real-apps-defaults]].

**Row swipe actions can't be driven (2026-10-01, #74):** phased continuous HID scroll events, with the window in front and the pointer on the row, only scroll the List column sideways. NSTableView's row swipe tracking (`.swipeActions`) never starts, so Archive/Bring Back by swipe can't be walked synthetically. Don't spend a screen lease on it; the walk is Alex's. The real crash it was chasing reproduced on Alex's live window anyway (Agents-2026-10-01-170818.ips).
