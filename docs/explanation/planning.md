---
description: What planning means in Agents, the three questions it answers, and how the figures earn trust.
---

# Planning

Planning is the product theme (`feature:planning`, Alex, 2026-11-10) that answers three questions about work on a repo, from what the agents have already done. It joins estimates, forecasting and the Value report, which grew up apart.

## The three questions

1. **What do we do next?** The plan is in the forge: epics, their sub-issues and the "blocked by" links between them (`specs/3265-work-plans/spec.md`, #3265). The Product Owner ranks with RICE, the Scrum Master gives places in a fixed order, and the Work pages show the plan as steps.
2. **What will it cost, and when does it land?** An **estimate** sizes one issue or epic from closed issues like it (#3557). A **forecast** says when an epic or a milestone lands and what the coming weeks cost, from the daily throughput and the burn rate, with no per-issue size (#4533).
3. **What did it deliver?** Reports ▸ Value says what the work cost, the PRs merged, the waste, and the lead and cycle times (#2351). It is the record the first two questions are checked against.

## What the figures come from

Every figure comes from the cost on the links (#2350): each turn's dollars, tokens and time go on the issue or PR the session works on, in `lineage-cost.json` on each machine, and the control plane adds the machines up. Nothing is typed in by a person. A figure that the store does not hold (Alex's time, CI minutes) is named as not counted.

## How the figures earn trust

- **A range with a probability, never a point.** An estimate is "$2 to $15, typically $6"; a forecast is "lands 18 to 24 Nov, 85% by 27 Nov". A point hides an error that is ×1.7 half the time.
- **Kept and scored.** Each estimate and forecast is kept when it is made, and scored against the actual figure when the work lands. Reports ▸ Value says how often the range held and by how much the dates missed. A model nobody can check does not improve, and the review of 2026-11-10 found exactly that: seven times more history left the per-issue estimate where it was.
- **The overhead is loaded in.** The Scrum Master, the leads, the merge waves and the releases cost money that no issue carries: 39% of the total on 2026-11-10. A loaded figure stands beside the direct one, so a budget means what it says.
- **The assumptions are stated.** A forecast names its window, the lanes and the runtime mix it assumes, because each one moves the dates and the dollars.

## Where it shows

Estimates and forecasts show on Work's issue, epic and milestone pages on every client, as one line under the title. Reports are on the web page only, where other people's data goes (#3224); the Mac window is for the person's own usage. A plan that moves, such as an epic past twice its estimate or a milestone whose forecast passes its due date, comes to the person as a notice.

## What is not planning

- **The Multiplier** (#3901) compares a person's output with an average engineer's. It is a figure to show, not a plan.
- **Usage and spending limits** say what was spent and stop an agent at a limit. Planning says what will be spent.

## Read more

- The review that led here: `.agents/reviews/estimates/2026-11-10-estimates-review.md`.
- The estimates' design and its backtest: `specs/3557-estimates/spec.md`.
- The forecasting epic: #4533.
