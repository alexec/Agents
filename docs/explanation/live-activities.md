---
diataxis: explanation
devices: [iphone, ipad]
description: Why a turn sent from the iPhone or iPad shows as a Live Activity, how its updates reach the device, and why a pushed update carries no words.
---

# How a Live Activity keeps up

A turn you send from the iPhone or iPad app shows as a Live Activity on the Lock Screen
and in the Dynamic Island (#1657). This page explains why it is there, how each update
gets to the device, and what an update may carry. For the steps, see
[Follow a turn on the Lock Screen](../how-to/follow-a-turn-on-the-lock-screen.md).

## Why a turn you sent

When you send a prompt from your phone, you usually wait for the answer. A turn can take
minutes, and you do not want to keep the app open for all of that time. A notification
tells you about one moment. A Live Activity shows the whole turn: that it works, what step
it is on, that it asks you something, and how it ended.

The app shows only turns you sent from that device, or sessions you started there. A
turn that a workflow started, or that you sent from the Mac, is not in it. The Lock
Screen is a small space, and a Live Activity for every turn on every host would fill it
with work you did not ask to follow.

## One Live Activity, not one for each session

A device shows one Live Activity in total (#2991). Three turns that run at the same time
are one banner on the Lock Screen, not three. The banner shows the session that most
needs you: one that asks a question or an approval, else the one you sent a prompt to
last. A line under it counts the others, and the time counts from the oldest turn that
still runs. A turn that ends while others run leaves it; the last one to end ends it.

## Two ways an update arrives

An update comes in one of two ways, and the device takes whichever comes.

**From the app's own connection.** While the app runs, it already receives every change
to its sessions from the control plane. It works out what the Live Activity says from
that, with the same rules the sidebar uses, and updates it. These updates carry words:
the session's title, the step it is on, the question, the report or the reason it
stopped.

**By push from the control plane (#1744).** iOS suspends an app soon after you leave it,
and a suspended app cannot update anything. So when the app asks iOS for a Live Activity,
it also asks for a push token for it. It gives that token to the control plane over its
own paired connection. After that, the update goes this way:

- The host that runs the session tells the control plane each time the turn moves to a
  new phase.
- The control plane keeps that phase on the Live Activity's token for that session. The
  app gives the one token once for each session the Live Activity speaks for.
- It works out the new summary with the same rule as the app, and sends it through Apple
  Push Notification service (APNs).

The time on the Live Activity needs neither. The system counts it from the time the turn
began, so it moves also when nothing reaches the device.

A Live Activity that has heard nothing for 10 minutes while it works says **Open Agents
to see where it is**. The step it showed may be old by then, and a Lock Screen that shows
an old step as the current one tells you something false.

## What a pushed update carries

A pushed update carries only these:

- the phase of the session it shows: working, question, approval, done, needs you,
  paused or failed;
- the session's id, so a tap opens it;
- how many other turns ask and how many work;
- when the oldest turn started;
- when it ended, once the last one has ended.

It never carries the session's title, a step, a question or a line of the chat.

The reason is who can read it. A notification from Agents is sealed with your device's
own key, and only your device opens it. A Live Activity's state cannot be sealed. iOS
gives it straight to the widget that draws it, and no code of ours opens it first. So
Apple can read every pushed state, and we do not send Apple your words.

That is why the title of a pushed Live Activity says how many sessions, such as
**2 sessions**, and its line says where to go, not what is there: **Open Agents to answer it**, **Open Agents to decide** or
**Open Agents to see what it needs**. When you open the app, its own connection gives the
words back.

## The end of a turn

When the last turn ends, the Live Activity shows how it ended and stays for 15 minutes. The
notification for the end says the same, so there is no reason to keep it for the four
hours iOS allows. When you archive or delete a session, it leaves the Live Activity at
once, and when it was the last, the Live Activity goes at once.

When a Live Activity ends, the control plane forgets its token. A token that Apple says
is no longer good is forgotten too. A device record keeps at most 16 tokens, and each one
goes after 12 hours: eight hours that a Live Activity can show, and four more after it ends.

## Without a push

A push needs a control plane with an APNs key. A control plane in the cloud gets one when
you set it up with `--apns` (see
[Run the control plane in the cloud](../how-to/run-the-control-plane-in-the-cloud.md)).
A control plane on your Mac has no key.

Without a key, the Live Activity still starts, still counts the time, and still updates
while the app runs. While iOS has the app suspended, it does not change. After 10 minutes
it says **Open Agents to see where it is**, and it catches up when you open the app.

## With the relay off

**Relay for my devices** carries notifications through your iCloud account (see
[How the phone and iPad reach your agents](phone-and-ipad.md)). A Live Activity does not
use it, because CloudKit cannot update a Live Activity. A pushed update always goes from
the control plane through APNs, with the relay on or off.

So the relay changes nothing for a Live Activity. With the relay off, the app's own
updates still come while it runs and can reach the control plane, and pushed updates still
come while it does not. What you lose with the relay off is the notifications that a Mac
host sends through iCloud.

## Only on the iPhone and iPad

The Mac window and the web page have no Live Activities, by design. A Live Activity is a
feature of the iPhone and iPad Lock Screen. On the Mac, the window's own notifications
and the Dock badge tell you when a turn needs you.

## Related

- [Follow a turn on the Lock Screen](../how-to/follow-a-turn-on-the-lock-screen.md)
- [How the phone and iPad reach your agents](phone-and-ipad.md)
- [The control plane](control-plane.md)
- [Statuses and groups](../reference/statuses.md)
