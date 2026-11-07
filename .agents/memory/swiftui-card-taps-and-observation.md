---
name: swiftui-card-taps-and-observation
description: "In this app, a tap gesture on a glass card never fires, and an @Observable field read only inside a Binding getter never redraws."
metadata:
  type: reference
  modified: 2026-09-25T04:15:22.756Z
---

Two things cost an hour on the 017 workflow page, both found by driving the real app
rather than by reading the code:

**A tap gesture on a card does not fire, and neither does a button behind the glass.**
`.onTapGesture` on the card never fired. A `Button` *behind* the content in
`.background` passed a synthesised System Events click on 2026-09-19 and then **never
received a real mouse click** on 2026-09-20 — Alex clicked every part of the card and
only the *Ran →* button in front did anything. What works is what `AgentCard` always
did: **the whole card is the `Button`**, its content the label, `.glassEffect(.regular
.interactive())` on the label, `.buttonStyle(.plain)` — and nested `Button`s inside the
label (play, a link) keep their own clicks, because the innermost button wins its hit.
`WorkflowRow.swift` is the worked example (`38572f3`). The earlier note here claiming
the button-behind pattern worked was wrong; a synthesised click is not a mouse.

**An `@Observable` field read only inside a `Binding` getter never invalidates the
body.** `AppModel.openWorkflow` was read only in the getter handed to `NavigationStack`,
so setting it redrew nothing and opened nothing. Observation registers what a body reads
while it runs, not what a stored closure reads later. `AppModel.selection` had survived
the same mistake only because `ContentView`'s body reads it in three other places. Read
the value in `body` and close over it.

**Padding outside a `.plain` button takes no clicks.** After the paper theme (glass →
`paperRaised`), `SelectCapsule` had `.padding` after `.buttonStyle(.plain)`: the runtime
select only opened on its word, and felt dead. Put padding inside the label and end it
with `.contentShape(Capsule())`, as `PaperButtonStyle` does (fixed `f5b97f1`,
2026-09-24). AXPress and pid-posted clicks cannot show this; a real click can:
launch with `--front` and post `CGEvent`s to `.cghidEventTap` at the capsule's edge,
old build as the control. Only when Alex is away ([[drive-the-scratch-app-only-when-alex-is-away]]).

**How to apply:** none of these shows up in a build or a test — the app has no view tests — so
a view change that depends on either needs the app driven by hand. Related:
[[agents-app-hosts-this-session]].
