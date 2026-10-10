---
diataxis: explanation
description: What the project is working towards now, what it is not, and how the work is checked against it.
---

# Direction

What we are building towards now, so a week of busy work can be checked against it.
Alex owns this page. The direction check-in reads it every few days, and every issue
names the goal it serves, or says it serves none.

## The milestone: an alpha for developers

Developers who build Agents from source can run several coding agents at once, see which
one needs them, and answer it from the Mac, the phone or a browser, and it holds up all
day.

## Goals

1. **It holds up.** Nothing crashes, hangs or loses work, and cost stays flat as hosts,
   clients, projects and sessions grow. Bound what is held or returned before reaching
   for concurrency.
2. **Three clients, one product.** The Mac window, the Remote and the web page do the
   same thing the same way, or the parity table says why not.
3. **What merges has been used.** A UI change counts as done once someone has run it,
   on a scratch app or by Alex, not when its pull request lands.
4. **A newcomer gets going.** A fresh clone builds, pairs a phone and runs a first agent
   by following the docs, with nothing missing.
5. **Agents land work on their own.** Issue → lane → pull request → CI → merge runs with
   nobody watching, and asks Alex only what is his to decide.

## Not now

- Publishing to the App Store, TestFlight, signing or a download.
- Hosted cloud: #59, #60 and #61 stay parked.
- New runtimes. Goose and auto-approve were tried and closed.
- Unlocking the Mac or keeping it awake to walk a change.
- Machinery under a layout Alex has not settled. Get the layout in front of Alex first.

## Signs we are in the weeds

- One area is reworked again and again in a few days. finish_turn was made optional,
  split, then removed between 2026-10-08 and 2026-10-09.
- More than five merged UI changes nobody has run (the `needs-walk` label).
- Issues that serve none of the goals above keep getting started.
- Most of a week's merges are tooling for agents rather than the product.

## How it is checked

- **The direction check-in** (`.agents/workflows/direction-check-in.md`) runs on Monday
  and Thursday mornings. It counts the merges since the last check-in against each goal,
  looks for the signs above, labels unwalked UI changes `needs-walk`, writes a short
  report under `.agents/reviews/direction/`, and asks Alex two or three questions.
- **Fill free slots** starts walk lanes instead of new enhancements while more than five
  issues are labelled `needs-walk`.
- When the goals here stop being right, change them here first.
