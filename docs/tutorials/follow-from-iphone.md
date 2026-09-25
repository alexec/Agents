---
diataxis: tutorial
devices: [mac, iphone]
description: Put Agents on your iPhone, see the agents on your Mac, answer one, and start another.
---

# Follow your agents from your iPhone

In this tutorial you put Agents on your iPhone, find the agent you started in
[Your first agent](first-agent.md), and start a second one from the phone. It takes about
ten minutes. The same steps work on an iPad.

**What you'll have at the end:** your Mac's projects and agents on your phone, one agent
started from it, and a question from an agent answered without going back to the Mac.

## Before you start

- You have finished [Your first agent](first-agent.md), so your Mac has a project with an
  agent in it.
- Your iPhone and your Mac are on the same Wi-Fi network.
- You have Xcode and a free Apple developer account, so that Xcode can put an app on
  your own phone.

## 1. Put Agents on your iPhone

Agents is not in the App Store yet, so you build it onto your phone from the same copy of
the source you built the Mac app from.

1. Connect your iPhone to your Mac with a cable, and unlock it.
2. In Xcode, choose the **Remote** scheme, then choose your iPhone as the destination.
3. Choose **Product ▸ Run**.

The first time, Xcode asks you to pick a team for signing. Pick your own. Your phone may
also ask you to trust the developer, under **Settings ▸ General ▸ VPN & Device
Management**.

You should see Agents open on your phone and say it is looking for your Mac.

## 2. Open the door on your Mac

The phone reaches the Mac through a small helper, `agents-bridge`, that you start
yourself and stop when you are done. In Xcode, choose the **agents-bridge** scheme with
**My Mac** as the destination, and choose **Product ▸ Run**.

!!! warning "Anyone on this network can reach it"

    While the helper runs, a device on the same network can see and drive your agents
    without asking. Run it on a network you trust, and stop it (**Product ▸ Stop**) when
    you have finished.

You should see the phone stop searching and show **Projects**, with the project you made
in the first tutorial.

## 3. Find your first agent

Tap your project.

You should see the agent from the first tutorial, in the **Complete** group, with the
first words of what you asked it. Tap it to read the whole conversation, exactly as it
is on the Mac.

## 4. Start an agent from the phone

1. Go back to the project and tap **New agent**.
2. Leave **Runtime** as it is. It is the runtime your Mac has set up.
3. In **What should it do?**, type:

    ```text
    Add a test for the low temperature in Celsius, and run the tests.
    ```

4. Tap **Start agent**.

You should see the new agent appear under **Working**, and its conversation fill in as it
reads the code.

## 5. Answer it from the phone

Before it changes a file, the agent asks for permission, just as it did on the Mac.

You should see the agent move to **Needs attention**, and a card in its conversation
naming what it wants to do. Tap **Yes**. The agent carries on, and ends in
**Complete**. On the Mac, the same agent shows the same answer.

## Where next

- [Answer a question or a permission request](../how-to/index.md), including from a
  notification when your Mac is not in use.
- [Start an agent in its own worktree](../how-to/index.md), so two agents in one project
  do not change the same files.
- [How the phone and iPad reach the Mac](../explanation/index.md).
