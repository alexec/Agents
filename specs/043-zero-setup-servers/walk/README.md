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

Not yet seen (needs Alex's real token, handed over through the Keychain item
`agents-043-walk`): Settings saying **Works**, a turn that answers on the bare box (SC-001), the
token-ask card (§ 3, only with no token in Settings), own-sign-in-only on the devbox, and the
leak search after real use (SC-003).
