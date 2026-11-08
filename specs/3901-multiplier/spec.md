# The Multiplier: how it is counted (#3902)

Part of epic #3901. This spike settles the method. #3903 counts it on the host and the control plane, and #3904 draws it on the Mac window.

## The method, in one line

> **Multiplier = the PRs your agents merged in the last 7 days ÷ 1.4, the PRs an average engineer merged in a week in 2025.**

For example, 7 merged PRs in 7 days is **5.0×**: "this week you shipped what 5 engineers ship".

Alex (2026-11-07, on #3902): the number is a show-off number, and a simple method that a person can explain in one line is better than a precise one. This method is the simplest one that has a public source for its baseline.

## 1. The unit of work: a merged PR

- **One merged PR is one unit.** A PR counts when it merged in the range and an agent of the person opened it or worked on it (a PR node in the person's lineage, `outcome: merged`).
- **Decided: merged PRs, not engineer-hours from the diff, because** Alex wants a method that a person can explain in one line, and a public baseline exists only for PRs a week. A formula on the diff needs a size baseline and weights that a person cannot check. Alex can overrule.
- **Splitting PRs.** A count of PRs goes up when the agents make smaller PRs. The risk is low here: in the backtest (below) this repo's median PR is 225 lines changed. LinearB 2026 (2025 data) says that the median AI-assisted PR is 96 lines. So these PRs are not smaller than others. A later issue can add a size weight if the number goes up for the wrong reason.
- **Closed issues: not used.** Issue sizes vary too much, and many PRs fix no issue.

## 2. The 2025 baseline: 1.4 merged PRs a week, by default

1.4 is the default, not a fixed figure (Alex, 2026-11-07, #3991): the person can set their own PRs a week (0.1 to 100, one decimal) and the line under the figures in Settings ▸ Cost ▸ Multiplier. The host keeps both in the person's preferences (`multiplierPRsPerWeek`, `multiplierLine`), counts with them, sends the figure with `multiplier/count` so the control plane counts every machine the same, and tells `multiplier/changed` at once. An empty line is the default line, with the person's figure. Hours a week stays 40.

| Figure | Population | Source |
|---|---|---|
| **1.4** merged PRs per engineer per week | median, engineers who do not use AI | DX, *AI-assisted engineering: Q4 impact report*, 2025-11-07: 61,800 developers at 376 companies |
| 1.5 / 1.8 / 2.3 | median, monthly / weekly / daily AI users | the same report |
| Good 1.2–2.0, Elite > 2.0 merges per developer per week | tiers at P75, 8.1M PRs, 4,813 teams | LinearB, *Engineering Benchmarks 2026* (2025 data) |

- The DX sentence is: "daily AI users merge a median of 2.3 pull requests per week, compared with 1.8 for weekly users, 1.5 for monthly users, and 1.4 among those who don't use AI at all." We read it as Tessl quotes it ([tessl.io](https://tessl.io/blog/ai-assisted-engineering-report-reveals-adoption-and-productivity-gains-but-quality-issues-persist)). DX's own report is behind a form.
- LinearB ([linearb.io](https://linearb.io/library/engineering-benchmarks-and-research)) puts 1.4 in its "Good" band, so the two sources agree.
- **Recommended: 1.4, because** it is an engineer's own output with no AI, and the Multiplier compares the person with their agents against that engineer. Alex chose it (2026-11-07). 1.8 (a weekly AI user) was the other choice: it makes every figure 22% lower.
- **Not used:** DX's Core 4 benchmark page says 3.8 merged PRs a week at P50, but it has no date and does not say who it counts. Faros AI (2025) and DORA 2025 give only changes in per cent, not a figure.
- **The page says the source** in one small line: "An average engineer merged 1.4 PRs a week (DX 2025)", or the person's own line.

### Engineer-hours

The hero page shows engineer-hours too (Alex, 2026-11-07). It comes from the same baseline, so it agrees with the Multiplier:

> **Engineer-hours = counted PRs × 40 h ÷ 1.4 = counted PRs × 28.6 h.**

That is "an average engineer works 40 hours a week and merges 1.4 PRs in it". Engineer-hours ÷ 40 h is the Multiplier again.

## 3. How a PR's hours are estimated: a fixed rate, no model

- Every counted PR is worth the same: 1 PR, 28.6 engineer-hours.
- **Decided: no model rates the PRs, because** a model costs money for each PR, sends the diff to a runtime (privacy), gives a figure that a person cannot check, and is not simpler. Alex can overrule.

### Backtest on this repo

`gh pr list --state merged` on alexec/Agents, 2026-11-07:

| Range | Merged PRs | Median lines changed | Multiplier (÷ 1.4) | Engineer-hours |
|---|---|---|---|---|
| ISO week 2026-W43 | 364 | 155 | 260× | 10,400 h |
| ISO week 2026-W44 | 321 | 120 | 229× | 9,170 h |
| ISO week 2026-W45 | 315 | 281 | 225× | 9,000 h |
| The last 7 days to 2026-11-07 | 395 | 225 | 282× | 11,290 h |

- This is the whole repo, and all of its PRs come from Alex's agents. One person's Multiplier here is about **230× to 280×**. With 1.8 it is about 175× to 220×.
- The number is large, but it is true to the count: 395 PRs is what 282 engineers at 1.4 a week merge. Alex agreed the method with these figures (2026-11-07).
- No merged PR in these weeks has a title that starts with "Revert".

## 4. The range: the last 7 days

- **Decided: the last 7 days, rolling, because** it does not drop to zero on Monday, and the baseline is a figure for one week, so there is nothing to scale. Alex can overrule.
- The window is now − 7 days to now, by the PR's `endedAt`. Note: Reports ▸ Value puts a node in a range by `lastAt`; the Multiplier uses `endedAt`, so a later turn on a merged PR does not move it.

## 5. The scope: the person, on the Mac window

- Alex (2026-11-07): the Mac window only, so the scope is the person: the PRs in the lineage of all the person's machines. There is no group or organisation figure, and no Remote or web figure.
- With a control plane, the control plane adds up the person's machines, as `reports/value` does with the scope "me". With no control plane, the host counts its own lineage.

## 6. Reverts

- **Decided: a merged revert takes one PR away, because** it undoes the PR that it reverts, and lineage does not link a revert to the PR it reverts. Alex can overrule.
- So: counted PRs = merged PRs − merged reverts in the range, never below 0. A revert is `outcome: reverted`: agentsd marks a merged PR whose title starts with "Revert" (`Go/internal/agentsd/lineagecost.go`, `notePROutcome`).
- A PR closed without a merge counts 0.
- The rule is simple, but it is not exact when the reverted PR merged before the range. Then this week loses one PR for an earlier week's work. That is acceptable for a show-off number, and it is rare (no revert in the backtest).

## 7. The data: what lineage gives, and what is missing

| Need | From | State |
|---|---|---|
| Merged PRs in the range | `LineageCostNode`: `node.kind == "pr"`, `outcome == "merged"`, `endedAt` | have it |
| Merged reverts | `outcome == "reverted"`, `endedAt` | have it |
| The person's machines | the control plane's lineage objects and `ownerOf` (`Go/internal/controlplane/reports_value.go`, `scopeLineage`) | have it |
| The PR that changed the figure (`+0.7×  #1234 merged`) | the `pr.merged` event, and the PR node's ref | have it |
| Agents working now | the host's sessions with a running turn; not lineage | have it, outside lineage |
| Only the PRs that the agents opened or worked on | `LineageCostNode.sessions` names the sessions, but not the link kind (`works-on`, `opens`, `reviews`) | **missing**: a PR that an agent only reviewed counts too. #3903 checks this and leaves out reviewed-only PRs if the lineage can say it |
| The revert → reverted PR link | none | **missing**, and not needed with rule 6 |
| Diff size | none | **missing**, and not needed with this method |

### For #3903

- Count on `pr.merged` and on a merged revert, and keep the figure: `count`, `reverts`, and for the 7-day window the merged times (at most a few hundred a week; the window drops the older ones). Do not read every machine's lineage on each open (#2975).
- Give `prsMerged` (counted), `multiplier`, `engineerHours` and `agentsWorking`, and the baseline (1.4, "DX 2025") so the clients do not keep their own copy.
- Tests: 7 merged PRs and 0 reverts is 5.0× and 200 h; 7 merged and 1 revert is 4.3×; nothing merged is no figure (the page shows `— ×`), not 0×.

### As built (#3903)

- **The wire:** `multiplier/state` (the window asks on each open), `multiplier/changed` (told on a merge or a merged revert, with the PR in `changedBy`), and `multiplier/count` (a host asks its control plane). The type is `Multiplier`, with the baseline in `MultiplierBaseline`. The figure is rounded on the host: the multiplier to 0.1, the hours to 1 h.
- **Only the agents' PRs:** a PR counts when a session worked on it (its node has sessions). A PR that the person merged by hand, or another person's PR in the same repo, counts 0. A revert counts the same way.
- **Reviewed-only PRs still count:** a review session's `P#n` label is a `works-on` link, so lineage cannot tell a review from work.
- **Kept, not read again:** the control plane keeps each person's merges by the entity tags of their machines' lineage objects, and counts again only when a machine sent new lineage. With no control plane, or when it does not answer, the host counts its own ledger's merges, kept as they happen.
- **Live on one machine:** the host that hears the `pr.merged` sends its lineage to the control plane, then tells its own window. The person's other machines show it on their next open.

## What it is not

- Cost and tokens do not change the figure (#985): only merged PRs do.

## Agreed

Alex agreed (2026-11-07, by a form on #3902):

1. The method: merged PRs in the last 7 days ÷ the baseline, a merged revert takes one PR away, engineer-hours = PRs × 40 h ÷ the baseline. The name is "Multiplier".
2. The baseline is **1.4**: an engineer with no AI.

mac: docs only, remote: docs only, web: docs only.
