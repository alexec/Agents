---
name: animated-top-inset-loops-appkit-layout
description: "An animated height change in the Mac chat's top safeAreaInset, while a turn runs, looped AppKit's layout until NSGenericException quit the window (#5189); open/close it unanimated on the Mac"
metadata:
  type: project
  modified: 2026-11-13T16:00:00Z
---

#5189: pressing the plan row of the top Now card (the chat's `.safeAreaInset(edge: .top)` in
`App/Sources/Chat/ChatView.swift`) open and closed with `withAnimation` while the agent worked
quit the window: "more Update Constraints in Window passes than there are views"
(`_postWindowNeedsUpdateConstraints` ← `NSHostingView.setNeedsUpdate` ← `HostingScrollView.updateContext`),
or a SIGTRAP in `_NSViewLayout` for the same loop. Idle, it never crashed.

**Why:** the animated inset re-measures the transcript's scroll view each frame, and with the
working foot updating too, the layout pass never settled. Fixed by toggling the top card's rows
without animation on macOS (`openOrClose` in `Shared/UI/Chat/NowCard.swift`); the chevron's
rotation still animates, as it changes no layout.

**How to apply:** do not animate a height change of anything in the chat's top inset on the Mac.
Repro that catches it at once: run-app at the default 1058x662 window, fake `grok` with `plan`
then `work 60`, and `walk.py press "<plan step>"` twice 0.3–0.6 s apart; a 1300x900 window with
1.5 s gaps did not crash. See [[chat-transcript-scroll-geometry-lies]].
