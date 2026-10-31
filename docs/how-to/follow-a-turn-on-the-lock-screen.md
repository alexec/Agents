---
diataxis: how-to
devices: [iphone, ipad]
description: Follow a turn you sent from your iPhone or iPad on the Lock Screen and in the Dynamic Island, and turn this off.
---

# Follow a turn on the Lock Screen

When you send a prompt from the iPhone or iPad app, the turn shows in a Live Activity. It
is on the Lock Screen, and in the Dynamic Island on an iPhone that has one. There is one
Live Activity in total, for all the turns you sent from this device. You can put
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

There is one Live Activity in total, not one for each session. A prompt to another
session joins the Live Activity that shows. A prompt you send while the turn still runs
does not start a new turn, and the time goes on from the first prompt.

When more than one turn runs, the Live Activity shows the session that most needs you:
one that asks a question or an approval, else the one you sent a prompt to last. Below
it, a line counts the others, such as **+1 needs you · +2 working**.

## Read it

The Lock Screen shows these, from left to right:

- **A mark** for the phase: a dashed ring while it works, an orange hand when it needs
  you, a tick when it is done, a grey stop when it is paused, and a red triangle
  for an unexpected stop.
- **The title** of the session. A session with no title yet is **New session**.
- **The phase**, then the runtime and the folder, such as **Working · Claude · api**.
- **A grey line**, of at most two lines, that says more.
- **The others**, when more than one turn runs, such as **+2 working**.
- **The time** on the right, from the oldest turn that still runs. The system counts it,
  also when the app does not run. When the last turn ends, the time stops.

The phase is one of these:

| Phase | What the grey line says |
| --- | --- |
| **Working** | The step of the plan that the agent is on. |
| **Question waiting** | The question. |
| **Needs approval** | What the agent asks to do, such as a command to run. |
| **Done** | The first line of the agent's report. |
| **Needs you** | Why: **Partly done**, **Stuck** or **Waiting on your answer**, with the report, or **Outcome unknown**. |
| **Paused** | **Stopped by you** or **Stopped by the agent that started it**. |
| **Unexpected stop** | The runtime crashed, failed, hit a limit or otherwise stopped short without you choosing to stop it. |
| **Unexpected stop** | The reason, such as **The runtime crashed**. |

The words are the ones the sidebar uses. See [Statuses and groups](../reference/statuses.md).

The Dynamic Island shows the mark and the time. When more than one turn runs, a number
next to the mark says how many. Touch and hold it to see the phase, the title, the grey
line and the others.

## When it ends

- **A turn ends while others run.** It leaves the Live Activity, which goes on for the
  others. The notification for the end tells you.
- **The last turn ends.** The Live Activity shows how it ended, and stays on the Lock
  Screen for 15 minutes. It does not stay the system's four hours, because the
  notification for the end says the same.
- **You archive or delete a session.** It leaves the Live Activity at once. If it was the
  last one, the Live Activity goes at once.
- **You turn Live Activities off.** The Live Activity goes at once.

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
  not run. A push carries no words, so the line cannot say the question, and the title
  says how many sessions, such as **2 sessions**. Open the app to read it.
- **The Live Activity does not change while the app is shut.** Your control plane sends
  updates by push only when it has an APNs key. A control plane on your Mac has none. See
  [How a Live Activity keeps up](../explanation/live-activities.md).

## See also

- [How a Live Activity keeps up](../explanation/live-activities.md)
- [See what needs you from your Home screen](see-what-needs-you-from-your-home-screen.md)
- [Answer a question or a permission request](answer-a-question.md)
- [How the phone and iPad reach your agents](../explanation/phone-and-ipad.md)
