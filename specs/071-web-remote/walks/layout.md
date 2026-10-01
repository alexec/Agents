# Walk: the layout, before depth (T039, quickstart §3)

2026-10-01, on scratch root `/tmp/run-weblayout`, run with the demo runtime
(`AGENTS_TEST_RUNTIME=echo`). It had three projects and twelve real sessions:
- `web-remote` 6, `control-plane` 4, `docs-site` 2;
- one session with a 94-entry chat;
- one session parked.

The browser was headless Chrome 154, paired as a device, driven by `Web/test/walk/layout.mjs`.
Each shot sits beside the frame it answers.

| Width | Frame | Shot | What shows |
|---|---|---|---|
| 1440 | A | [layout-1440.png](layout/layout-1440.png) | Projects under This Mac, the project's sessions, and the chat with the prompt at its foot. Who this browser is, and Forget This Browser…, at the foot of the projects. |
| 1600, files open | B | [layout-1600-files.png](layout/layout-1600-files.png) | The files pane as a fourth column, with its close button. |
| 1300, files open | B, below 1440 | [layout-1300-files-over-chat.png](layout/layout-1300-files-over-chat.png) | The pane over the chat. |
| 1000 | C | [layout-1000.png](layout/layout-1000.png), [layout-1000-menu.png](layout/layout-1000-menu.png) | The projects folded into a menu atop the sessions; the menu open under host headings, with the Needs you dots. |
| 390 | D | [chat](layout/layout-390-chat.png), [sessions](layout/layout-390-sessions.png), [projects](layout/layout-390-projects.png) | One column at a time, with back controls. The browser's own Back steps chat → sessions → projects. |
| 1440, control plane stopped | F, left | [layout-f-down.png](layout/layout-f-down.png) | **Can't reach the control plane**, the columns greyed out, the chat kept (32 lines), and Try Now. It reconnected and caught up by itself, with no reload. |
| 1440, forgotten | F, right | [layout-f-forgotten.png](layout/layout-f-forgotten.png) | The pairing screen, with "This browser was forgotten. Pair it again to carry on." |

At every width, the walk checks that:
- no column scrolls sideways, and the page doesn't;
- every visible column starts at the top, so none has wrapped;
- the prompt is on screen.

All held. There were no page errors, and no request went off the page's origin.

**Found and fixed by the walk:**
1. **The files pane wrapped the chat onto a row of its own below 1440.** The chat and the pane
   now share one grid cell, and the walk checks no column wraps.
2. **The control plane, stopped, was never noticed.** A hung socket never answers Chrome's
   close handshake either. Now a missed heartbeat counts the link down at once, so the banner
   shows within the heartbeat (5 s plus 3 s).
3. **Back after opening and closing Files reopened Files.** Opening the pane now replaces the
   history entry rather than adding one.
4. **At 390, the empty chat showed beside the projects.** Its own `display` rule overrode the
   narrow layout.
5. **At 1000, the project menu's button wrapped**, and the search field crowded it. The search
   field now waits for the wide layout, as frame C has it.
6. **The chat opened at its top.** It opens at the end and follows it unless the person has
   scrolled up, including when the window is resized.

**Not yet, by plan:**
- the sessions' groups, status words and workflows (Phase 6, T049);
- concise turns, tool calls and cards (T050–T051);
- sending (Phase 7);
- the tab title's count (T052);
- the files pane's contents (Phase 9).

The page's identity line says "Chrome on this Mac", not the record's own name. A device can't
read `clients/list`, so the page names its own browser.
