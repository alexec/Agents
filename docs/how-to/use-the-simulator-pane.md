---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: See an iOS simulator on the session's Mac beside the conversation, boot or shut it down, and tap on its screen.
---

# Use the Simulator pane

When an agent builds an iOS app, you want to see what it made without leaving the
conversation. The **Simulator** pane shows the iOS simulators on the session's Mac. You
can boot one, see its screen, and tap on it, from the Mac, an iPhone, an iPad or the web
page.

## Before you start

- A session on a Mac with Xcode. The simulators are the ones on the session's host, not on
  the device you look from. A session on a Linux server has none: the pane says
  **Simulators run on a Mac. This host is not a Mac.**
- At least one iOS simulator, made in Xcode.

## Open the pane

- **Mac**: open the session's conversation. Click **Simulator** at the top of the sidebar
  on the right, or choose **View ▸ Simulator** (Command-7).
- **iPad**: open the conversation, tap **Panes** at the top, then choose **Simulator**.
- **iPhone**: open the conversation, open the **Actions** menu and choose **Simulator**.
- **Web page**: open the conversation and click **Files** in the chat's header (on a narrow
  page, **Files** in the **···** menu). Then click the **Simulator** tab.

On the iPhone and iPad, the pane is not offered while the Remote cannot reach the Mac.

## Steps

1. Choose a simulator in the menu at the top of the pane. Each one shows its name and its
   iOS version, and **Shut Down** when it is not running. Running ones are listed first.
2. If it is shut down, the pane says **‹name› is shut down. Boot it to see its screen.**
   Click **Boot**. The pane says **Booting ‹name›…** until it is done.
3. Its screen shows in the pane. The pane reads it again each second.
4. Click (on the Mac and the web page) or tap (on the iPhone and iPad) on the screen. That
   is a tap at that place on the simulator. The pane reads the screen again at once, so
   you see what the tap did.
5. Click **Home** to press the simulator's Home button.
6. When you are done, click **Shut Down**. The pane asks first, **Shut down ‹name›? The apps
   that run on it stop.**, because an agent or you may still need them. Click **Shut Down** to go on.

Click **↻** (**List the simulators again**) after you make or delete a simulator in Xcode.

The pane boots or shuts down a simulator only when you press the button. It reads the
screen only while the pane is on screen and its window can be seen, so a hidden pane costs
the host nothing. A tap goes to the simulator directly and does not move your pointer on
the Mac.

## What it needs

- **Xcode on the session's Mac.** Without it the pane says **Xcode is not on this Mac, so it
  has no simulators.** Taps and **Home** use the Xcode that the Mac has selected.
- **Agents Host on that Mac.** It carries the helper that sends taps. A host without it
  says **This host cannot touch a simulator: agents-watch is not beside agentsd.** You can
  still boot a simulator and see its screen.
- **A host that has the pane.** An older host says **This host needs an update to do
  this.** See [Versions](../explanation/versions.md).

The pane takes no lease. An agent can boot or drive the same simulator under a lease while
you look at it. See [Leases on shared resources](../explanation/leases.md).

## If it doesn't work

- **This Mac has no iOS simulators. Make one in Xcode.** Make one in Xcode, then click
  **↻**.
- **Couldn't list the simulators: ‹why›**, with **Try Again**: the host did not answer, or
  `simctl` failed. Click **Try Again**.
- **Not updating: ‹why›**: a screen read failed. The last screen stays, dimmed, until a read
  works again.

## See also

- [Read an agent's changes](read-an-agents-changes.md)
- [Edit files](edit-files.md)
- [Keyboard shortcuts](../reference/keyboard-shortcuts.md)
