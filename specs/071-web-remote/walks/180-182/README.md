# Walk: #182 order, #181 folds, #180 pins (2026-10-03)

On a run-app scratch root (`/tmp/run-sb182`) at b050692d: one project, three real Claude
sessions working a tick loop (labelled a1, a2, a3 in the order they started) and one more to pin.
The window was driven by pid over AX (no pointer, no keys); the page in headless Chrome.

- **#182:** `182-window-clicks-a1-a2-a3.png`: after selecting a1, then a2, then a3, Working reads
  a3, a2, a1 each time, newest started first. Before the fix, a click fetched the agent whole with
  a fresher `lastActivityAt` and the group re-sorted around it.
- **#181:** `181-window-folded.png`: Pinned and Working folded, counts and unread kept;
  `181-window-after-relaunch.png`: the same after quitting and reopening the window, read from
  `sidebar.folded.walk:run-sb182`. The page: `web-working-folded-after-reload.png`.
- **#180:** `180-window-pinned-working.png` → `180-window-pinned-needs-you.png`: the pinned
  session stays on top under Pinned as it goes from working to needs you, with its state mark,
  unread and the project's dot; `180-window-unpinned.png`: unpinned, it is back under Needs you,
  and the empty `.agents/pins.json` is gone. The page: `web-pinned-and-order.png`.
