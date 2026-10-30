# Decide and tell (#1083), two weeks on (#1092)

Measured on 2026-10-29, from the transcripts of the 1,657 sessions on Alex's Mac and the issues labelled `decided`. The cut is 2026-10-16 01:54 UTC, when PR #1093 merged. The transcripts on this Mac start on 2026-10-08, so the "before" period is 7.8 days. The "after" period is 13.8 days. `scripts/form-stats.py` makes the form numbers again.

## Forms

| | Before (10-08 to 10-15) | After (10-16 to 10-29) |
|---|---|---|
| Sessions started | 481 | 1,109 |
| Forms asked | 215 | 242 |
| Forms per day | 27.6 | 17.5 (−37%) |
| Forms per 100 sessions | 44.7 | 21.8 (−51%) |
| Answered forms where Alex took the recommended option for every question | 116 (55%), 14.9/day | 67 (36%), 4.8/day (−68%) |
| Answered forms with no recommended option | 39 (19%) | 88 (47%) |
| Questions where Alex took another option | 65 of 323 (20%) | 35 of 130 (27%) |
| Hours agents waited on forms that changed nothing | 65.8 (8.4/day) | 57.3 (4.2/day) |

The median wait for an answer stays at about 2 minutes.

- Agents ask much less often. Per session, they ask half as often.
- The forms that changed nothing fell by two thirds per day. Most of those still asked are what AGENTS.md keeps for Alex: installs on Alex's devices, deploys, accounts, releases and leases.
- The forms that remain are mostly real choices: nearly half have no recommended option, and Alex took another option more often than before.

Week by week after the change: 136 forms from 10-16 to 10-22 and 86 from 10-23 to 10-29, so the count goes on falling.

## Decided items

- 564 issues have the `decided` label. 396 of them have a `Decided:` comment, with 781 `Decided:` lines in all. A further 630 pull requests say `Decided:` in their bodies.
- Alex reversed **6** decisions (about 1% of the 781 lines on issues):
  1. #1092: milestone 0.4 → backlog (2026-10-17).
  2. #1117: "MCP servers and their secrets belong to the machine" withdrawn; a secret belongs to the person who configured it (2026-10-15).
  3. #2658: "seven part issues" → one branch and one PR for all of Auto runtime (2026-10-27).
  4. #2658: "the new milestone goes after 0.13 Hosted" → Auto runtime became the open milestone, in front of Hosted (2026-10-27).
  5. #2801: "the patch process starts with v0.13.0" → it starts now, with 0.12.3 (2026-10-27).
  6. #2798: the Remote's "Open this on your Mac or the web page" line → no line (2026-10-29).
- Alex changed part of 2 more (#1428, the connectors Agents makes come from a built-in marketplace; #1924, agent configuration syncs with no switch). Those add to the decision rather than reverse it.
- 5 of the 6 reversals are about order and scope (milestones, how a feature is split into PRs, when a process starts). None is about code. Each cost at most one PR, as #1083 expected.
- Reversals were found by searching the comments on `decided` issues for Alex's words (overrule, withdrawn, reversed, "Alex (date)") and reading each match. A reversal that Alex made only in a chat, with no comment on the issue, is not counted.

## Does a "Decided" item need a line in the Brief?

Decided: no line in the Brief, because Alex reversed about 1 in 130 decisions, and 781 decisions in 14 days would be about 56 lines a day: noise that would bury the needs and notices the Brief is for. The `decided` label stays, so a search still finds them all (https://github.com/alexec/Agents/issues?q=label%3Adecided). Alex can overrule.

Two things could change this later:

- If reversals grow (more than about 5% of decisions), show only scope and milestone decisions in the Brief, since these are the ones Alex reverses.
- If Alex wants a daily look, a once-a-day digest of the scope and milestone decisions would be fewer lines than one per decision.
