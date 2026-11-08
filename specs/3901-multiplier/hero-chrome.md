# Wireframe: more on the Multiplier page (part 2)

Alex asked for these parts on 2026-11-07: the Huddle, the earned achievements, personal bests, and a
way back to the page. The first Multiplier page (`wireframe.md`, #3904) does not change. This file adds
to it. The figures are made-up examples.

**The Mac window only.** The web page does not have the Multiplier page yet (Alex, 2026-11-07), so it
keeps its Achievements page. The Remote never gets the Multiplier page.

---

## 1. The page

```
┌─ Agents ─────────────────────┬──────────────────────────────────────────────────────────┐
│ [+ New Session]              │                                                          │
│                              │   ○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○   │◄── the crowd (A):
│                              │    ○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○○    │    one Blob for each
│                              │                        ◉                                 │    engineer, you in front
│ ▾ Usage                      │                     Last 7 days                          │
│   ✕ Multiplier       ◄──(B)  │                                                          │
│   $ Cost                     │                       3.2×                               │◄── the Multiplier,
│   # Tokens                   │           the work of 3.2 engineers                      │    still the largest
│   ◷ Time                     │                                                          │
│   ≡ Events                   │      23            128             5                     │
│                              │   PRs merged   engineer-hours   agents now               │
│ ▾ Agents             (5)     │                                                          │
│   ● Rewrite settings sheet   │       Best week 4.1×   ·   Most at once 9                │◄── personal bests (D)
│   ◐ Check the build          │                                                          │
│                              │          🏅 🏅 🏅 🏅 🏅          5 of 7                   │◄── earned badges (C)
│                              │      Next: pair a phone or a browser                     │
│                              │                                                          │
│                              │            + 0.3×  #1234 merged                          │◄── rises and fades
│                              │                                                          │
│                              │     ⌘0 Multiplier · ⌘N new session · ↑↓ move · ⌘F find   │
└──────────────────────────────┴──────────────────────────────────────────────────────────┘
```

From top to bottom, the parts are in order of importance. Every new part is smaller than the
three numbers.

---

## 2. The parts

### A. The crowd: one Blob for each engineer (Alex's idea, 2026-11-07)

The Huddle, with as many Blobs as the Multiplier says: at **300×**, 300 Blobs.

- **You are in front:** one white Blob, as in the Huddle. The engineers are the light-blue Blobs behind you.
- **How many:** the whole part of the Multiplier (3.2× is 3 Blobs). The fraction is one more Blob, drawn
  faint (0.2 is 20% opaque). `— ×` is you alone.
- **The band does not grow:** it is a band of a fixed height above "Last 7 days", the width of the page.
  With few Blobs, they are the Huddle's size. With more, they get smaller and pack closer, in rows that
  go back and up, like a crowd in a stadium. At 300× each Blob is about 10 pt.
- **A cap of 1,000 Blobs.** Past that, one Blob is 10 engineers, and a small line under the band says
  so ("each Blob is 10 engineers").
- **They move:** when the Multiplier goes up past a whole number, a Blob pops in at the back. A revert
  takes one away. Now and then, a few of them blink. Under Reduce Motion they appear and go with no
  movement, and nobody blinks.
- **Drawn in one `Canvas`, not one view for each Blob:** 300 views with eyes that follow the pointer
  cost too much. Only your Blob in front has the Huddle's eyes that look around.
- **Why:** the number says "300×", and the crowd shows it. A screenshot shows which app made it and
  what the number means.

### B. The way back

At the moment, the page shows only when no session and no page is selected. After you click a
session, you cannot get back to the page.

- **A Multiplier row**, first in the sidebar's Usage group, always shown. It takes the place of the
  Achievements row.
- **View ▸ Multiplier, ⌘0.** ⌘1…n are the inspector panes, so ⌘0 is free and is next to them.
- The window still opens to the page.
- The card that shows when an achievement is earned opens this page, not the Achievements page.

### C. The earned achievements

The achievements move here from their own page.

- **Earned ones only, as a row of badges:** one SF Symbol for each achievement. Its tooltip and
  accessibility label give the title and the day ("First agent started, 12 Oct 2026").
- **"5 of 7"** next to the row, and one **Next:** line with the first achievement not earned yet
  and its "how". When all are earned, there is no Next line and no count.
- **Nothing earned:** no row. The empty state (`— ×`) shows only "Next: start an agent and let it
  run a turn."
- **Removed from the Mac window:** the Achievements row in the sidebar, the Achievements page,
  View ▸ Achievements, and the list under Time's charts.
- **Earned:** the badge counts in (it scales up from nothing, about 0.5 s). Under Reduce Motion it
  shows with no movement.

### D. Personal bests

- **Best week:** the highest Multiplier of a calendar week (Monday to Sunday, local time), from
  lineage, counted the same way as the Multiplier (#3902).
- **Most at once:** the most agents in a turn at the same time, ever.
- Counted on the host and sent in `multiplier/state` and `multiplier/changed` (#3903). They are not
  counted on the window.
- **A new best:** the figure counts up, and the rising line says `New best week: 4.3×`.
- **Hidden until there is one full week of lineage.** Before that, "best week" means nothing.
- **This is not a streak:** nothing is lost when you miss a day, and there is no notification
  (the epic's rule, #3901).

---

mac: wireframe only, remote: by design (never on the Remote), web: not yet (Alex, 2026-11-07).
