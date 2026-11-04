---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Let an agent use the apps on your Mac through its screen, mouse and keyboard, and watch it work from your iPhone, iPad or the web page.
---

# Let an agent drive desktop apps

Some work has no API: an app's own window, a dialog, a setting that is only in a menu.
With **Desktop control** on, an agent can use any app on your Mac through its screen,
mouse and keyboard, not only a browser. While it works, every client shows a live tile of
the Mac's screen, so you can watch from your iPhone, your iPad or the web page.

## Before you start

- A Mac with Agents Host. Desktop control is only on a Mac: an agent on a Linux server
  does not get the tool.
- Desktop control is **off** until you turn it on. Until then, no agent can click, type or
  read the screen of another app.

## Turn desktop control on

1. Open the setting:
   - **Mac**: **Settings ▸ Machines ▸ This Mac**.
   - **Web page**: **Settings ▸ Machines**.
2. Turn on **Let an agent drive apps on this Mac**, under **Desktop control**.
3. The first time an agent tries, macOS asks you to grant **Agents Host** the
   **Accessibility** permission. Grant it in **System Settings ▸ Privacy & Security ▸
   Accessibility**. Until you do, the agent is told what to grant, and nothing is driven.
4. The first picture of the screen asks for **Screen Recording** in the same place. Until
   you grant it, the agent is told it could not capture the screen, and the live tile
   says **Waiting for the first look at the screen…** above what the agent did last.

## What the agent can do

The agent uses the app tool `drive_screen`. It names the app, and then it can:

- click a button, menu item or other control by its label, or at a place on the screen;
- type text, with real keystrokes;
- press one named key, such as Return;
- read the app's own list of controls;
- take a picture of the whole screen.

Only one agent drives the screen at a time. The first call takes the `screen` lease. An
agent that calls the tool while another one holds the lease waits in line. The lease is
let go when the turn ends.

## Watch it work

Open the session on any client: the Mac window, the Remote on an iPhone or iPad, or the
web page. While the agent holds the screen, the chat ends with a tile:

- **Driving the Mac's screen**, the latest picture of the Mac's screen;
- under it, what the agent did last, such as *Clicked Save in TextEdit.*

The tile shows a new picture after each action, and at least every 5 seconds while the
agent is thinking. You do not have to set anything up.

While the Mac's screen is locked, the tile says **Mac is locked** and shows no picture.
The agent keeps working.

The pictures go only to the clients that show the session. They are not kept: no picture
is written to disk or put in the chat's history.

## Take the screen back

- **Use your mouse or keyboard.** If you move the real mouse or press a real key while an
  agent holds the screen, the agent stops where it is. Every client shows a card:
  - **Resume** lets the agent go on from where it stopped.
  - **Take Over** gives you the screen back for the rest of the turn. The agent cannot
    drive the screen again until its next turn.
- **Stop** the turn, as for any turn. The screen is let go at once.

## Related

- [Use Agents in a browser](use-agents-in-a-browser.md): the web page, where the tile
  shows too
- [Watch background work](watch-background-work.md)
- [Agent tools](../reference/agent-tools.md): `drive_screen`
