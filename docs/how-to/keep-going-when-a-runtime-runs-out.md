---
diataxis: how-to
devices: [mac, iphone, ipad, server]
description: Have a chat carry on with another runtime when its plan's allowance runs out, without ever paying by use.
---

# Keep going when a runtime runs out

Plans such as Claude Max, ChatGPT and Copilot come with a generous allowance, and then stop
you for a few hours. You can set up a **pool** of runtimes you are happy to use, in order.
When a chat's allowance runs out, it carries on with the next runtime in the pool that isn't
out, with the conversation so far and the message it was refused. Nothing is ever put on a bill
that can grow: an API key joins the pool only on free or prepaid credit.

## Before you start

- At least two runtimes installed and signed in, each on its own plan. See
  [Sign a runtime in](sign-a-runtime-in.md).
- Recognising a spent allowance works for Claude, Codex, Gemini, Antigravity, Copilot, Cursor
  and Grok. See [Runtimes](../reference/runtimes.md).

## Set up the pool

1. Open **Settings ▸ Pool**.
2. Turn on **Carry chats on with the next runtime when one runs out**.
3. Use **Add a runtime** to add each runtime you are happy to carry on with. Only runtimes
   that are installed and signed in are offered.
4. Drag the rows into the order to try them in. The first one that isn't out is used.
5. Optionally, choose a **Model** for a runtime: the model a chat is started on when it moves
   there and no level decides (see Matching models below).

## Add credit on an API key

A key can join the pool only if its spending stops by itself when the credit is gone. Today
that is a Gemini key, the one key this Mac lends to a runtime.

1. Save the key first in **Settings ▸ Agent Runtimes**, under Gemini.
2. In **Settings ▸ Pool**, choose **Add credit on an API key…**.
3. Pick what kind of credit it is: **Free tier, no billing on the key**, **Free credit** or
   **Prepaid, with auto-recharge off**. **Billed with no limit** is shown but can't be picked.
4. For free or prepaid credit, give the amount and, if it has one, the expiry date. The app
   counts what each turn costs against it and stops using the key when it is spent or past its
   date, before the provider says no.
5. **Add**. The key goes last in the pool, after every plan.

The app can't see a provider's billing settings. It takes your word for the kind of credit, so
check with the provider that auto-recharge is off.

## What a switch looks like

When a chat's allowance runs out:

- The chat shows a tinted note: **Claude's allowance ran out, until 07:00. Carried on with
  Codex.** Under it are the model, effort and mode the chat carried on with and where each came
  from, what was handed over, and anything not carried, such as "always allow" answers.
- **What it was handed** folds open to the conversation as the new runtime received it.
- The new runtime starts a fresh conversation, is given this one so far, and answers the message
  that was refused. You don't type it again.
- The mode is never looser than the chat's own: a chat that asks before editing carries on with
  a mode that asks too.
- On the sessions list, the chat has a **⇄** mark: its tooltip says where it came from and
  when.

If every runtime in the pool is out, the chat waits for the first one that said when it is back,
and carries on by itself then: **Every runtime in the pool is out. This chat waits, and carries
on with Claude at 07:00.** Its icon stays grey, with an hourglass. If none has said when, it stops
and says so. Your next message, **Stop**, **Park** or **Archive** ends the wait.

## Read the Pool page

**Pool**, last in the sidebar's Activity section, has a red dot while a runtime is out, and a
line such as **1 out · 3 chats on Codex**. The page shows:

- **Runtimes, in order**: each with how it is paid for and its state in words, such as
  **Available**, **Out until 07:00**, **Rate limited · trying again at 02:21** or **Credit used
  up**. **Mark available** is on any that is out.
  Under it, where the runtime says so, is what is left of its plan: **28% left this week ·
  resets Sun 20:39 · as of 14:02**. Grok is asked each time the page opens, at most every five
  minutes. Claude says it during a turn, usually only once a limit is near or reached. Other
  runtimes have no way to say it yet. The line is only shown: whether a chat runs is still the
  state above it.
- **Waiting for an allowance**: chats waiting, with when each carries on, and **Stop waiting**.
- **Matching models**: see below.
- **Recent switches**: when, which chat, from which runtime to which, and why. **Show the last
  30 days** goes further back.

On the iPhone and iPad, **Pool** is under **Spending**, with the same dot. Mark available and
Stop waiting are swipe actions.

## Mark a runtime available

If you know a runtime is back before the app does (you bought more credit, or a new month
started), choose **Mark available** on its row. It is used again from the next switch. If you
were wrong, it costs one refused turn, and it is marked out again.

## Match models across runtimes

**Matching models** on the Pool page is a grid: one column per runtime, one row per **level** you
name, such as *Strongest* or *Everyday*. When a chat switches, it keeps its level. If it was on
Claude's Opus and Opus is in *Strongest*, it carries on with *Strongest*'s Codex model.

- Click a cell to choose that runtime's model for the level. A model sits in one level at most:
  choosing it in another moves it there.
- **Add a level**, and use a level's name for **Rename…**, **Move up**, **Move down** and
  **Remove this level**.
- A model a runtime no longer offers is struck through, and a switch treats that cell as empty.
- Without a level, a chat carries on with the pool entry's **Model**, else the model last chosen
  for that runtime, else the runtime's default.

## Continue with another runtime yourself

Use the runtime menu on the prompt bar:

- The tick at the top, **Carry on when Claude runs out**, turns switching off or on for this
  chat only.
- **Continue with** lists the pool's runtimes with their state, then every other runtime.
  Runtimes that are out can still be picked.

Picking one opens a sheet: each setting as it is now, as it will be, and where that came from.
Each new value is a menu of what the runtime offers, with modes looser than the chat's left out.
**Remember this for next time** puts the model you pick beside the chat's in a Matching models
level. **Continue on …** moves the chat. Nothing is sent until your next message, which carries
the conversation so far with it. While a turn is running, the sheet says **Stop the turn first**.

After an automatic switch, **Change what it carried on with…** on the note opens the same sheet
for the runtime the chat is on. Your changes apply from its next turn, and nothing is started or
sent again.

On the iPhone and iPad, **Continue with** is on the chat's menu, with the same sheet as a list.

## On servers

The pool is the Mac's, and each connected server uses it. A server's Codex signs in through this
Mac's ChatGPT sign-in, so it spends this Mac's plan. When that plan runs out on either side, the
other knows at once, while the Agents window is open: a chat there moves before it is refused.

## See also

- [Why chats carry on when a plan runs out](../explanation/runtime-pool.md)
- [Limit what agents spend](limit-spending.md)
- [Sign a runtime in](sign-a-runtime-in.md)
- [Statuses and groups](../reference/statuses.md)
