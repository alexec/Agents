# Walk: OpenCode MVP (T017), 2026-09-29

On scratch roots `/tmp/run-oc` then `/tmp/run-oc4` (run-app skill), built from this branch, with
the scratch app's `XDG_*` and `npm_config_cache` under `/tmp/run-ochome`, so OpenCode's own
first-run files never reached the real home. `~/.config/opencode` and `~/.npm` were unchanged
(last modified 2026-09-12). The screen was locked throughout, so this walk is over the socket;
the window look is still to do.

## What was proved

| Step | Result |
|---|---|
| Listed before install | `opencode` **missing**, looked only in `<root>/tools/opencode/current/bin` |
| **Install** (`runtimes/install`) | 4 s from GitHub; the row said "Downloading OpenCode (46 MB)", "Checking the download", "Unpacking OpenCode" (`us1-install-progress.jsonl`); `ok` written, `current` set |
| First turn: "Create hello.txt … then run ls" | two permission cards (edit, then `ls`), each answered once; the file written through the app (`servedRequest writeFile`); `finish_turn` called; usage recorded with **no cost** (Zen's zero dropped) |
| Stop the app, relaunch the same root, prompt again | "Picked the conversation back up."; answered "Hello, world!" from memory; first word **2.8 s** after the prompt, including OpenCode's start |
| Model and mode | `opencode/big-pickle`, `build` (OpenCode's defaults) |

## Found and fixed during the walk

Every turn first took 43–55 s. The cause was `TMPDIR`: OpenCode walks it at the start of a
turn, and this Mac's per-user temporary folder holds ~900,000 entries (research R11). OpenCode
now gets `TMPDIR=<root>/runtimes/opencode/tmp`. After that, the first card of a new agent came in
18 s (model thinking included) and a resumed turn's first word in 2.8 s.

Also seen: on one turn the free model ended without `finish_turn`; the app's existing nudge got
the report on the next turn, as for other runtimes.

## Still to walk

- The window: the set-up sheet's OpenCode row ("46 MB from GitHub"), the chat, the model and mode
  menus, and the meter showing no "$0". Needs the screen unlocked.
