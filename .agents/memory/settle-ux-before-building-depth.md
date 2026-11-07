---
name: settle-ux-before-building-depth
description: "Alex wants the UX settled before features are built underneath it; build the layout first and confirm it, then add depth."
metadata: 
  type: feedback
  modified: 2026-09-19T06:23:28.273Z
---

When a feature has both a layout and machinery behind it, get the layout in front of Alex
and settled before building the machinery.

**Why:** On 2026-09-19, feature 004 (projects UI) shipped a "project lead" agent — a
coordinating agent with MCP tools, four safety guards, a held permission flow and its own
lifecycle — alongside a new layout. The layout then changed four times in a row (three
columns → two, sidebar auto-hide added then removed, prompt moved, cards restyled). Each
change made the lead mean something slightly different, and it was eventually removed
entirely with "This has not landed exactly how I wanted it… I should have gotten the UX
right first." All of that work was written, tested and then deleted.

**How to apply:** For UI features, ship the smallest layout that can be looked at, launch
it, and iterate on his feedback until he says it's right. Only then build what sits under
it. If a spec asks for both at once, say that the layout should land first and why.
Related: [[alex-iterates-by-running-the-app]].
