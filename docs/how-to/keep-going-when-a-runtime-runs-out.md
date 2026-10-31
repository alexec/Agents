---
diataxis: how-to
devices: [mac, iphone, ipad, server]
description: When a chat's allowance runs out, let it carry on when the allowance is back, or start a new chat on a free runtime that continues its work.
---

# Keep going when a runtime runs out

Plans such as Claude Max, ChatGPT and Copilot come with a generous allowance, and then stop
you for a few hours. When a chat's allowance runs out, the chat stops on its runtime and says
so. To go on, let the chat carry on by itself when the allowance is back. Or, to go on now,
start a new chat on a runtime that isn't out and ask it to continue the first one. The new
agent reads what the first chat asked, said and did, and carries on from there. The first
chat stays as it was.

## Before you start

- At least two runtimes installed and signed in. See [Sign a runtime in](sign-a-runtime-in.md).
- Recognising a spent allowance works for Claude, Codex, Antigravity, Copilot, Cursor
  and Grok. See [Runtimes](../reference/runtimes.md).

## When a chat runs out

The turn ends, and a note in the conversation says so: **Claude's allowance ran out, until
07:00.** The time is there only when the runtime gave one. The chat moves to **Paused**, with
**Its allowance ran out** under its name. Nothing else happens: no other runtime is started,
and the chat does not carry on until you ask it to.

The runtime is marked out for every chat, so you can see it before you pick it again. Other
chats on it are not stopped. You can still send one a message. If that turn works, the
runtime is back.

## Carry on when the allowance is back

1. Open the chat. Under its head, choose **Continue at 07:00**. When the runtime gave no time,
   the button is **Continue when it is back**.
2. The chat moves to **Waiting**, and its row says **Continues at 07:00**. When the runtime
   gave no time, it says **Continues when it is back · tries at 11:00**: the app's next check.
3. At that time, the app sends "continue" in the same chat. It goes sooner when another turn on
   that runtime works, or when you choose **Mark available** on the **Runtimes** page.

If the allowance is still out when the chat tries, the chat waits again, for the next time.
To stop waiting, choose **Cancel** in the chat. A message you send, **Stop** or **Archive**
also cancels it. The wait is kept over a restart of the Mac.

## Continue an Auto session on the next runtime

A session that started on [Auto](use-auto.md) has one more button under its head:
**Continue on Codex**, with the runtime that Auto would pick now. Choose it to start a new
session there, on Auto, with the same values (model, permission mode and sandbox). The new
session reads this one with `read_session` and carries on. Auto does not do this by itself:
a new runtime reads the work again, and that costs money.

### Workflows and helpers that nobody watches

A workflow's run or a session started by a session can wait by itself, with nobody to choose
**Continue**:

- **A workflow:** on its page, turn on **Continue when the allowance is back**, or add
  `continue-when-back: true` to its file's front matter. Each run whose turn is refused for a
  spent allowance waits at once, and its row says **Continues at 07:00**.
- **Helpers:** on the Mac, open the folder's **Folder Settings ▸ General** and turn on
  **Helpers continue when the allowance is back**. It is kept in `.agents/folder.json`.

Both are off unless you set them. A chat you started waits only when you choose **Continue**.

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

1. Start a new chat in the same folder, on a runtime that isn't out.
2. Ask it to continue the other chat by its title: **Please continue the work of Login
   redirect.**

The agent finds that chat in the folder and reads its history: what you asked, what it said,
the tools it ran and the files they touched, and its plan as it last stood. A long chat is
shortened from the middle, and the history says how many turns were left out. The files are
already as the first chat left them.

If two chats have that title, the agent is told and shows you each, and you say which. It can
also list the chats in the folder, or be given a chat's id.

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
