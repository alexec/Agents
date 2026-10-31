---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Turn Relay for my devices on in Agents Host, so your iPhone and iPad reach your agents away from home and are told when an agent needs you, or turn it off.
---

# Turn the relay on or off

**Relay for my devices** is a switch in Agents Host on a Mac. When it is on, your iPhone
and iPad reach your agents through your own iCloud account when they are away from home,
and they get a notice when an agent needs you. It is off until you turn it on.

The relay exists because a control plane on your Mac at home has no address that a phone
on another network can reach. The relay carries the same requests and updates through
iCloud instead, each one sealed so that only your control plane and that one device can
read it. Nothing passes through a server of ours. See
[How the phone and iPad reach your agents](../explanation/phone-and-ipad.md) for more.

**Why turn it on:** you want to answer your agents from your phone when you are out, and to
be told when one asks you something.

**Why leave it off:** your devices are only ever on the same network as the control plane,
or your control plane has an address on the internet, so the devices reach it from any
network with no relay. While the relay is off, nothing of yours goes through iCloud.

## Before you start

- A Mac with Agents Host, set up either to **Run It Here** or to **Join one elsewhere**.
  See [Set up Agents on this Mac](set-up-on-this-mac.md).
- iCloud signed in on that Mac and on each iPhone and iPad, with the same account.
- An iPhone or iPad that is paired. See
  [Connect a window or phone](connect-a-window-or-phone.md).

## Turn the relay on

1. Open Agents Host from the menu bar, and click **Open Agents Host**.
2. Under **CONTROL PLANE**, find **Relay for my devices**.

   With the relay off, the line under it says: "Your iPhone and iPad reach your agents
   through your iCloud when away, and are told when an agent needs you."
3. Turn on the switch.

   - **If this Mac runs the control plane,** that is all. Agents Host makes the relay's
     code itself. The switch works only while the control plane runs.
   - **If this Mac joins a control plane elsewhere** (on a server, for example), Agents
     Host asks for a join code the first time. Continue with step 4.
4. Get a join code from your control plane. In the Agents window, open **Settings ▸
   Control plane**, click **Add by Code…** under **Hosts**, then click **Copy**.
5. In Agents Host's **Relay for My Devices** sheet, paste the code under **Join code** and
   click **Start Relay**.

   The relay joins the control plane as a host that runs no agents.

The line under the switch says **Joining the control plane…** and then: "On: your iPhone
and iPad reach your agents through your iCloud when away, and are told when an agent needs
you."

On an iPhone or iPad away from home, the top of the screen then says **Away** and
**slower, through iCloud**. The relay is slower, so the terminal, the live page, files and
attaching pictures wait until the device is back on a network that reaches the control
plane.

## Turn the relay off

1. Open Agents Host from the menu bar, and click **Open Agents Host**.
2. Under **CONTROL PLANE**, turn off **Relay for my devices**.

   Agents Host tells the control plane that the relay is off, and stops the relay. Your
   devices stay paired. Away from home they reach your agents only where they can reach
   the control plane's address. A notice reaches them only when the control plane is set up
   to send push notifications itself. See
   [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md#notifications).

Agents Host keeps the relay's enrolment. When you turn it on again, it starts again at once
and asks for no code.

If you choose a different control plane in Agents Host later (**Join one elsewhere** again,
or **Run It Here Again…**), Agents Host stops the relay, tells the old control plane, and
forgets that enrolment. The next time you turn it on there, a control plane elsewhere asks
for a new join code.

## See whether the relay is on

- **On the Mac,** the Agents window shows it in **Settings ▸ Control plane**, on the row
  **Reachable away from home**:
  - **Through your iCloud account, sealed to each device**: a relay is on.
  - **Off: devices reach it on this network only. Turn on Relay for my devices in Agents
    Host on a Mac.**: no relay is on for this control plane.
  - **On the internet at** an address: devices reach it from any network, with no relay.
- **In Agents Host,** **Copy Diagnostics** includes a line **Relay for my devices:** with
  **on** or **off**, and whether the relay has joined.
- **On iPhone and iPad,** there is no switch. The device uses the relay by itself when it
  cannot reach the control plane's address.
- **On the web page,** there is no switch and no relay. A browser reaches the control
  plane only at its address.

## If it doesn't work

- **The switch is greyed out.** Where this Mac runs the control plane, the line says **Turn
  it on while the control plane runs.** Start the control plane first. While this Mac waits
  for its control plane to come back, the line says **Turn it on once your control plane is
  back here.**
- **That isn't a join code.** The code you pasted is for a window or a device, not a host.
  Get one with **Add by Code…**, as in step 4. The message calls the button **Add a Mac**.
- **Allow Agents Host in System Settings ▸ General ▸ Login Items, then try again.** macOS
  did not let the relay start. Allow Agents Host there, and turn the switch on again.
- **The line under the switch is orange.** The relay is on but not running, and the line
  says why. Click **Copy Diagnostics** to see the relay's log, `relay.log`.
- **The iPhone or iPad says "The relay needs iCloud on your iPhone and your Mac".** Sign in
  to iCloud on both, with the same account.
- **The iPhone or iPad says "iCloud is full, so the relay can't carry messages".** Free
  space in iCloud.

## See also

- [How the phone and iPad reach your agents](../explanation/phone-and-ipad.md)
- [Set up Agents on this Mac](set-up-on-this-mac.md)
- [Add a machine](add-a-machine.md)
- [The control plane](../explanation/control-plane.md)
