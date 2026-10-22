---
diataxis: how-to
devices: [iphone, ipad]
description: Follow a turn you sent from your iPhone or iPad on the Lock Screen and in the Dynamic Island, and turn this off.
---

# Follow a turn on the Lock Screen

When you send a prompt from the iPhone or iPad app, the turn shows as a Live Activity. It
is on the Lock Screen, and in the Dynamic Island on an iPhone that has one. You can put
the phone down and see when the agent asks you something or ends, without opening the
app.

Only a turn you send from this device shows. A turn sent from the Mac window, the web
page or a workflow does not, because you did not ask for it here.

## Before you start

- The iPhone or iPad app, paired with your control plane. See
  [Connect a window or phone](connect-a-window-or-phone.md).
- Live Activities allowed for Agents in the system's Settings app. If the system does
  not allow them, the app starts none.

## Steps

1. Open a session in the app.
2. Type a prompt and send it.

   The Live Activity starts at once. It also starts when you start a new session from
   this device, as soon as your host tells the app about the new session.
3. Lock the phone, or go to another app. The turn shows on the Lock Screen.
4. Tap the Live Activity to open its session. A question waits there as its card.

There is at most one Live Activity for each session. A prompt you send while the turn
still runs does not start a second one, and the time goes on from the first prompt. A
prompt you send after the turn ends starts the time again from that prompt.

## Read it

The Lock Screen shows these, from left to right:

- **A mark** for the phase: a dashed ring while it works, an orange hand when it needs
  you, an empty ring when it is done, a grey stop when it is paused, and a red triangle
  for an unexpected stop.
- **The title** of the session. A session with no title yet is **New session**.
- **The phase**, then the runtime and the project, such as **Working · Claude · api**.
- **A grey line**, of at most two lines, that says more.
- **The time** the turn has worked, on the right. The system counts it, also when the
  app does not run. When the turn ends, the time stops.

The phase is one of these:

| Phase | What the grey line says |
| --- | --- |
| **Working** | The step of the plan that the agent is on. |
| **Question waiting** | The question. |
| **Needs approval** | What the agent asks to do, such as a command to run. |
| **Done** | The first line of the agent's report. |
| **Needs you** | Why: **Partly done**, **Stuck** or **Waiting on your answer**, with the report, or **Outcome unknown**. |
| **Paused** | **Stopped by you**, **Stopped by the agent that started it** or **Its allowance ran out**. |
| **Unexpected stop** | The reason, such as **The runtime crashed**. |

The words are the ones the sidebar uses. See [Statuses and groups](../reference/statuses.md).

The Dynamic Island shows the mark and the time. Touch and hold it to see the phase, the
title and the grey line.

## When it ends

- **The turn ends.** The Live Activity shows how it ended, and stays on the Lock Screen
  for 15 minutes. It does not stay the system's four hours, because the notification for
  the end says the same.
- **You archive or delete the session.** The Live Activity goes at once.
- **You turn Live Activities off.** Every Live Activity goes at once.

## Turn it off or on

1. In the sidebar, tap **Settings…** at the foot of the list.
2. Under **Notifications**, turn **Live Activities** off.

Live Activities are on at first, because you sent the prompt from this device and so you
are likely to want to follow it. The switch is for this device only.

## If it doesn't work

- **No Live Activity starts.** Check that **Live Activities** is on in the app's
  **Settings…**, and that the system's Settings app allows Live Activities for Agents.
- **The line says Open Agents to see where it is.** The app has not heard about the
  turn for 10 minutes, so it does not show a step that may be old. Open the app, and the
  line comes back.
- **The line says Open Agents to answer it, Open Agents to decide, or Open Agents to see
  what it needs.** The update came by push from your control plane while the app did
  not run. A push carries no words, so the line cannot say the question. Open the app to
  read it.
- **The Live Activity does not change while the app is shut.** Your control plane sends
  updates by push only when it has an APNs key. A control plane on your Mac has none. See
  [How a Live Activity keeps up](../explanation/live-activities.md).

## See also

- [How a Live Activity keeps up](../explanation/live-activities.md)
- [See what needs you from your Home screen](see-what-needs-you-from-your-home-screen.md)
- [Answer a question or a permission request](answer-a-question.md)
- [How the phone and iPad reach your agents](../explanation/phone-and-ipad.md)
