---
name: vendor-scripts-touch-the-real-home
description: 048's vendor-script installs (Grok, Cursor, Copilot) write into the real $HOME even from a scratch root; walks must set AGENTS_TEST_INSTALL_SCRIPT; ui.swift press hits the LAST match.
metadata:
  type: feedback
---

On 2026-09-25, walking 048 on /tmp/run-inst, `ui.swift press <pid> "Install"` pressed Cursor's
button (the LAST match, not the first its header claimed) and ran cursor.com/install for real. It
upgraded Alex's Cursor CLI 2026.09.10 → 2026.09.26 and relinked `~/.local/bin/agent` and
`~/.local/bin/cursor-agent`. I relinked both back to 2026.09.10-fd3934a; the new version's folder
is still in ~/.local/share/cursor-agent/versions.

**Why:** a scratch root isolates the daemon and the Claude toolset (`<root>/tools`), but a
vendor's `curl | bash` writes to the person's home whatever the root is.

**How to apply:** launch any 048 walk with `--env AGENTS_TEST_INSTALL_SCRIPT=<url>` (debug builds
replace every vendor script with it), and press by a unique label: the Install buttons carry help
"Install <Name> on this Mac". Menus count too: `press "Settings…"` hit "Services Settings…" and
opened System Settings (quit again at once), and `press "Agents"` hit "Agents Help". Run `find`
first and pick text that matches exactly one element. Related: [[drive-a-scratch-window-by-pid-with-ax]].


2026-09-26: `ui.swift press <pid> "Settings…"` hit "Services Settings…" and opened System Settings on Alex's screen; "Restart" hit an unrelated menu item. For anything whose title is a substring of another, press by exact title only (a small AX script that refuses unless exactly one element's title/description equals the words).
