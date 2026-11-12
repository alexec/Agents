---
name: scratch-host-dies-on-a-reused-slug
description: run-app's scratch agentsd exits silently when its root path was used before by another build; pick a new --slug
metadata:
  type: project
---

On 2026-11-12 (#4974) `launch.sh --slug pv2` started an `agentsd` that exited about 10 s later
with nothing in `host.out`. `logs/daemon.log` ended with "this machine's key: the Keychain did
not let this program read the item". The login Keychain was unlocked. The host key's Keychain
item is named from the root path (`controllink.HostKeyService(root)`), so an item that another
build made for the same `/tmp/run-<slug>` is not readable by a new build, and the host stops.
A new slug (`p2tok`) started at once.

**Why:** the failure looks like a locked screen or a broken main, and costs time to find.

**How to apply:** when a scratch host dies after that log line, launch again with a slug no
earlier walk used. See [[drive-the-scratch-app-only-when-alex-is-away]] for the other walk rules.
