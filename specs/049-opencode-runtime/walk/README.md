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

# Walk: US5 servers (T034), 2026-09-29

Scratch root `/tmp/run-oc7`, built from `75f47b9c` with the Linux helpers rebuilt, the scratch
app's `XDG_*` under `/tmp/run-oc7home`, whose `auth.json` held a **fake** Anthropic key (`api`)
and a fake OpenAI browser sign-in (`oauth`). The server was `agents-devbox` (Linux aarch64, glibc
2.36, no AVX2), seeded with a fake Groq key of its own in `~/.local/share/opencode/auth.json`.
Turns went over the window's forward on a connection of the walk's own, which offered and lent the
way the window does (the window's reading of `auth.json` is `OpenCodeFileSignInTests`).

| Step | Result |
|---|---|
| OpenCode installed on the scratch Mac, window connects | `opencode installing` → `ready("c6fda4c6c21060d9")` in 8 s: the Mac downloaded, checked and streamed it; `ok`, `manifest.json`, `bin/opencode`, `current` swapped; `opencode --version` on the box: 1.18.33 |
| A Zen turn ("run uname -sm") | asked before `uname -sm`; "Linux aarch64"; answered and called `finish_turn`, 12 s |
| A start with the sign-in offered | refused first with `credentialWanted` (offered), started nothing; after `credentials/lendSignIn`, started once |
| That run's model menu | anthropic 19 (lent), groq 16 (the server's own, kept under it), opencode 8; **no openai**: the browser sign-in stayed on the Mac |
| A turn on `anthropic/claude-haiku-4-5` | "A provider refused the key this Mac lent OpenCode. Sign in to it again on the Mac with opencode auth login, then send again." ended `signInRefused`, not "stopped answering" |
| `grep -r` for the lent key in `~`, `/tmp`, `/var/tmp` on the box | **0 files**; nor the kept sign-in; the only `auth.json` is the server's own, unchanged |
| An "own sign-in only" connection | `credentials/lendSignIn` refused (notOffered); the run had groq 16 + opencode 8 only |
| The scratch Mac root | the lent key in no file |

Measured on the way (research R12): `OPENCODE_AUTH_CONTENT` **replaces** `auth.json`, it does
not add to it. Hence the merge of the server's own non-rotating entries under the lent ones.

Seen and not this branch's: the devbox has no `xz`, so Codex's Node toolset fails there with
tar's own words; `ToolsetInstaller.refusal` does not check for `xz`.

Not walked: a turn that a lent provider answers (no real key on this Mac), a musl server, and the
install progress line in Settings ▸ Servers on screen.

# Walk: the window (T017, T022, T027, T034 looks), 2026-09-29

The same scratch root `/tmp/run-oc7`, on screen, by AX by pid with you away. Screenshots in `screens/`.

| Look | What it shows |
|---|---|
| `setup-sheet.png` | Install your agents: OpenCode ticked, its path the root's own `tools/opencode/current/bin/opencode` |
| `settings-opencode.png` | Settings ▸ Agent Runtimes ▸ OpenCode: the path, "OpenCode permission mode: Default", "Asks before OpenCode does something that needs permission.", Allowance: Available |
| `settings-servers.png` | "OpenCode: ready (installed by Agents) · borrows this Mac's sign-in (1 provider)" |
| `server-chat-zen.png` | a server OpenCode chat: the answer, mode `build`, model "OpenCode Zen/Big Pickle", the meter "Not measured" (no "$0") |
| `server-model-menu.png` | the lent run's menu: Anthropic (lent), Groq (the server's own), OpenCode Zen; no OpenAI |
| `signin-sheet.png` | "Login with opencode", the `auth logout` line with the app's own path, and "Servers borrow this Mac's Anthropic key for each run, and keep nothing. OpenAI stays on this Mac: …" |

Fixed from the looks: the sheet named providers by their ids ("anthropic"), now by name; the
Servers footer now says OpenCode borrows this Mac's provider keys.

Seen, not fixed here:
- `server-chat-refused.png`: the refused-key sentence is on the record but the chat does not show
  it, and the row has no line under it. The concise chat hides runtime notes at a turn's end (065's
  open item), so a stopped turn just ends after the prompt.
- Settings ▸ Servers says "Setting up 127.0.0.1 failed: tar …" for Codex's failed install, not
  naming Codex, which reads as the whole server failing (043/046 wording; the devbox has no `xz`).
- A server chat's model menu has no "Sign in, sign out, providers…"; the Mac chat's chooser does.
