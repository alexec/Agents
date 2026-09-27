---
diataxis: explanation
description: Why a chat can carry on with another runtime when its plan's allowance runs out, and what that keeps off a bill that can grow.
---

# Why chats carry on when a plan runs out

Plans such as Claude Max, ChatGPT and Copilot give you a generous allowance and then stop
you for a few hours. Paying by use is easy to set up and hard to stop: one runaway turn
can spend more than you meant. The app's answer is a **pool** — an ordered list of
runtimes you are happy to use — and a rule that nothing in it may spend money that grows
without a limit.

## What the pool is for

When a chat's allowance runs out, you usually want the work to continue, not to wait for
the plan to reset or to paste the conversation somewhere else by hand. The pool is that
continuation: the chat moves to the next runtime that still has room, with the
conversation so far and the message that was refused. You do not type it again.

The switch is a fact about the chat, not a new agent. The same session keeps its place in
the list, its mode (never looser than before), and any matching-models level you set. The
runtime underneath it changes.

## Why credit is gated

An API key can join the pool only when its spending stops by itself — free tier, free
credit, or prepaid with auto-recharge off. A key billed with no limit is offered and
cannot be picked. The app cannot see a provider's billing page; it takes your word for
the kind of credit, and stops using the key when the amount you named is spent or past
its date, before the provider says no.

That keeps the pool's promise: carrying on never puts you on a bill that can grow.

## What happens when everyone is out

If every runtime in the pool is out, the chat waits for the first one that said when it
is back, then carries on by itself. That wait is **Waiting for an allowance** under
**Stopped**, not the hourglass **Waiting** group — those are agents waiting on events or
other agents. The Pool page lists the chats that are waiting, and **Stop waiting** ends
one early.

## Related

- [Keep going when a runtime runs out](../how-to/keep-going-when-a-runtime-runs-out.md),
  for setting the pool up and reading a switch.
- [Limit what agents spend](../how-to/limit-spending.md), for caps that stop a chat
  regardless of the pool.
- [Statuses and groups](../reference/statuses.md), for **Waiting for an allowance** and
  **Its allowance ran out**.
- [Settings](../reference/settings.md), for the Pool pane.
