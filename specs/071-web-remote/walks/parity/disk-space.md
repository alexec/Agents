# Parity: Disk space

A screen of [the parity table](../parity.md), which says what the paths and verdicts mean.

| Feature | Tier | Mac | Remote | Web | Verdict |
|---|---|---|---|---|---|
| Low or almost-full disk (#195, #196; strips removed #3628) | Mac + web | The machine's row in the sidebar is red, and its page says each disk's free space and level (#3626): `A/Hosts/MachinePage.swift` | None: **by design** (tier mac+web, #2798; its strip removed with nothing in its place, #3628) | The same, on the machine's row and page: `W/views/Nav.tsx`, `W/views/MachinePage.tsx`, words held to `Fixtures/web/disk/lines.json` | **same** |
| Low and Critical settings | Mac + web | Folder Settings ▸ Disk Space | None: **by design** (tier mac+web, #2798) | Folder Settings ▸ Disk Space (#3280): `W/views/ProjectSettings.tsx` | **same** (#3280) |
