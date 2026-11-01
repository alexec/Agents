---
diataxis: how-to
devices: [mac]
description: See what agents have cost, and set a limit in money or tokens on what one agent, or one day, may use.
---

# Limit what agents spend

Agents shows what every agent has cost, as its runtime reported it, and can stop the
spending at a limit you set: for one agent across its whole life, and for everything in
one day. A limit is in money, in tokens, or both. Whichever is reached first stops the
work.

## Before you start

- A runtime that reports a price or tokens. What each runtime reports decides which
  limit can stop it:

  | Runtime | Reports | Limit that applies |
  |---|---|---|
  | Claude | price and tokens | money and tokens |
  | Codex, Gemini, OpenCode, Copilot | tokens | tokens |
  | Cursor, Antigravity, Grok | neither | none |

  An agent on a runtime that reports neither runs past every limit. See
  [Runtimes](../reference/runtimes.md).

## Steps

**See what has been spent**

1. Click **Cost** in the sidebar's **Usage** group, or press Option-Command-S.

   The page shows **All time** at the top, then each folder with what its agents cost,
   in each currency the runtimes reported. Archived folders are shown greyed. A line
   saying **At least this much** means some chats ran on a runtime that reported no price.
2. For one agent, look above its prompt: the figure beside its name is what it has cost so
   far.

**Set a limit**

1. Choose **Agents ▸ Settings…** and click **Policy** in the rail's **Agents** group. On the
   web page, open **Settings** and find **Agents ▸ Policy**.
2. Under **Money**, type an amount in US dollars in **Per agent** and press Return.

   An agent that reaches it finishes the turn it is in and takes no further prompt, so it
   may end a little over.
3. For a runtime that reports no price, type a number of tokens in **Tokens per agent**
   and press Return. A token limit counts the fresh input and the output of each turn;
   it does not count what the model reads back from a cache.
4. Do the same in **Per day** and **Tokens per day**.

   When a day reaches it, nothing new starts and no prompt is sent, in any folder,
   including scheduled workflows. What is working finishes its turn and holds. What you
   typed waits until the day rolls over. **Spending** shows what is left today, in money
   and in tokens.
5. To remove a limit, empty the field and press Return. An empty field is no limit, never
   a zero.

A limit that your organisation caps shows 🔒 and the organisation's value. Your own value
is kept, not used, until the organisation's value is higher. See
[Policy layers](../explanation/policy-layers.md).

**When an agent reaches a limit**

It moves to **Stopped** with **Reached its cost limit**, and **Raise the limit** above the
prompt opens Settings. Raise it in **Policy**, then send a prompt to carry on. **What the
limits have stopped**, in **Spending**, lists every agent a limit has stopped.

Each server keeps to the per-day limit on its own. For every control in the pane, see
[Settings and the Resources page](../reference/settings.md).

**When your organisation sets a budget**

An organisation's policy can give each person a budget per UTC day and per agent, in US
dollars and in tokens (#998). It is a ceiling over your own limits: the lower one stops the
work. A runtime on a subscription reports tokens and no price, so the token budget holds it.
At the budget, new turns are refused until 00:00 UTC, and the chat says that your
organisation set the budget. Your machines count together: the control plane adds what each
one spent. While a budget is set, a runtime that reports neither a price nor tokens is
refused, unless your organisation allows it. See
[Organisation policy on a machine](../explanation/organisation-policy.md#budgets).

**When a session uses your organisation's key or gateway**

An org account (#999) has no plan, so the **Runtimes** page shows its row as **Organisation ·
No plan limit**, with its tokens today. The tokens are the provider's own count, which the
model relay on your machine reads from each answer. A token limit, yours or your
organisation's, counts these tokens. A cost on an org account is the runtime's own figure at
its list price ("list price, as Claude reports it"), not what your organisation pays. See
[org keys and gateways](../reference/runtimes.md#org-keys-and-gateways).

## If it doesn't work

- **An agent went over its limit.** A limit is checked between turns, so the turn that
  crosses it finishes.
- **The figure stays at nothing, and a money limit does not stop the agent.** Its runtime
  reports no price; hover over the figure and it says so. Set a token limit: the figure
  then shows the tokens used against it.
- **The figure says *Not measured* and no limit stops the agent.** Its runtime reports
  neither a price nor tokens (Cursor, Antigravity, Grok). No limit applies to it. While
  your organisation sets a budget, such a runtime does not start at all.

## See also

- [Keep going when a runtime runs out](keep-going-when-a-runtime-runs-out.md)
- [Settings and the Resources page](../reference/settings.md)
- [Statuses and groups](../reference/statuses.md)
