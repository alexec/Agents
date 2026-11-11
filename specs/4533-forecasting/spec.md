# Forecasting when work lands (#4533)

Status: the spike #4523 is done. This file holds its decision. The daemon method `lineage/forecast` (#4526) builds on it.

## The question

Does a Monte Carlo over the folder's throughput forecast when an epic or a milestone lands better than today's cycle-time estimate does?

## The data

- **The store is too short.** `lineage-cost.json` has merged PRs from 2026-10-30 only: 11 days, less than one 14-day window. So the backtest reads the forge. `fetch.py` dumps every issue of `alexec/Agents`: its dates, labels, milestone, parent, blocked-by and the PRs that closed it. No titles. The dump stays out of the repo.
- **History:** 41 days of landings, 2026-09-28 to 2026-11-10. 2,084 issues closed as completed, 1,776 of them by a merged PR.
- **Throughput:** the issues that landed with a merged PR (epics left out). A median of 43 a day, P10 6, P90 84.
- **Groups:** 39 closed epics with children (a median of 6 children, 14 with 8 or more) and 20 closed milestones (a median of 28 items).
- **Landed:** an issue lands when its first PR merges, or when it closes if no PR closed it. An epic or milestone lands when its last item lands.

## How the backtest works

`backtest.py` forecasts each group at a cut-off from what was known then, with 1,000 draws and a fixed seed. Then it compares the forecast with when the group landed.

- **Cut-offs:** when the epic was filed (for a milestone, when its first issue was filed), and again when half its items had landed.
- **Error:** the median of `|P50 − actual|` in days, and the median of `max(P50/actual, actual/P50)`, with both at least 6 hours.
- **P85 held:** how often the group landed by the P85 date. A good P85 holds about 85% of the time.
- **Scope:** every method gets the items the group finally had. This makes every method look better than it will be live (see "Scope grows", below).

The methods:

| | Method |
|---|---|
| A | Start plus the median cycle time of one issue (today's `landsAt` for an issue) |
| B | **Today's epic estimate** (`estimate.go`): each draw takes the longest cycle time per blocked-by step and adds up the steps |
| D | Throughput by **day**: each draw resamples days of the last 14, thins each landing by the group's share, and counts days until the items are done. The share is the median share that past groups had |
| H | **The same by hour**: resamples hours of the last 14 days |
| F | max(D, B on 14-day cycle times): blocked-by steps as a floor |
| I | Items ÷ a past group's items per day, drawn per draw |
| J | H on the items filed at the cut-off × the past groups' median scope growth |
| K | H at half, with the group's own share so far |
| H0 | H with the share the group really had (a ceiling, not a method) |

## What the data says

Epics, forecast when the epic was filed:

| Method | Epics | Median error | Ratio | P85 held |
|---|---|---|---|---|
| A. cycle median of one issue | 39 | 0.9 d | ×3.94 | 41% |
| **B. today: steps of cycle draws** | 39 | 1.0 d | **×1.93** | 92% |
| D. throughput by day | 39 | 2.9 d | ×4.59 | 97% |
| F. D with steps as a floor | 39 | 4.1 d | ×5.68 | 97% |
| **H. throughput by hour** | 38 | 1.0 d | **×2.20** | **82%** |
| I. past epics' items per day | 31 | 0.6 d | ×1.98 | 100% |
| J. H, filed scope × growth | 36 | 0.8 d | ×2.17 | 81% |
| H0. H with the real share | 39 | 0.6 d | ×1.81 | 95% |

Epics with 8 or more children, at filing:

| Method | Epics | Median error | Ratio | P85 held |
|---|---|---|---|---|
| B. today | 14 | 1.9 d | ×3.59 | 100% |
| D. throughput by day | 14 | 1.4 d | ×2.43 | 100% |
| **H. throughput by hour** | 11 | **0.4 d** | **×1.42** | **91%** |

Milestones, forecast at the first issue:

| Method | Milestones | Median error | Ratio | P85 held |
|---|---|---|---|---|
| A. cycle median of one issue | 19 | 7.2 d | ×29.6 | 21% |
| B. today | 19 | 5.3 d | ×4.01 | 47% |
| D. throughput by day | 19 | 4.5 d | ×3.50 | 89% |
| **H. throughput by hour** | 11 | **2.7 d** | **×2.85** | 55% |
| J. H, filed scope × growth | 11 | 15.8 d | ×5.30 | 73% |

Re-forecast when half had landed: every method gets better, because the tail is short (an epic's last half lands in a median 0.4 days). B is ×2.14 and H is ×2.33 on epics. On milestones B is ×3.59 and H is ×2.83. K (the group's own share so far) is no better than H on epics (×2.17), and much worse on milestones (×12).

Window: 7, 14 and 28 days give H ×2.42, ×2.20 and ×2.31 on epics. The window length does not matter much.

The figures move by about ±0.05 in the ratio from one seed to the next. The groups are few: 39 epics, 20 milestones, and fewer for methods that need 5 past groups.

## What this means

1. **Throughput by day is wrong for this folder.** An epic lands in a median of 1.0 day from filing. Its share of the day's landings is about 6%, so a day-level draw gives about 2.6 children a day and says 2 to 3 days for 6 children. In fact a lead starts the children at once, and they land in parallel within hours. The day bins are too coarse, and the share is not steady over a day. D is ×4.6 against today's ×1.9.
2. **By the hour, throughput is as good as today on a typical epic and better on a large one or a milestone.** On all epics, H and B have the same median error (1.0 day). B's ratio is a little better (×1.93 against ×2.20). On epics with 8 or more children, H is ×1.42 against ×3.59, and on milestones ×2.85 against ×4.01. Today's step sum grows with the number of steps, but large epics run their steps faster than one cycle time each.
3. **Only H's P85 means what it says.** H's P85 held 82% of the time on epics and 91% on large epics. B's held 92% to 100% on epics, so its range is too wide, and 47% on milestones, so it is too late there. A forecast that says "85%" must hold about 85% of the time.
4. **Blocked-by steps do not help as a floor.** F (throughput with the step sum as a floor) is the worst method (×5.7). The step sum uses cycle times that hold queue waits, so as a floor it pushes every date out.
5. **Scope grows, and nothing predicts how much.** At filing, 81% of an epic's final children exist. A milestone has only 20% of its final items when its first issue is filed. Scaling by past growth (J) does not help an epic and makes a milestone much worse (×5.3). Every figure above uses the final scope, so a live forecast of an early milestone is a floor, not a date.
6. **The issue's premise, "×2.6 today", is about one issue.** An epic's `landsAt` today is already B, the step sum, not the cycle median. A (the cycle median of one issue) is ×3.9 on epics, and its P85 held only 41%.

## The decision

`lineage/forecast` (#4526) forecasts an epic's or a milestone's landing date with **method H**.

- **Method:** a Monte Carlo of 1,000 draws with a fixed seed. Each draw resamples hours of the window, keeps each landing in that hour with the chance `share`, and counts hours until the open items are done. It returns the P50 and P85 dates. It does not return P10.
- **Window:** the last **14 days**, by hour. A landing is an issue (not an epic) closed by a merged PR, from the store. With fewer than 7 days of history, no forecast.
- **Share:** the median of the shares that closed groups of the same kind (epics or milestones) had over their lives. A group's share is its items ÷ all the folder's landings from its start to its last landing, by the hour. With fewer than 5 closed groups of that kind, no forecast. Do not use the group's own share so far (K): it was no better.
- **Items:** the open items filed now. No growth factor. The forecast says its count: "6 open children: P50 Thursday, P85 Friday".
- **Blocked-by steps:** do not enter the date. The method can report the steps that are left as context.
- **Milestones:** the same method, on the milestone's open items, with the milestones' share. When less than half of the milestone's items have landed, the forecast says the scope is still growing (a milestone grows about 5× after its first issue).
- **Today's epic `landsAt` (B):** stays in `estimate.go` until #4526 lands, then the epic estimate shows the forecast's dates instead. An issue's own `landsAt` (A) is not part of this decision.
- **Keep what it forecast.** Keep the P50 and P85 dates, the window, the share and the open count with the epic's kept estimate when the forecast is made, so a report can score it when the group lands (#4533's scoring story).
- **Score it again later.** This backtest has 39 epics and 20 milestones from 41 days. Run `backtest.py` again when the store holds 60 days or 80 closed epics. If B beats H then, return to B.

Decided: method H (hourly throughput, 14-day window, past groups' median share, no step floor, no growth factor), because it equals today's step model on a typical epic, beats it on large epics and milestones, and its P85 is the only one that holds about 85% of the time. Alex can overrule.

## What `lineage/forecast` built (#4526)

- **When an epic lands:** method H as decided, in `Go/internal/lineage/throughput.go`. The landings are the store's issues (not epics) with a merged PR, in the epic's repo. A closed epic is one whose node is closed, or, when the store has no node for it, one whose children are all closed. Its start is the first work on it or a child. With no date, `noForecast` says why.
- **Kept:** the first forecast is kept on the epic's cost node (`LineageCostNode.forecast`), once, for scoring.
- **Estimate to complete:** each open child's cost drawn from its matches, times one lognormal factor per draw from the closed children's actual over their kept estimate (3 or more), times one plus the lead's share (the epic's own cost over its closed children's).
- **Spend:** a week and a month from 7 and 30 draws of the window's days. A day's cost is what the issues that landed on it took.
- **Burn:** each weekly allowance's last reading of the week now running, at its pace since the week started: when it runs out, or that it lasts to the reset.
- **Service levels:** each level's P50 and P85 cycle time over the window's landings, with 5 or more.
- **Milestones are not in it yet (#4620):** the store does not keep an issue's milestone, so there are no closed milestones to take a share from.

Decided: milestones go in #4620, not in #4526, because their membership must first be kept in the store, which is a change of its own. Alex can overrule.

## Not in this spike

- Cost forecasts, the burn against the allowance, and the estimate to complete. #4526 has them; this backtest is about dates only.
- The Scrum Master's order and the free lanes as inputs (the review's recommendation 6). The median share stands in for them. A queue model is a later spike, if H is not good enough.
- Alex's approval waits. They are inside the throughput and the share, not apart.

## How to run it again

```sh
python3 specs/4533-forecasting/fetch.py alexec/Agents /tmp/issues.json
python3 specs/4533-forecasting/backtest.py /tmp/issues.json
```

It prints aggregate figures only. It takes about 10 minutes.
