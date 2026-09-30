---
diataxis: how-to
devices: [mac, iphone, ipad, server]
description: When a chat's allowance runs out, see which runtimes are free and start a new chat that continues its work.
---

# Keep going when a runtime runs out

Plans such as Claude Max, ChatGPT and Copilot come with a generous allowance, and then stop
you for a few hours. When a chat's allowance runs out, the chat stops on its runtime and says
so. To go on, start a new chat on a runtime that isn't out and ask it to continue the first
one. The new agent reads what the first chat asked, said and did, and carries on from there.
The first chat stays as it was.

## Before you start

- At least two runtimes installed and signed in. See [Sign a runtime in](sign-a-runtime-in.md).
- Recognising a spent allowance works for Claude, Codex, Gemini, Antigravity, Copilot, Cursor
  and Grok. See [Runtimes](../reference/runtimes.md).

## When a chat runs out

The turn ends, and a note in the conversation says so: **Claude's allowance ran out, until
07:00.** The time is there only when the runtime gave one. The chat moves to **Paused**, with
**Its allowance ran out** under its name. Nothing else happens: no other runtime is started,
and the chat does not wait to carry on.

The runtime is marked out for every chat, so you can see it before you pick it again. Other
chats on it are not stopped. You can still send one a message. If that turn works, the
runtime is back.

A rate limit is different. The same chat tries again on the same runtime after a short wait,
and says when. Three rate limits in ten minutes on one chat count as the allowance running
out.

## See which runtimes are out

1. Open **Runtimes**, under Activity. Every runtime is on it, whether or not it is on this Mac.
2. Read where each one stands: **Available**, **Rate limited · trying again at
   02:21**, **Out · reset 07:00 · checking after 09:00**, **Out since 22:27 · checking after
   02:27** or **Credit used up · checking after 02:27**.
3. Where the runtime says so, a second line shows what is left of its plan: **28% left this
   week · resets Sun 20:39 · as of 14:02**. Grok is asked each time the page opens, at most
   every five minutes. Claude says it during a turn, usually once a limit is near.

On the iPhone and iPad, **Runtimes** is at the foot of **Spending**, with a red dot while a
runtime is out.

A new chat about to start on a runtime that is out says so above the prompt: **Claude is out.
The app checks it again at 02:27.** You can still send.

The runtime chooser above the prompt is in two runs, so you can see this before you pick. A
runtime that is out is under **Out**, with the same line under its name, and you can still
choose it. A new chat you start on one begins there.

## Continue the work in a new chat

1. Start a new chat in the same project, on a runtime that isn't out.
2. Ask it to continue the other chat by its title: **Please continue the work of Login
   redirect.**

The agent finds that chat in the project and reads its history: what you asked, what it said,
the tools it ran and the files they touched, and its plan as it last stood. A long chat is
shortened from the middle, and the history says how many turns were left out. The files are
already as the first chat left them.

If two chats have that title, the agent is told and shows you each, and you say which. It can
also list the chats in the project, or be given a chat's id.

## Bring a runtime back

The app checks an out runtime every four hours: a short conversation on a small model, in a
read-only mode, asked to reply "OK". If it answers, the runtime is back. A provider's reset time
is shown, but the runtime is not treated as back until a check or a turn works.

If you know it is back sooner, because you bought more credit or a new month started, choose
**Mark available** on the **Runtimes** page, or swipe the runtime on the phone. If you were wrong, it
costs one refused turn, and it is marked out again.

## On servers

A server's Codex and Claude sign in through this Mac, so they spend this Mac's plans. When a
plan runs out on either side, the other knows while the Agents window is open.

## See also

- [Limit what agents spend](limit-spending.md)
- [Sign a runtime in](sign-a-runtime-in.md)
- [Statuses and groups](../reference/statuses.md)
- [Tools the app gives agents](../reference/agent-tools.md)
