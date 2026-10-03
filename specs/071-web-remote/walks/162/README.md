# #162 walk: a workflow's settings edited from the web page

2026-10-03, on a run-app root `/tmp/run-wf162` with one project and one workflow, *Nightly sweep*
(`agent: new`, `enabled: false`, `labels: [review]`), and Claude's options remembered in its
folder (`agents/options`, then the draft discarded). Never approved or enabled.

`node Web/test/walk/workflowsettings.mjs <WEB_URL> <browser code> <file> <out>` changed, from the
page in headless Chrome, and read back from the file after each:

| Control | Chosen | The file |
| --- | --- | --- |
| Runtime | Codex, then Default (Claude) | `runtime: codex`, then the line taken out |
| Permission mode | Accept edits | `permission-mode: acceptEdits` |
| Model | Opus 5.5 | `model: opus[1m]` |
| Effort | Low | `effort: low` |
| Fast mode | Fast mode on | `options:` / `fast: true` |
| Cooldown | 1 hour | `cooldown: 1h` |
| Labels | typed `nightly,`, removed `review` | `labels: [nightly]` |

Then the file was made unreadable and the model set back to its default: the daemon's
"nightly.md could not be read." showed under the labels and the Model menu stayed on Opus 5.5,
what the file says.

- `web-before.png`, `web-after.png`, `web-refused.png`: the page.
- `window-after.png`: the window's page for the same workflow afterwards (by window id over AX):
  Accept edits, Opus 5.5 Low, `nightly`, Cooldown 1 hour.

A file with a problem (first seeded by mistake with `at: ["22:00"]`) arrives with empty settings,
and a change then wrote those empty settings over the file's. The page now locks its settings
while the file has a problem; the window and the Remote still offer them: #179.
