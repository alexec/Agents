# 043 walk — 2026-09-25

Scratch window on `/tmp/run-043` (kept), real ssh, the bare box `agents-bare` (rebuilt twice),
a **made-up** Claude token (`sk-ant-oat01-WALKMADEUP…0043`). Screenshots in `look/`.

| # | What | Seen |
|---|---|---|
| 1 | Settings ▸ Servers, empty | `look/1-settings-empty.png`: "Signing in on servers", field, where to get one, what it's for |
| 2 | Paste + Save | real call to Anthropic: **Refused**, "OAuth access token is invalid.", masked `sk-ant-oat…0043`, Check again / Replace… / Remove (`2-settings-refused.png`) |
| 3 | Add a server `agents@127.0.0.1:2223`, bare | fingerprint matched the box; checklist with **Install Claude** (`3-add-installing.png`); **ready in 9 s**; the server row says "Claude: ready (installed by Agents) · signs in with the token in Settings" (`4-add-ready.png`) |
| 4 | Server project + a Claude agent, typed into the window's own prompt box | lent on demand through the window, agent started; "Failed to authenticate. API Error: 401 …" then **"Claude refused the token in Settings. Replace it in Settings ▸ Servers."** (`5-chat-refused.png`). It also said "The runtime crashed" — fixed at `d9fd07f`: now "Its sign-in was refused" |
| 5 | Relaunch on a new build | server daemon updated, Claude ready, connected in ~1 s |
| 6 | `bare.sh rebuild` under the window | offline → **"127.0.0.1 has a new identity"**, Before/Now fingerprints right (`6-rebuilt-sheet.png`) |
| 7 | This server was rebuilt | set up again, Claude installed, **connected in 7 s**; old project **"Gone from 127.0.0.1" with Remove** (`7-after-rebuild.png`) |
| 8 | `scripts/leak-check.sh` | root, preferences, crash reports, unified log, the box: **clean** |

Rough edges seen:
- After the rebuild, the sidebar's whole-list empty state ("No projects yet…") shows under the
  gone row, and the page behind is a blank "Project".
- On the rebuilt sheet neither button is drawn as the default; Cancel is the default by keyboard.
- The app wrote the bare box's key into `~/.ssh/known_hosts` as `[127.0.0.1]:2223` (037's
  behaviour, by design); the rebuild replaced it with `ssh-keygen -R`.

## With Alex's real token (pasted by him into the scratch Settings; the Keychain handoff item never appeared)

| # | What | Seen |
|---|---|---|
| 9 | Save | **Works** (`8-settings-works.png`): a real subscription token answers 200 on `/v1/models` with Bearer + `oauth-2025-04-20` (T010) |
| 10 | `bare.sh rebuild`, This server was rebuilt | set up again with Claude in **12 s** from the rebuild |
| 11 | Project, prompt typed in the window, Send | `hello.txt` on the box **4 s** after Send; Claude ran `uname -a`, answered, and ended **Complete** through `finish_turn` (`10-real-turn.png`). The box has no sign-in of its own: the lent token is what answered (SC-001, well under 5 minutes) |
| 12 | Leak search after real use | no `sk-ant-oat01-…` anywhere in the scratch root, preferences, crash reports, the last hour of the unified log, or the box's `$HOME` and `/tmp`; no `~/.claude/.credentials.json` on the box (SC-003) |
| 13 | Env over a server's own login (T008) | on the devbox, signed in with `claude login`, a made-up `CLAUDE_CODE_OAUTH_TOKEN` was refused (401): the lent token wins (D1) |

Found along the way:
- A gone project's page still offers **New session**; sending from it fails with "…is not there any
  more" in an alert (`9-gone-page-send.png`). A gone project should open no page.
- While replacing a token, the row says "No token" though one is saved.
- AX typing into sheets is unreliable from outside (keystrokes went to the chat's prompt box), so
  own-sign-in-only on the devbox was not walked in the window; it is covered by `LendTests`.

Still open: own-sign-in-only walked in the window, the token-ask card (§ 3) seen on screen,
Remove + purge (T054), the toolset update seen in the window (T052), and Alex's look approval (T018).
