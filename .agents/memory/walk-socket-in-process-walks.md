---
name: walk-socket-in-process-walks
description: #1172 walk socket — how a Debug scratch window draws/presses itself; the non-obvious AppKit/SwiftUI traps found in the spike
metadata:
  type: reference
---

The run-app `walk.py` drives `App/Sources/Walk/*` (Debug + `--walk` only). Traps found in the
2026-10-16 spike (`.agents/reviews/walk-socket-1172/spike.md`):

- SwiftUI builds AX elements only after `AXEnhancedUserInterface` is set on NSApp.
- Children via legacy `accessibilityAttributeValue:` (table rows); labels via modern selectors
  (SwiftUI's `AccessibilityNode` answers only those and does not declare the protocol).
- SwiftUI List reverts `AXSelected`/`selectRowIndexes`/`expandItem`; use
  `_userSelectSingleRow:` and `_doUserExpandOrCollapseOfItem:isExpand:optionKeyWasDown:`.
- `cacheDisplay` misses SwiftUI's view-less layers and scroll content; the shot is a layer
  render after forcing display, plus glass/clip/selection/terminal fills. On screen it draws
  GPU-backed layers black, so unlocked shots use shot.sh.
- A field's field editor is shared: check `editor.delegate === field` before typing.
- NSLog from the sandboxed window is redacted; walk logs use Logger category "walk" (public).

Related: [[locked-screen-means-wait-for-unlock]], [[drive-a-scratch-window-by-pid-with-ax]].
