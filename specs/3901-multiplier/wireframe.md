# Wireframe: the Multiplier hero page (#3904)

Alex approved it in chat (2026-11-07).

**The Mac window only** (Alex, 2026-11-07). Not the web page yet, and never the Remote.

**What it is for:** an engineer is proud of their work. It is a show-off page, a little
marketing: a few big numbers that go up and down as work lands. Keep it simple.

The animated version is `wireframe.html` (open it in a browser and press **Land a PR**). The
figures are made-up examples. #3902 says how they are counted.

---

## 1. The page

The window opens to it, in place of today's "Nothing selected" page
(`App/Sources/ContentView.swift`, `NothingPickedPage`). Nothing else on the window changes.

```
┌─ Agents ─────────────────────┬──────────────────────────────────────────────────────────┐
│ [+ New Session]              │                                                          │
│                              │                     Last 7 days                          │
│ ▾ Agents             (5)     │                                                          │
│   ● Rewrite settings sheet   │                       3.2×                               │◄── the hero number
│   ◐ Check the build          │           the work of 3.2 engineers                      │
│   ◐ Tidy error codes         │                                                          │
│ ▾ Web                (2)     │                                                          │
│   ◐ Parity walk              │      23            128             5                     │◄── three big numbers
│   ○ Fix sidebar badge        │   PRs merged   engineer-hours   agents now               │
│                              │                                                          │
│                              │                                                          │
│                              │            + 0.3×  #1234 merged                          │◄── rises and fades
│                              │                                                          │     when work lands
│                              │                                                          │
│                              │     ⌘N new session · ↑↓ move · ⌘F find                   │◄── today's key hints
└──────────────────────────────┴──────────────────────────────────────────────────────────┘
```

- **The hero number:** the Multiplier, the largest text in the app.
- **Three big numbers under it:** PRs merged, engineer-hours of work, agents working now.
- **Nothing else:** no chart, no list, no links. A person screenshots it and posts it.

---

## 2. How it moves

| When | What moves |
|---|---|
| **A PR merges** | The numbers count up to their new values (1 s). A `+0.3× #1234 merged` line rises under them and fades. |
| **A PR is reverted** | The numbers count down. The line says `−0.2× #1207 reverted`. |
| **An agent starts or stops** | "agents now" counts up or down. |
| **The window opens** | The numbers count up from the last values the window showed. The first time, from 0. |
| **Reduce Motion** | The numbers change with no count and no rising line. |

No movement when nothing changed.

---

## 3. Empty state

```
                              — ×
                No merged work in the last 7 days.
          Your number starts when an agent's first PR merges.
```

---

mac: wireframe only, remote: by design (never on the Remote), web: not yet (Alex, 2026-11-07).
