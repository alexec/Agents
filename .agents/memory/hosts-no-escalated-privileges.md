---
name: hosts-no-escalated-privileges
description: "Agents Host and agentsd (Mac and Linux) must never need admin/root, including for updates"
metadata:
  type: project
  modified: 2026-10-11T20:14:08.871Z
---

Alex 2026-10-11: Agents Host and agentsd should avoid escalated privileges. Today they already do: user LaunchAgents via SMAppService.agent, systemd --user, everything under ~/.agents-server, no sudo (RuntimeInstaller refuses to retry with sudo). Only `loginctl enable-linger` is printed as an optional hint.

**Why:** stated as a design constraint while discussing how hosts update (no auto-update exists yet).

**How to apply:** any update or install work (Sparkle, hosts/update over the uplink, restarting agentsd on a new build) must work as the user: no SMJobBless/LaunchDaemons, no Sparkle installer helper that asks for admin, no sudo/root on Linux. When the app bundle isn't writable by the user, say so and stop rather than prompting for a password.
