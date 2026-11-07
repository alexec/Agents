---
name: stacked-accessibility-labels-crash-appkit
description: "An .accessibilityLabel on a view whose child Text already has one crashed the Mac app (SIGSEGV, stack guard) the moment anything queried accessibility."
metadata:
  type: project
  modified: 2026-10-01T21:55:34.373Z
---

Found 2026-09-25 walking 041: a diff row put `.accessibilityLabel("Added: …")` on a `CodeLine` whose
own `Text` already carried `.accessibilityLabel(text)`. The row rendered fine, but the first
accessibility query (VoiceOver, or `ui.swift find/dump/press` in the run-app skill) died in
`AccessibilityNode.accessibilityLabel → resolvedRole(forPlatformElement:)` with EXC_BAD_ACCESS at a
stack guard page. It reproduced on relaunch every time.

**Why:** SwiftUI resolves a label by asking the platform element for its role, which asks the child
for its label, and the stacked overrides recurse until the stack runs out. Plain rendering never
touches that path, so it only shows up under accessibility.

**How to apply:** give a composite row one element with `.accessibilityElement(children: .ignore)`
plus a single label (fixed in `1f49a50`). When a walk's `ui.swift` call returns `? ·` and the scratch
app is gone, check `~/Library/Logs/DiagnosticReports/Agents-*.ips` for this stack before blaming the
walk. See [[drive-a-scratch-window-by-pid-with-ax]].

#71 (2026-10-01): the Files pane's rows crashed the same way once an open file changed on disk.
Cause: under `.textSelection(.enabled)` each `Text` is backed by an AppKit `AppKitTextInteractionView`,
and CodeLine's own `.accessibilityLabel` on that Text made node and platform view ask each other.
Fixed in 662beef4, MERGED ff to main 2026-10-01 and #71 closed (not pushed or live): CodeLine has no label, FileLineRow
is one element "Line N: …". Reproduced and proven by run-app + ui.swift dump/find after `echo >>`.
While the screen is locked any AX client, even in-process, gets AXApplication back as its own child,
so an AX repro has to wait for unlock; an in-process NSHostingView walk sees only AXUnknown nodes
(SwiftUI's accessibility stays off without a real client), so it can't stand in as a test.
