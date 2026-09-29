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

# Walk: US4 and US3 (T022, T027), 2026-09-29

Scratch root `/tmp/run-oc6`, built from `48961b13`, the same scratch XDG home. Screen locked, so
over the socket again (`us3-us4-transcript.jsonl`).

| Step | Result |
|---|---|
| Sign in (`runtimes/authenticate opencode-login`) | refused with the sheet's command: `/tmp/run-oc6/tools/opencode/current/bin/opencode auth login` — the app's copy by full path, never a bare `opencode`; the account's method carries the same |
| That command | `opencode auth --help` lists `login` and `logout`; `auth list` on the scratch home: 0 credentials |
| A model of an unsigned provider, remembered while idle | at the next start: "OpenCode isn’t signed in to anthropic, so it can’t use anthropic/claude-haiku-4-5. Sign it in from the runtime menu, then pick the model again."; the choice forgotten; the turn went on |
| Tools, asked by prompt | all 16 `agents_*` tools; `task` absent, `todowrite` present |
| A question | through `agents_ask_form`: a form card held by the daemon, answered over the socket, the answer read back by the agent, then `finish_turn` |
| **Always approve** (`clientPermissions/set` opencode) | a file write and `cat` ran with no card; the setting persisted |

## Found and fixed during this walk

The first try of the unsigned model found it refused at start **in silence**: the turn ran on
the free default while the menu still said Haiku. Any remembered choice a runtime refuses at
start now leaves a note and is forgotten (48961b13), for every runtime.

## Still to walk (needs the screen)

- The sign-in sheet for OpenCode: its button, the command with **Open Terminal** and **Copy**, and
  the "To sign a provider out, run … auth logout" line while it reads ready.
- Settings ▸ Agent Runtimes: OpenCode's Ask / Always approve row.
- The set-up sheet's row, the chat, the menus and the meter (from the first walk).
