# US3 walk: send, start and steer

**Date:** 2026-10-01

**Commit:** the T059 commit on `agents/write-spec-first-version`.

**How it was run:**
- On the scratch root `/tmp/run-webus3`, with the scratch window opened behind other windows.
- Headless Chrome 154 drove the web remote, using `Web/test/walk/us3.mjs`.
- A real Claude agent did the work.
- The walk script checked the host's record after every step, as the window would see it.

**The scratch window:**
- After the start, the walk reopened the window on the new session with the Debug build's `-open-agent`.
- It then captured the window by its window id (`shot.sh`) at each step. That needs no Accessibility permission and doesn't bring the window to the front.

**Warm-up:** before the walk, a one-line Claude turn ran so that Claude's account was known. Until a runtime has run once, its capabilities are empty. The browser then refuses a picture, as the Remote does.

There were three runs:
1. **First run.** Claude Code wouldn't run a foreground `sleep`, so the turn ended before the steps that needed it running.
2. **Second run.** It passed, but showed a wording problem when a question was withdrawn, and a race on the host's side (both below).
3. **Third run.** It ran after the wording fix. The notes and screenshots here are from this run.

## Steps (quickstart §5)

| # | Step | In the browser | On the host's record, and in the window |
|---|------|----------------|-----------------------------------------|
| 1 | Start an agent in a new worktree with a picture attached | Pressed ✎. The project's empty pane became the form. *Works in: A new worktree*; the runtime was Claude; the menus were Mode, Model, Effort and Fast mode. The picture (a red PNG) was picked, shown as 🖼 071-red-square.png, then sent. | Started in worktree `say-one-sentence-what-2` on branch `agents/say-one-sentence-what-2`. The first prompt's blocks were `text` and `image`, and Claude answered "The picture is solid red." The window showed the picture and the worktree. |
| 2 | Queue a second prompt, then **Send now** | A prompt typed while the turn waited on its permission was shown as *Waiting its turn*, with **↑ Send now** (Claude can steer). | 1 queued, then the queue emptied after Send now. The window showed the prompt in the chat. |
| 3 | Change the model | The Model menu offered *Default (recommended), Opus 5.5, Fable 5.1, Sonnet 5, Haiku 4.5*. **Opus 5.5** was chosen. | `model`: `default` → `opus[1m]`. The window's pill read *Opus 5.5*. |
| 4 | Park, unpark, stop and archive | From the ··· menu: **Park** while it ran, **Unpark**, **Stop**, **Archive**, then **Bring Back**. | Park while running gave `{"whenTurnEnds": …}` (it parks when the turn ends). After Unpark there was no parking. Stop gave `stopped, cancelled`. Archive gave `archived`, and Bring Back returned it to `stopped`. |
| 5 | Add and remove a label | Typed `walked,` into the label field, then pressed × on the chip. | `walked` was added with owner `person`, then was gone. The window showed the chip beside the worktree. |

There were no problems shown on the page, and no page errors.

All of steps 2–4 happened while the turn waited on its first Bash permission. A turn waiting on a question still holds its runtime, so it can be queued into, steered, parked and stopped.

## Screenshots (`walks/us3/`)

**From the browser:**
- `us3-1-new.png`: the form, ready to send.
- `us3-2-queued.png`: the queued prompt with Send now.
- `us3-3-model.png`: after the model change.
- `us3-4-stopped.png`: after Stop.
- `us3-5-archived.png`: archived.
- `us3-6-label.png`: the label added.

**From the scratch window:**
- `us3-window-1-started.png`
- `us3-window-2-queued.png`
- `us3-window-3-model.png`
- `us3-window-4-stopped.png`
- `us3-window-6-label.png`

## Found during the walk

1. **A withdrawn question said it was answered elsewhere (fixed).**
   - **The problem:** a permission withdrawn because the session stopped read "Answered on another device."
   - **The fix:** the host writes *Nobody answered this question before the agent ended.* in the conversation, then withdraws the question. The card now looks for that line and says **"The session stopped before this was answered."** The third run shows it.
2. **A permission asked just after Stop stays on screen (host-side, not fixed here).**
   - **What happened:** in the second run, Claude asked a second permission (`echo two > two.txt`) 0.03 s after the stop was recorded. The host held it, and both the window and the browser showed a live card on a stopped session (`us3-window-6-label.png` in that run).
   - **What the host did:** it later took the card off its pending list with no "Nobody answered" line on the record.
   - **Where it belongs:** this is a race in the daemon's permission handler (DaemonCore), which doesn't check whether the agent has been stopped. It needs fixing on main, apart from 071.

## Not covered here

- **Grant refusal.** A refusal by grant (T058) is covered by `errors.test.mjs`. A device grant reaches every method the page offers, so the walk never met one.
- **Dropping and pasting.** Dropping or pasting a file wasn't walked, only picking it. All three go through the same `attach()`.
- **Firefox and Safari.** These are left to T071.
