# US2 walk: read and answer in three columns

**Date:** 2026-10-01

**Commit:** the T053 commit on `agents/write-spec-first-version`.

**How it was run:**
- Scratch root `/tmp/run-webus2`, launched with `launch.sh --no-window`, so nothing opened on the Mac's screen.
- Headless Chrome 154 drove the web remote, using `Web/test/walk/us2.mjs`.
- One real Claude turn per run.
- There were two runs. The first found a list bug, and the second ran after the fix. The notes and screenshots below are from the second run.

## Who stood in for the Mac window

The scratch window was not opened. Its stand-in was `operator.mjs`, an operator client of kind `mac` that connects over the control plane's TLS address.
- It speaks the window's own wire.
- It started the turn, as the window's prompt would.
- It answered the last permission, so that one was answered "elsewhere" while the browser showed it.

The browser answered the question and the first permission.

## The turn

The prompt asked Claude to do four things:
1. Ask which greeting to write, using its question tool.
2. Write the chosen greeting to `greeting.txt` with Bash.
3. Write the date to `when.txt` with Bash.
4. Say what it did.

Each Bash call needs permission in the default mode.

## Scenarios

| # | Scenario | Result |
|---|----------|--------|
| 1 | Hosts' projects under their host heading | The **This Mac** heading with **work**. Once the question arrived, the project row said *Needs you*, with the dot. |
| 2 | Sessions in the window's groups, with status, labels and last activity | Sessions were grouped in the window's order: *Working 1* then *Done 1* while the turn ran, and *Done 2* after it ended. Each row had its status mark, title, report line and "now"/"1m". *Archived sessions* was folded, and *Workflows 0* read "Ask an agent to write one." |
| 3 | Updates within half a second of the window (SC-003) | The median lag was **1 ms** and the worst **13 ms**, over 9 updates (reply chunks and cards). |
| 4 | Answered in the browser, the agent carries on, others see it answered | The question was answered with *Howdy*, then **Submit**. The first permission was answered with *Yes*. The turn carried on, and the host's record shows the form answer and both permissions. `greeting.txt` holds `Howdy`. |
| 5 | Answered in the window first while the browser shows it | The card said **"Answered on another device."**, its buttons went inert (a click did nothing), and it left after 4 s. |
| 6 | A finished turn at Outcome, Steps and Details (069) | **Outcome** showed the ask, *9 steps*, the answer bubble, the reply and the report, in the window's order. **Steps** showed every call and the asks and answers under the rule. **Details** opened every call to its argument and return. |

### Other things checked

- The tab's title was **(1) Agents** while the question waited.
- At the end the row said **Complete**, with the check mark. While the question waited, the mark was the tinted "!", which is the page's only colour.
- There were no page errors and no CSP complaints.

## Screenshots (`walks/us2/`)

- `us2-1-working.png`: the session under *Working*, with its spinner.
- `us2-2-question.png`: the question card. Claude's question tool sends a form with choices and an optional "Other" box on one page, so it is answered with Submit.
- `us2-3-permission.png`: the first permission card.
- `us2-4-answered-elsewhere.png`: the second permission card, answered by the operator client.
- `us2-5-outcome.png`, `us2-6-steps.png`, `us2-7-details.png`: the finished turn at each level.

## Found and fixed during the walk

**A numbered list began at 0.**
- **Cause:** markdown-it gives no `start` attribute to a list that starts at 1, and `Number(null)` is 0.
- **Fix:** `render/markdown.ts` reads a missing attribute as 1.
- **Test:** `render.test.mjs` now covers it.

## How the lag was measured, and what it does not cover

- **The browser side.** A MutationObserver in the page recorded the chat's text and the number of cards at every change.
- **The operator side.** The operator client recorded when it heard each reply chunk (`agent/entry`) and each new card (`agent/permission`, `agent/elicitation`).
- **The lag** is the time from the operator hearing a thing to the page first showing it. Both clocks are this Mac's wall clock.
- **Negative values.** A value of −2 ms means the browser drew it before the operator client heard it. The control plane sends to both at once.

This measures the browser against the window's wire, not against the window's own drawing. SwiftUI's time to draw is not part of the number.

## Not covered here

- **The scratch window itself.** It was not opened, so the window side of scenario 5 is the operator client.
- **Firefox and Safari.** These are left to T071.
- **Front trimming.** The front of a long, followed page is not trimmed yet (T047 note). A chat open for hours keeps every entry it heard.
- **Pool switches.** A pool switch line uses the runtime's id, not its display name.
