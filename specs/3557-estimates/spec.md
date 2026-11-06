# Estimates from past work (#3557)

Status: the spike (#3558) is done. This file holds its decision. The daemon method (task 2), the Work pages (story 3) and estimate against actual (story 4) build on it.

## The question

How do we find the closed issues that are like a new one, and how accurate is an estimate made from them?

## The data

The data came from the lineage cost store on Alex's Mac (`lineage-cost.json`, #2350) on 2026-11-05, with labels, dates, parents and PR sizes from GitHub.

- The store starts on 2026-10-30. It holds 869 nodes: 316 issues, 324 PRs and 229 sessions.
- **305 issues are closed. 293 of them have a cost** and are not epics. 97 of them are children of 14 epics.
- **For an issue, the store has** dollars, input and output tokens, turns, working and waiting seconds, `firstAt`, the PRs that fix it and its sessions. A PR also has its outcome, `endedAt` and its failed checks. The resolve cache has the labels for 156 issues.
- **An issue's actual figure is** its own cost plus the cost of the PRs that fix it, as `Rollup` adds them up. Its **working time** is the sum of `workingSeconds`. Its **lead time** is from its first `firstAt` to when the issue closed.
- **The spread is wide.** The median issue cost $2.79, P25 $1.29, P75 $8.24, P90 $20.39, and the most expensive one $243.

## The matching rules that were tried

The backtest estimated each closed issue from the issues that closed before its work started. The estimate is the median of the matched issues, and the range is their percentiles. The backtest compared the estimate with the actual figure.

- **Error:** the median of `max(est/actual, actual/est)`. For example, ×1.5 means the estimate is typically 1.5 times too high or too low.
- **Within ×2:** how often the actual figure is between half the estimate and double it.

Dollars, on the 97 children of epics, with at least 5 matches:

| Rule | Issues it could estimate | Error | Within ×2 | Inside P25–P75 | Median matches |
|---|---|---|---|---|---|
| All past issues (the baseline) | 97 | ×3.03 | 29% | 42% | 222 |
| (a) type + level + `area:` | 6 | ×1.43 | 83% | 33% | 7.5 |
| **type + level** | 66 | ×1.54 | 67% | 48% | 20.5 |
| `area:` only | 58 | ×2.65 | 43% | 40% | 12.5 |
| (b) (a) + body size | 1 | — | — | — | 5 |
| type + level + body size | 48 | ×1.57 | 67% | 46% | 11.5 |
| the same epic | 37 | ×1.73 | 57% | 38% | 7 |
| text match on title and body (the top 15) | 97 | ×1.91 | 53% | 57% | 15 |
| **type + level → type → all (the fallback chain)** | **97** | **×1.56** | **66%** | **52%** | **31** |

- The **type** is the label `bug` or `enhancement`. The **level** is `story`, `task`, `spike` or `bug`, or none.
- On all 293 closed issues, the fallback chain gives ×1.77 for dollars and ×1.69 for working time.
- When the 52 issues made before the store started are left out, the numbers stay the same (dollars ×1.52, working time ×1.45).

What the backtest found:

- **The type and level label carries the signal.** The median cost of an `enhancement` `story` is not the same as that of a `bug`.
- **`area:` does not help.** With it, too few past issues match: only 6 of the 97 children have 5 or more. With 1 or more, the range is too narrow (it holds the actual figure for 12% of the issues). `area:` by itself is worse than type and level.
- **The size of the body or of the PR does not help.** It cuts the sample and does not make the error smaller. The PR size is known only after the work, so it cannot be an input anyway.
- **A text match is not better** than type and level (×1.91 against ×1.54), and it costs more to run. We do not use it.
- **The minimum sample matters little** between 3 and 12 (×1.62, ×1.56, ×1.62, ×1.62). 5 is the best.

## Accuracy per figure (the fallback chain, the 97 children of epics)

| Figure | Error | Within ×2 | Inside P25–P75 | Inside P10–P90 |
|---|---|---|---|---|
| Dollars | ×1.56 | 66% | 52% | 80% |
| Output tokens | ×1.67 | 62% | 48% | 71% |
| Working time | ×1.45 | 72% | 51% | 74% |
| Lead time | ×2.44 | 40% | 56% | 81% |

The ranges are calibrated: P25–P75 holds the actual figure about half the time, and P10–P90 about 8 times in 10. **Lead time is poor.** It depends on the queue (lanes waiting for places, CI, Alex's approval), not on the work.

## Epics

For each of the 12 closed epics with 2 or more children in the store, the backtest estimated each child from the issues that closed before the epic started (none from the epic itself), and then added up the estimates.

| How to add up | Dollars: error | Dollars: bias (actual/estimate) | Working time: error |
|---|---|---|---|
| The sum of the children's medians | ×1.69 | ×1.52 (too low) | ×1.35 |
| The sum of the children's means | ×1.57 | ×0.95 | ×1.13 |
| **A simulation: draw one match per child, add them up, 2,000 times; the median** | **×1.45** | **×0.97** | **×1.14** |

- The sum of medians is too low: a cost is skewed to the right, and a few expensive children make most of an epic's cost.
- The simulation's P10–P90 held the actual figure for 8 of 12 epics in dollars and for 11 of 12 in working time. Its P25–P75 held it for only 4 of 12 in dollars.

## Decision

- **The matching rule:** match closed issues with the same type label (`bug` or `enhancement`) and the same level (`story`, `task`, `spike` or `bug`, or none). When fewer than 5 match, use the same type only; then all closed issues in the repo. Do not use `area:`, `feature:`, the body or the PR size, or a text match.
- **The figures:** dollars, output tokens and working time (the agents' hours). Lead time shows as a range only, under the words "lead time varies with the queue", because its error is ×2.4.
- **What an issue's estimate shows:** the median and the P10–P90 range ("8 in 10 like it land here"), and the matches it used: "from 31 closed stories". The backtest held the actual figure inside the range 80% of the time for dollars.
- **What an epic's estimate shows:** for each open child, an estimate as above. The epic's estimate is a simulation with a fixed seed: draw one match per open child, add up, 1,000 times. Show the median and the P10–P90 of the sums, plus what the closed children actually cost.
- **The minimum sample:** 5. When the fallback chain ends with fewer than 5 closed issues in the repo, show no figures, only "not enough history yet (3 closed issues)".
- **The epic's own node** is not used as a match. Epics are estimated only from their children.
- **Only issues that closed with a PR that fixes them** go into the matches, so that an issue closed as not planned does not make the estimates too low. The backtest gives the same numbers with this rule (dollars ×1.56, working time ×1.45).

Decided: type + level with the fallback chain, P10–P90, minimum 5, and a simulation for epics, because the backtest gave them the smallest error with a range that holds what it says. Alex can overrule.

## The daemon method (#3559)

`lineage/estimate` (capability `lineage.estimate/1`) answers `LineageEstimate` for an issue or an epic, with the rule above, from the totals in `lineage-cost.json` and the plan from `forge/plan`. Its code is `Go/internal/lineage/estimate.go`.

- **Figures:** dollars by currency, input and output tokens, working time, lead time and cycle time, each as the median and P10–P90. A figure fewer than 5 matches have is absent.
- **Landing date** (Alex, 2026-11-05): `landsAt` is the start plus the cycle time. The start is the request's `startAt`, or now. An epic's time follows its steps: in each draw, the longest child of each step, added up over the steps.
- **An epic** is an issue with children in its plan, or labelled `epic`. Its open children are estimated and added up by the simulation; `spent` is what its closed children cost.

Decided: the method is not tagged `web` yet, because a `web` method needs its Swift `WebSignatures` and story 3 (#3560) adds it with the first client that shows it. Alex can overrule.
Decided: with no `startAt`, the remaining work starts now, because the closed children are already out of the estimate. Alex can overrule.

## The Work pages (#3560)

`lineage/estimate` is tagged `web` now, with its `WebSignatures` row. An open issue's page asks the machine that keeps its links, and shows one line under the title (`EstimateWords`, `Web/src/model/estimate.ts`):

- **An issue:** "Estimate: about $5.87, 85.5K output tokens, 2h 58m of work (from 8 closed stories)". The P10–P90 range and the lead time ("it varies with the queue") are in its help on the Mac and the web page; on the Remote a tap shows them under the line.
- **An epic:** "Estimate for 3 open children: about …", and "Spent $14.21 on 2 closed children". In the Plan, each open child has "est. $5.87 · 2h 58m" after its cost (Mac + web, as the Plan).
- **Too little history:** "Not enough past work to estimate", and nothing else.

Decided: the hours are the agents' working time, not the cycle or lead time, because the backtest found working time the most accurate (×1.45) and lead time poor (×2.44). Alex can overrule.
Decided: no landing date on the pages yet, because the cycle time needs the start of work (#3562), which has only just begun to be recorded. Alex can overrule.
Decided: a closed issue shows no estimate, because story 4 (#3561) shows the estimate against the actual there. Alex can overrule.

## Estimate against actual (#3561)

- **Kept at the start.** Each issue in `lineage-cost.json` gets `estimate` (`LineageEstimateKept`: the medians of dollars, output tokens and working time, the matches and the rule) once its work has started (`startedAt`, else `firstAt`) and its labels are known. It is made from the issues that merged **before** that start, so an issue banked before this change gets the same estimate it would have had (the backfill), and it is made once.
- **An epic's** is made when `lineage/estimate` asks for it: every child of its plan estimated as open, by the simulation, from the issues merged before the first start on the epic or any child. It is kept on the epic's node when the store has one.
- **`lineage/estimate`** adds `kept` (the estimate at the start) and, for a closed issue or epic, `actual`: an issue's own cost and its PRs'; an epic's, its own and every child's.
- **Work's page** of a closed issue or epic: "Estimated $3.20, 2h 10m of work; actual $4.10, 3h of work" under the title (`EstimateWords.actualWords`, `actualWords` in `Web/src/model/estimate.ts`). Nothing with no estimate then.
- **Reports ▸ Value** (the web page): "Estimates were off by ×1.5 in dollars and ×1.4 in hours of work (the median of 12 closed issues)". The error is the backtest's, the median of `max(est/actual, actual/est)`, over the issues with an estimate whose last PR merged in the report's range, not epics.

Decided: the error is over the report's range (a month by default), not a fixed 30 days, because every other figure on Reports ▸ Value follows the range. Alex can overrule.
Decided: the hours are the agents' working time, as on the open page (#3560). Alex can overrule.
Decided: an epic's estimate at its start counts the children its plan has now, because the plan at its start is not kept; a child added later makes the estimate higher. Alex can overrule.
- **The lead's closing summary** (#3590): the app tool `estimate_issue`, read-only, says `lineage/estimate` to an agent, with the same line once the issue or epic is closed. The `lead` skill closes the epic, asks it, and puts the line in its summary comment.

Decided: an app tool (`estimate_issue`, method `issues/estimate`), not the daemon posting the line on the epic, because the lead already writes the summary and other agents (the Product Owner, when it files an epic) can ask for an estimate too. Alex can overrule.

## What the backtest does not cover

- **6 days of history.** The store starts on 2026-10-30. These numbers will change as history grows. Story 4 (estimate against actual) keeps track of them.
- **Sessions with no link** (229 nodes) are cost that no issue has. An issue's actual figure is therefore lower than what it really cost.
- **One repo, one person's way of work.** The labels follow #3265's levels. In a repo that does not use them, the chain falls back to the type, then to all issues.

## How it was run

The script that fetched GitHub and ran the backtest was a one-off in `/tmp`; it is not product code. To run it again: read `lineage-cost.json`, take each closed issue's cost as `Rollup` adds it up, take its labels and parent from GitHub, and for each issue estimate from the issues that closed before its first `firstAt`.
