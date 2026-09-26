---
diataxis: reference
devices: [mac, iphone, ipad]
description: Every control in Agents ▸ Settings on the Mac, and the system settings Agents uses on iPhone and iPad.
---

# Settings

This page lists every control in the Mac's Settings window, **Agents ▸ Settings…**, pane
by pane, and the system settings the app on iPhone and iPad depends on.

The Mac's Settings window has four panes: **Appearance**, **Spending**, **Devices** and
**Servers**. Agents on iPhone and iPad has no Settings screen of its own; it follows the
Mac it is paired with.

| Device | Pane | Control | What it does |
| --- | --- | --- | --- |
| Mac | Appearance | **Appearance**: **System**, **Light**, **Dark** | Sets the app's look. **System** follows your Mac, and changes with it. |
| Mac | Spending | **Per agent**, with an amount, a currency, **Set** and **No limit** | The most one agent may spend across its whole life, not one turn. An agent that reaches it finishes the turn it is in and takes no further prompt, so it may end a little over. If agents have already spent this much, the pane says so as you set it. |
| Mac | Spending | **Per day**, with an amount, a currency, **Set** and **No limit** | The most everything may spend in one local day, in every project. When the day reaches it, nothing new starts and no prompt is sent, including a workflow on a schedule. Whatever is working finishes its turn and holds. What you typed waits until the day rolls over. Each server keeps to this limit on its own. |
| Mac | Spending | **Today** | What today has cost so far, and how much is left under **Per day**. Shows **Nothing yet** before anything is spent. |
| Mac | Spending | **What the limits have stopped** | The agents that reached a limit, with what each spent. Shown only when there are some. |
| Mac | Devices | The list of devices | Every iPhone and iPad that has paired, with one line on each: **Paired**, **Last heard from** a time, **Has not said whether it can show notifications**, or **Notifications are off on the device — it will not be chosen**. A device is told when an agent needs you and your Mac is not in use. |
| Mac | Servers | The list of servers | Every server you have added, with its projects, whether it is connected, **Connecting…**, **Offline since** a time, **Update waiting — an agent is mid-turn** or what went wrong, its system, the version of Agents on it, and the runtimes installed there. |
| Mac | Servers | **Add a server** | Adds a server by the name you use with `ssh`. |
| Mac | Servers | **Check again** | Shown on the selected server. Tries connecting to it again. |
| Mac | Servers | **Remove…** | Shown on the selected server. Removes it from the app, stopping any agents running there. Its folders are not touched. **Also delete what Agents installed on** the server removes the app's own files there too. |
| iPhone and iPad | Settings ▸ Agents | **Local Network** | Lets the app find your Mac on the network you are both on. Without it, the app cannot reach your Mac. |
| iPhone and iPad | Settings ▸ Agents | **Notifications** | Lets the Mac tell this device when an agent needs you. When it is off, the Mac's **Devices** pane says so and the device is not chosen. |

When an agent reaches a spending limit, **Raise the limit** above the prompt opens the
Settings window.

## See also

- [How-to guides](../how-to/index.md)
- [Explanation](../explanation/index.md)
