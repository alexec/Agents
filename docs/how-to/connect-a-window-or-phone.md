---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Pair a window on another Mac, an iPhone or iPad, or a browser on this Mac with your control plane, connect this Mac to another control plane, and forget a client.
---

# Connect a window or phone

Every window and device reaches your agents through your control plane. Each one is paired
once, with a code that works once, for five minutes, and may then do everything a window
on this Mac may. See [The control plane](../explanation/control-plane.md#one-grant-for-every-client)
for why every client is trusted alike, and what that risks.

## Before you start

- A control plane, and a window already paired with it. Agents on a Mac sets up both the
  first time you open it. See [Set up Agents on this Mac](set-up-on-this-mac.md), or
  [Run the control plane as several copies](run-several-copies.md).
- Agents on the other Mac, iPhone or iPad.
- If the control plane runs on your Mac, the other Mac or the device on the same network
  as it.

## Steps

### Connect a window on another Mac

Agents on the other Mac sets up its own control plane the first time it opens. To use
your control plane instead, connect it with a code. Its window and its host join
together.

1. In a paired window, open **Settings ▸ Control plane**, and click **Show** beside
   **Clients**.
2. Click **Pair a Mac…**, then click **Copy**.
3. On the other Mac, open Agents, then open **Settings ▸ Control plane** and click
   **Connect to Another…**.
4. Click **Use a Code…**, paste the code, and click **Next**.
5. The sheet says what happens next. Click **Connect**.

   The window is paired, and that Mac is a machine of your control plane. The window lists
   the folders on every host. The control plane on that Mac stops. Its iPhone, iPad and
   browsers must pair again.

A code from **Add a machine by code** is for a machine, not a window. The sheet refuses it.

### Connect this Mac to another control plane

To use Hosted at agentloops.dev, or a control plane that you run somewhere else, in place
of the one on this Mac:

1. Open **Settings ▸ Control plane**, and click **Connect to Another…**.
2. Choose one:
   - **Sign In to agentloops.dev**, with Apple, Google or GitHub. A new account gets a
     control plane of its own.
   - **Use a Code…**, with a code from **Settings ▸ Clients ▸ Pair a Mac…** on the control
     plane that you run. Paste it and click **Next**.
3. The sheet says what happens: this Mac's agents report to the other control plane, your
   sessions stay on this Mac, your iPhone, iPad and browsers must pair again, and the
   control plane on this Mac stops. Click **Connect**.

   The window and this Mac's host join the other control plane together. You sign in or
   paste one time only.

To go back, open **Settings ▸ Control plane** and click **Use This Mac Only**, then
**Use This Mac Only** again. The control plane on this Mac starts again, as it was, and
this Mac's host and the window go back to it. Your sessions stay on this Mac.

### Connect an iPhone or iPad

1. In a paired window, open **Settings ▸ Control plane**, and click **Show** beside
   **Clients**.
2. Click **Pair a Device…**. The window shows a code to scan.
3. On the iPhone or iPad, open Agents. It says **Connect to your agents**, with the sign-in
   first. Tap **Use a Code Instead…**, then **Scan the Code**, and point the camera at the
   code.

   The device is paired, and lists the folders on every host, each under its host's
   heading.

On the Mac that runs the control plane, **Pair a Phone or iPad…** in the Agents menu bar
item opens the same code.

An iPhone or iPad whose Agents predates the control plane can't read these codes. It says
**That isn't a pairing code from Agents on your Mac.** Install the current Agents on it
first.

### Connect a browser on this Mac

1. In a paired window, open **Settings ▸ Control plane**, and click **Show** beside
   **Clients**.
2. Click **Add a Browser…**, then click **Copy**.
3. In Safari or Chrome on the Mac that runs Agents, open **http://localhost:8792**,
   paste the code, and click **Connect**.

Only a browser on that Mac can use the code, and a code from **Pair a Device…** or
**Pair a Mac…** does not pair a browser. **Open in Browser** in the Agents menu bar item
pairs the default browser with no code. See
[Use Agents in a browser](use-agents-in-a-browser.md) for what the page can do.

### Forget a window or device

1. Open **Settings ▸ Control plane**, and click **Show** beside **Clients**.
2. Beside the client, click **Forget…**, then **Forget**.

   It is cut off at once, and its next attempt to connect
   is refused. To use it again, pair it again with a new code.

Any client may be forgotten, the last one too. If none is left, open Agents on the Mac
that runs the control plane: its window pairs itself again.

## If it doesn't work

- **That isn't a control plane's code. It starts with agents-control:.** The window was
  given something else. Copy the code again.
- **This is a code for a machine.** It adds a machine that runs agents, not a window. Ask
  for a code from **Pair a Mac…** instead, or see [Add a machine](add-a-machine.md).
- **That code is for adding a host, not a phone.** On the device: the same mistake. Use a
  code from **Pair a Device…**.
- **The control plane didn't take that code. It may have run out: show a new one and try
  again.** A code works once, for five minutes. Close the sheet and open it again for a
  new one.
- **The control plane can't reach where it keeps its records, so nothing was changed.**
  Its store is down. Pairing and forgetting wait until it is back; agents
  that are running carry on.
- **Every paired client may do everything now, so there is no grant to change.** An older
  window still shows an **Operator**/**Device** choice. Update Agents on that Mac.
- **Can't reach the control plane.** The window or device cannot reach its address. If
  it runs on your Mac, check that the Mac is awake and on the same network.

## Related

- [Sign in with Google, Apple or GitHub](sign-in-with-google-apple-or-github.md): pair with no code.
- [The control plane](../explanation/control-plane.md).
- [Use Agents in a browser](use-agents-in-a-browser.md).
- [Answer a question or a permission request](answer-a-question.md).
