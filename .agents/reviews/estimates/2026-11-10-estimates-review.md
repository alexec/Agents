# How we estimate work: a review (2026-11-10)

Read with `specs/3557-estimates/spec.md`, which holds the design. The code is `Go/internal/lineage/estimate.go`. The data is `lineage-cost.json` on Alex's Mac, read today.

## What we do today

- An issue's estimate is the median cost of the closed issues with the same type (`bug` or `enhancement`) and level (`story`, `task`, `spike`, `bug`). With fewer than 5 matches, the same type; then all closed issues.
- The figures are dollars, output tokens, the agents' working time, and a cycle time with a landing date.
- An epic's estimate draws one match per open child, 1,000 times, and takes the median of the sums.
- The estimate is kept when work starts. Reports ▸ Value says the median error. The lead's closing summary says the estimate against the actual.
- Nothing upstream uses it. The Product Owner ranks with RICE by feel. The Scrum Master orders by RICE and never asks `estimate_issue`. The tool is asked once, when an epic closes.

## What the data says

The store now has 785 issues, 734 PRs and 403 sessions. 650 closed issues have a kept estimate and an actual.

| Figure | Spec's backtest (97 issues, 6 days) | Today (650 issues) |
|---|---|---|
| Median error, dollars | ×1.56 | ×1.69 |
| Within ×2 | 66% | 60% |
| Within ×1.5 | not measured | 41% |
| Median error, working time | ×1.45 | ×1.65 |
| Median error, cycle time | ×2.44 | ×2.63 |

Seven times more history did not make the estimate better. The reasons:

1. **The estimate is a class prior, not an estimate of the issue.** 650 estimates use 97 distinct values; 60 issues got "$1.34" and 49 got "$7.67". The spread of the estimates (sd of log 0.76) is far narrower than the spread of the actuals (1.02). Spearman's correlation between estimate and actual is 0.59: the labels carry some signal, and then nothing.
2. **The labels are exhausted.** I backtested, leave-one-out on the 573 issues, each alternative the spec did not try: a shrunk `area:` multiplier, `area:` and `feature:` multipliers, the last 30 of the class only, the class mean, and the geometric mean. Every one gives ×1.64 to ×1.70. No label refinement can move it. Nuance must come from new inputs, not from better matching.
3. **Both tails are equal.** 125 issues cost less than half the estimate; 132 cost more than double. The errors are not a bias to correct; they are variance the inputs cannot see.
4. **The cost drivers are known only after the fact.** A merged PR with no failed check cost a median $3.17; with two failed checks, $6.88. An issue with one session cost $3.03; with three, $8.33. Rework and helpers double the cost, and nothing at filing time predicts them yet.
5. **Epics are systematically low.** 23 closed epics have a kept estimate. The median actual is 1.7× the estimate; 17 of 23 came in over, 7 of them at more than double. The spec's backtest found no bias (×0.97) on 12 epics. Causes:
   - The epic's own cost, the lead's sessions, is in the actual and not in the estimate: a median 25% of the children's cost, a mean 42%.
   - The draws are independent. Children of one epic share a cause (the same runtime, the same flaky suite, the same approval wait), so their costs move together and the sum's tail is longer than the simulation says.
   - The children's actuals are right-skewed (mean $6.66, median $3.60). Per issue, the mean actual is 1.6× the estimate.
6. **A third of the cost is on no issue.** $4,240 of the $10,749 banked (39%) is on sessions with no link. One Scrum Master session, 2026-11-02 to 11-07, banked $3,084: 29% of everything. The merge waves, releases, reviews and fix-failed-checks runs are in this pile too. Every estimate and every actual leaves out this overhead, so "this epic will cost $100" means about $140 of agent spend, and nothing says so.
7. **Time is the weakest figure, and it is never checked.** Working time is the agents' compute time: median 22 minutes per issue, 23% of the cycle time (median 1.7 hours, P90 12 hours). The cycle time error is ×2.6, and `landsAt` is the start plus that cycle median. The kept estimate keeps dollars, output tokens and working time only, so the landing dates' error is never measured. The same is true of the P10–P90 range: "8 in 10 land here" is a claim from a 6-day backtest, and nothing today checks it.
8. **Tokens are half measured.** `inputTokens` on an issue is tiny (a sample: 55 input against 7,196 output) because runtimes count cached reads apart. The estimate shows output tokens only. `limitTokens`, fresh input plus output, is the figure a spending limit uses, and it is not estimated.
9. **False precision.** The page says "about $5.87" for a figure that is wrong by ×1.7 half the time. The range sits in a tooltip.
10. **The rates move.** The daily median cost of a closed issue swung from $1.37 to $6.90 over the 12 days. The runtime and model mix (Claude or Codex, effort), the lane limit and the allowance pause change the rate per issue, and none of them is an input or a stated assumption.

## Recommendations

In order. The first three change what the numbers mean; the rest change how they are made.

1. **Load the overhead in, and say it.** Measure each week the ratio of unlinked cost to linked cost (today 0.65) and the ratio of an epic's own cost to its children's (today 0.25). Show a loaded figure: "direct $100, about $165 all in". Link what can be linked: a Scrum Master's turn that starts a lead goes on that epic; a fix-failed-checks run goes on its PR; a merge wave splits over the PRs it lands. Alex's time and CI minutes stay out, but the report names them as uncounted.
2. **Show a range and a size, not a point.** Replace "about $5.87" with "$2 to $15, typically $6" (P10, P90, median), or a size band from the class (bug S, task M, story L) with its dollar range. Round to one significant figure. Say the working time as "agents' compute time", and show the cycle time as a range only, with the median queue wait named apart.
3. **Keep enough to check the claims.** Keep P10, P90, the cycle time and `landsAt` in the kept estimate. Reports ▸ Value then says the coverage: "the P10–P90 range held the actual 71% of the time; it should hold it 80%", and the landing date's median error in days. A model nobody can check does not improve.
4. **Add the inputs the labels lack, at filing time.** The Product Owner sets a `size:` label from a short rubric when it files an issue: the clients it touches (Core is three), a new screen or control (an approval wait), an integration or an outside account, a spec or not, the files in its `area:`. Keep `size:` as a match key beside type and level. Backtest it after 100 closed issues and keep it only when it beats ×1.6. The labels today have nothing more to give; this is the one cheap input left.
5. **Re-estimate an epic as it goes.** Once an epic has three closed children, compute the ratio of their actuals to their estimates and apply it to the open children: an estimate to complete. Add the lead's own cost as a term (the measured ratio). Draw the children with a shared multiplier per draw (a lognormal factor) so the sum's tail is honest. Notify Alex when an epic passes 2× its estimate, instead of a surprise in the closing summary.
6. **Model the queue, not the cycle median.** The landing date depends on the lanes free, the items ahead in the Scrum Master's order, Alex's median response to `needs-approval`, and the CI time. All four are in the store or the events. A date from those will beat a date from the cycle median; until then, show no date.
7. **Make an estimate decide something.** The Product Owner's RICE effort is `estimate_issue`, not a guess. The Scrum Master's weekly summary says the week's spend against the open epics' estimates. A release's notes say what the milestone cost against its estimate. An estimate nobody acts on will not get better, because nobody will notice when it is wrong.
8. **Estimate per runtime mix, and from a recent window.** Match on the closed issues of the last 14 days, and state the mix the estimate assumes ("at this week's rates: Claude Opus, 7 lanes"). When the mix changes, the estimate changes with it, and the reader knows why.
9. **Drop `inputTokens` from the estimate; add `limitTokens`.** Output tokens and fresh tokens are the two figures a person can act on.

## What I did not do

- No code changed and no issue filed. Alex asked for recommendations.
- The backtest of alternatives was a one-off script over `lineage-cost.json`, not product code. Its method is the spec's: estimate each closed issue from the issues merged before its start, and take the median of max(est/actual, actual/est).
- CI minutes and Alex's review time are not in any store, so no figure here includes them.
