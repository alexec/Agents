# US4 walk: files, changes and live documents

**Date:** 2026-10-01

**Commit:** the T066 commit on `agents/write-spec-first-version`.

**How it was run:**
- On the scratch root `/tmp/run-webus4`, with `--no-window`.
- Headless Chrome 154 drove the page, at 1600 × 1000 so the files pane sat in its own column, using `Web/test/walk/us4.mjs`.
- The work project was a git repository holding a `README.md`, and two hostile files:
  - a `page.html` whose `<script>` logs and calls `fetch`, with an `<img onerror>`;
  - a `picture.svg` with a `<script>` and an external `<image>`.

**The turn:**
- A real Claude turn ran on the host's own socket, with each permission allowed there.
- It edited `README.md` and created `notes.txt`.
- It wrote `plan.md`, called `show_file` on it, then added three paragraphs, one edit each.

There were two runs. The first found that an edit's diff was drawn as every line removed and every line added. The notes and screenshots here are from the second run, after the fix.

## Scenarios

| # | Scenario | Result |
|---|----------|--------|
| 3 | `show_file` on a Markdown page opens it beside the chat and follows each write | The files pane opened by itself on the **Page** tab beside the open chat. The page went through **4 versions** in 22 s as the agent wrote. At the end it drew 5 passages, matching the 5 on disk. |
| 4 | Typing on the live page reaches the file | I clicked the last passage and typed " Typed in the browser.". It reached `plan.md` on the host through `artifact/write`, and the file ends "…noting any follow-up work. Typed in the browser." The page still had its 5 passages. |
| 2 | The changes view lists them with diffs | `README.md · Modified +2 −0`, `notes.txt · Untracked +2 −0` and `plan.md · Untracked +9 −0`. README's diff showed `+` (blank) and `+Edited by the agent.`, with the rest as context. |
| 1 | The files pane lists the agent's files and opens one | **Files** listed the session's folder, and a file opened from it in place. |
| 5 | HTML shows as source, SVG as a picture; neither runs anything | `page.html` showed its source under "HTML is shown as its source here, so nothing in it runs." `picture.svg` was drawn as an `<img>` from a `blob:` URL, 120 × 80. While both were open, CDP recorded **no console calls** and **no requests off the page's origin**. That includes `example.com`, which both files try to reach. |

There were no page errors.

## Found and fixed during the walk

**An edit's diff was every line out and every line in.**
- **Cause:** with no git hunks, the host sends the agent's own edits. Claude's whole-file write gives the old text and the new text in full, and the browser drew the old lines removed and the new lines added.
- **Fix:** `model/diff.ts` now diffs them line by line, as the window's `LineDiff.rows` does, so README's diff shows only the line added.
- **Look:** diffs are drawn as the window draws them: sign, weight and a neutral wash, never red and green.

## What isn't the window's yet

- **Page following:** the page marks and goes to the first passage that changed. The window does more: a caret with the agent's name types each change in, and it marks individual changed lines (`PassageChange`).
- **Word marks:** the changes view has no per-word marks (`WordDiff`).
- **Whole-file view:** there's no switch to see the whole file.

## Screenshots (`walks/us4/`)

- `us4-1-page.png`: the page beside the chat after the turn.
- `us4-2-typing.png`: a passage being edited.
- `us4-3-changes.png`: the changes, with README's diff.
- `us4-4-html.png`: `page.html` as source.
- `us4-5-svg.png`: `picture.svg` as a picture. The small mark at its corner is the SVG's external `<image>`, refused.
