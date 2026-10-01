# Notes for App Review

Agents is a window onto coding agents that run on the person's own machines: a Mac of
theirs, or a server they rent. The window and the phone app do not run agents themselves.
They connect to a *control plane*, a small service the person runs, and every agent, file and
terminal they show is on one of its hosts.

To review the apps without a Mac or server of your own, connect them to our demo control
plane. It has one host, and on it one runtime, **Demo**, which says back what you tell it. It
signs in to nothing, and needs no account from you.

## Connecting

**On iPhone or iPad (Agents):**
1. Copy this device code.
2. Open Agents. On **Connect to your agents**, tap **Paste**.

   ```
   <device code>
   ```

**On the Mac (Agents):**
1. Open Agents. On **Where should your agents run?**, choose **Connect…**.
2. Paste this code, then **Connect**:

   ```
   <operator code>
   ```

Each code works once and lasts 60 days. If one has already been used, write to us at
<contact> and we will send another at once.

## What to try

1. The project **Welcome** is on **Demo host**. Open it.
2. Start an agent there with the **Demo** runtime, the only one available on this host.
3. Type a prompt and send it. The agent answers "You said: …" and finishes its turn.
4. On the Mac, **Settings ▸ Control plane** lists the demo control plane, its host and the
   clients connected to it, including the phone once it has connected.

## Why the host is not in the Mac App Store app

The Mac app is sandboxed and runs nothing. Agents run under a separate download, **Agents
Host**, on a Mac or server the person chooses, because running an agent means running the
programs it asks for, in the person's own folders. Agents Host is distributed outside the App
Store and is not needed to review these apps: the demo control plane is its stand-in.

## Contact

<contact>
