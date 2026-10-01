---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Pair a window on another Mac, or an iPhone or iPad, with your control plane, change what it may do, and forget it.
---

# Connect a window or phone

Every window and device reaches your agents through your control plane. Each one is paired
once, with a code that works once, for five minutes, and is given a grant: **Operator**,
which may do everything, or **Device**, which may do what a phone does. See
[How the phone and iPad reach your agents](../explanation/phone-and-ipad.md) for what each
grant allows.

## Before you start

- A control plane, and a window already paired with it as an operator. See
  [Set up Agents on this Mac](set-up-on-this-mac.md), or
  [Run the control plane as several copies](run-several-copies.md).
- Agents on the other Mac, iPhone or iPad.
- If the control plane runs on your Mac, the other Mac or the device on the same network
  as it.

## Steps

### Connect a window on another Mac

1. In a paired window, open **Settings ▸ Control plane**, and click **Show** beside
   **Clients**.
2. Click **Pair a Mac…**. Under **It may**, choose **do everything (Operator)** or **what a
   phone can (Device)**, then click **Copy**.
3. On the other Mac, open Agents. It asks **Where should your agents run?** Under
   **Connect to a control plane**, click **Connect…**.

   If Agents Host runs on that Mac, the window says **Agents Host is running on this Mac**
   instead. Click **Connect to a different control plane…**.
4. Paste the code under **CODE** and click **Connect**.

   The window is paired, and lists the projects on every host.

On the Mac that runs Agents Host, you can also get a code from Agents Host itself: click
**Pair a Window or Phone…**, choose **A window on a Mac**, and click **Copy**. That code
always pairs an operator.

### Connect an iPhone or iPad

1. In a paired window, open **Settings ▸ Control plane**, and click **Show** beside
   **Clients**.
2. Click **Pair a Device…**. The window shows a code to scan.
3. On the iPhone or iPad, open Agents. It says **Connect to your agents**. Tap **Scan the
   Code** and point the camera at the code.

   The device is paired as a **Device**, and lists the projects on every host, each under
   its host's heading.

On the Mac that runs Agents Host, you can also get the code from Agents Host itself: click
**Pair a Window or Phone…**, choose **An iPhone or iPad**, and scan the code it shows.
Without a camera to hand, click **Copy** there instead. Get the text to the device
(Universal Clipboard does it), then tap **Paste** in Agents on the device.

An iPhone or iPad whose Agents predates the control plane can't read these codes. It says
**That isn't a pairing code from Agents on your Mac.** Install the current Agents on it
first.

### Change what a client may do

1. Open **Settings ▸ Control plane**, and click **Show** beside **Clients**.
2. Beside the client, choose **Operator** or **Device**.

   Its next request is judged by the new grant. It does not need pairing again.

### Forget a window or device

1. Open **Settings ▸ Control plane**, and click **Show** beside **Clients**.
2. Beside the client, click **Forget…**, then **Forget**.

   It is cut off at once, directly and through the relay, and its next attempt to connect
   is refused. To use it again, pair it again with a new code.

The app will not let you demote or forget the last operator, and says why.

## If it doesn't work

- **That isn't a control plane's code. It starts with agents-control:.** The window was
  given something else. Copy the code again.
- **This is a code for a host.** It adds a machine that runs agents, not a window. Ask for
  a code from **Pair a Mac…** instead, or see [Add a server](add-a-server.md).
- **That code is for adding a host, not a phone.** On the device: the same mistake. Use a
  code from **Pair a Device…**.
- **The control plane didn't take that code. It may have run out: show a new one and try
  again.** A code works once, for five minutes. Close the sheet and open it again for a
  new one.
- **The control plane can't reach where it keeps its records, so nothing was changed.**
  Its store is down. Pairing, grant changes and forgetting wait until it is back; agents
  that are running carry on.
- **Can't reach the control plane.** The window or device cannot reach its address. If
  it runs on your Mac, check that the Mac is awake and on the same network.

## Related

- [The control plane](../explanation/control-plane.md).
- [Answer a question or a permission request](answer-a-question.md).
