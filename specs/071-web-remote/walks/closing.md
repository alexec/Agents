# Closing walk (quickstart §8)

**Date:** 2026-10-01

**Commit:** the T071 commit on `agents/write-spec-first-version`.

**How it was run:**
- On the scratch root `/tmp/run-closing`, with a scratch window.
- Headless Chrome drove the page at 1440 × 900, using `Web/test/walk/closing.mjs`.
- The work project was a git repository, with one approved workflow, "Write a greeting".
- One real Claude agent ran the whole list. The scratch window was put on the session after each step, and captured.
- CDP listened throughout: to every request, every console call, and the page's WebSocket frames. The control plane's log was read at the end.

There were three runs. The first two found the two bugs below. The notes and screenshots are from the third, after both fixes.

## SC-002: every first-cut action, from the browser

| Action | In the browser | On the host and in the window |
|---|---|---|
| Pair | Pasted a device code. The footer reads **Chrome on this Mac · Device**. | — |
| Start in a worktree | **New session**, **Works in: A new worktree** | Worktree `test-driving-from-browser-3`, branch `agents/test-driving-from-browser-3` (`closing-window-1-started.png`) |
| Send with an attachment | A red PNG attached to the first prompt | The first prompt's blocks are `text`, `image`. The agent said the picture is red. |
| Answer a question | Chose **Howdy**, then **Submit**. While it was on its way, the button said **telling your Mac** (#86). | `greeting.txt` holds `Howdy` |
| Answer a permission request | Three allowed in the page: `echo Howdy > greeting.txt`, writing `plan.md`, and its second edit | The turn finished: done (`closing-window-2-answered.png`) |
| A live page | `show_file` opened it on the **Page** tab. It followed the writes, and drew 3 passages. Typing " Typed in the browser." on the last passage reached `plan.md`. | `plan.md` ends "…Typed in the browser." |
| The changes view | `plan.md · Untracked +5 −0`, `greeting.txt · Untracked +1 −0`. `greeting.txt`'s diff drawn. | — |
| Open a file | `greeting.txt` reads `Howdy` | (`closing-window-3-done.png`) |
| Send now | A second prompt typed while the turn waited on a permission, then **↑ Send now** | The queue emptied on the record |
| Change model | **Default (recommended)** → **Opus 5.5** | `default` → `opus[1m]`. The window's menu reads **Opus 5.5** (`closing-window-4-model.png`). |
| Park | **More ▸ Park** while the turn ran, then **Unpark** | `parking: whenTurnEnds`, then none |
| Stop | **More ▸ Stop** | `stopped`, `cancelled` (`closing-window-5-stopped.png`) |
| Archive | **More ▸ Archive** | `archived` (`closing-window-6-archived.png`) |
| Run a workflow | **Run Now** on "Write a greeting". Its permission was answered in the page. | A new agent, started by `greeting`. It finished: "Created hello.txt in the project folder containing the word "hello"." (`closing-window-7-workflow.png`) |

## §6: away and back

- The control plane was stopped. The banner **Can't reach the control plane at localhost:… Trying again.** came within 0.1 s.
- It was started again after 15 s. The banner went 1.4 s later, with no reload.

## SC-008: nothing from elsewhere, no secret anywhere

- **Requests:** the page made 4, all to its own `localhost` origin (`closing/requests.txt`). No URL held the code.
- **Secrets:** each of these was checked in the console and in the control plane's log:
  - the pairing code;
  - a marker word the agent was asked to say;
  - a prompt's text ("banana");
  - the words typed on the live page.

  None was in either.
- **Console:** 11 lines, every one an `agents: …` event name.
- **Page errors:** none.

## Found and fixed during the walk

**A question answered too quickly was sent empty.**
- **Symptom:** the first run chose Howdy and Submit, and the host recorded the form as answered. But Claude was told "The user did not answer the questions."
- **Cause:** the question card filled its form's defaults in an effect, after the first paint. Headless Chrome can delay that by a frame or more. A choice made before then was wiped back to the defaults, so Submit sent `{}`.
- **Fix:** each card is its own request (keyed by its id), so its defaults are now the form's starting value, and there is no effect.
- **Checked:** the same question answered on the host's own socket, and from the page at a normal pace, reached Claude. That was what pointed at the timing.

**A file a command wrote showed no diff.**
- **Symptom:** `greeting.txt`, written by `echo`, has no reported edits, so the changes view said "No lines to show for this file."
- **Fix:** the window shows such a file whole, where git can say what changed (`ChangeFileView`), and the page now does the same (`wantsWhole`, tested in `diff.test.mjs`).

## Found, not fixed here

- **One file listed twice in the changes view** (host side). In the second run, `plan.md` was listed twice: as `Added +3` from the agent's own edit, at `/private/tmp/…`, and as `Untracked +5` from git, at `/tmp/…`. It is the same file through macOS's `/tmp` symlink. The host lists both, so the window would too. It appears only when the agent's path and the project's differ by a symlink, as on scratch roots under `/tmp`. The third run listed it once.
- **The prompt's menus were cut off** when the files pane was open at 1440: **Fast mode** showed as "Fa" (`closing-2-page.png`). They scrolled sideways with no scrollbar. Fixed after the walk: they wrap now.

## Safari: §2, §4 and §6

**How it was run:**
- Safari 27.0, through `safaridriver` (WebDriver), in its own automation window, apart from Alex's Safari. Both the screen and Safari were leased.
- On the scratch root `/tmp/run-safari`, with no window, using `Web/test/walk/safari.mjs`.
- The code was made with `agents-control code --client device --browser`.

**Getting it to run:**
1. Remote automation was off at first, so WebDriver refused: "You must enable 'Allow remote automation'". Alex turned it on.
2. Sessions then timed out connecting to Safari. A stale `safaridriver` of mine was holding port 4723.
3. Once Alex had quit Safari, a fresh `safaridriver` on 4723 got a session at once.

| Section | Result |
|---|---|
| §2 Pair | The page is a secure context at `http://localhost`. Pasting the code paired it: the footer reads **Safari on this Mac · Device**. After a reload, it connected again with the stored key, and nothing was pasted. |
| §4 Read and answer | A real Claude turn, started on the host's socket. The question card showed in Safari, and **Howdy** then **Submit** were chosen there. The permission card (`echo Howdy > safari.txt`) was allowed there. The turn finished: "Asked which greeting to use; you picked Howdy, and it was written to safari.txt." `safari.txt` holds `Howdy`. The chat showed the answer, the reply and the outcome. |
| §6 Away and back | The control plane was stopped. The banner came within 0.1 s. It was started again after 15 s. The banner went 2.1 s later, with no reload. |

Firefox isn't installed, so it isn't walked.

## Screenshots (`walks/closing/`)

- `closing-1-started.png` to `closing-6-away.png`: the page at each step.
- `closing-window-1-started.png` to `closing-window-7-workflow.png`: the scratch window on the same session after each step.
- `safari-1-paired.png` to `safari-5-back.png`, with `safari-notes.txt`: the Safari walk.
