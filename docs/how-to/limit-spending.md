---
diataxis: how-to
devices: [mac]
description: See what agents have cost, and set a limit on what one agent, or one day, may spend.
---

# Limit what agents spend

Agents shows what every agent has cost, as its runtime reported it, and can stop the
spending at a limit you set: for one agent across its whole life, and for everything in
one day.

## Before you start

- A runtime that reports a price. Claude does; some report tokens only, and no limit
  applies to an agent on those. See [Runtimes](../reference/runtimes.md).

## Steps

**See what has been spent**

1. Click **Spending** at the foot of the sidebar, or press Option-Command-S.

   The page shows **All time** at the top, then each project with what its agents cost,
   in each currency the runtimes reported. Archived projects are shown greyed. A line
   saying **At least this much** means some chats ran on a runtime that reported no price.
2. For one agent, look above its prompt: the figure beside its name is what it has cost so
   far.

**Set a limit**

1. Choose **Agents ▸ Settings…** and click **Spending** in the rail.
2. Under **Per agent** (*The most one agent may spend*), type an amount, choose the
   currency, and click **Set**.

   An agent that reaches it finishes the turn it is in and takes no further prompt, so it
   may end a little over.
3. Under **Per day** (*The most a day may spend*), do the same.

   When a day reaches it, nothing new starts and no prompt is sent, in any project,
   including scheduled workflows. What is working finishes its turn and holds. What you
   typed waits until the day rolls over. **Today** shows what is left.
4. To remove a limit, click **No limit**.

**When an agent reaches a limit**

It moves to **Stopped** with **Reached its cost limit**, and **Raise the limit** above the
prompt opens Settings. Raise it, then send a prompt to carry on. **What the limits have
stopped**, in the same pane, lists every agent a limit has stopped.

Each server keeps to the per-day limit on its own. For every control in the pane, see
[Settings](../reference/settings.md).

## If it doesn't work

- **An agent went over its limit.** A limit is checked between turns, so the turn that
  crosses it finishes.
- **The figure stays at nothing, and a limit does not stop the agent.** Its runtime
  reports no price; hover over the figure and it says so.
