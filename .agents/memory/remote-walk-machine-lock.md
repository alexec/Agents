---
name: remote-walk-machine-lock
description: A Remote walk that reads machines must pair the phone first on a fresh scratch root, so the phone founds the machine lock; then approve hosts with walk.py's "=" exact match.
metadata:
  type: project
---

On a scratch set-up, a machine refuses the Remote's direct calls (`runtimes/list`, `machine/usage`) with "the request is not signed by one of them" when the phone is not in the machine lock (#3490). Pairing the phone again later (`remote.sh up … -pair`) uninstalls it and makes it a new device outside the lock.

**Why:** found walking #4034 (2026-11-08): the machine page was empty and the sidebar listed nothing after a re-pair.

**How to apply:** start the scratch root, add a folder, pair the phone first (it founds the lock and shows a recovery key: press "I Saved It"), then join extra hosts (`agents-control code --host`, a second `agentsd --control-code … --host-name …` under `$ROOT/<x>`). Approve each with `walk.py remote press "=Compare Digits"` then `"=Approve"`: a leading `=` matches the label exactly, else the card's "Approve the new machine…" text wins. Reinstall a new build with `remote.sh up APP` and no `-pair`, which keeps the pairing. walk.py cannot press swipe actions or open a long-press menu on the Remote.

**Host to host on the Mac (#4640, 2026-11-11).** A walk of a host-to-host call (Send to, Bring Back, `machines/sendFolder`) with a second scratch `agentsd` is refused with "the key is not in your lock" until the scratch Mac window approves *both* hosts, this Mac's scratch host as well as the second one: `walk.py $ROOT press "=Compare Digits"`, then `"=Approve"`, once per card.
