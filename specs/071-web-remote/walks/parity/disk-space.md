# Parity: Disk space

A screen of [the parity table](../parity.md), which says what the paths and verdicts mean.

| Feature | Tier | Role | Mac | Remote | Web | Verdict |
|---|---|---|---|---|---|---|
| Low or almost-full disk (#195, #196; strips removed #3628) | Mac + web | Engineer (set-up) | The machine's row in the sidebar is red, and its page says each disk's free space and level (#3626): `A/Hosts/MachinePage.swift` | None: **by design** (tier mac+web, #2798; its strip removed with nothing in its place, #3628) | The same, on the machine's row and page: `W/views/Nav.tsx`, `W/views/MachinePage.tsx`, words held to `Fixtures/web/disk/lines.json` | **same** |
| Low and Critical settings | Mac + web | Engineer (set-up) | Folder Settings ▸ Disk Space | None: **by design** (tier mac+web, #2798) | Folder Settings ▸ Disk Space (#3280): `W/views/ProjectSettings.tsx` | **same** (#3280) |
| A notice when a disk becomes almost full (#3682) | Mac + web | Engineer (set-up) | A banner from this Mac's host, once each time a volume becomes critical, taken back when it climbs back; a click opens this Mac's page: `A/Notifications/MacNotifier.swift` | The banner reaches it as any notice does, and a tap opens the app: **by design** (no machine page, tier mac+web, #2798) | The page's own notification opens that machine's page; a Web Push opens the machines: `W/pageNotices.ts`, `W/pushItem.ts`, `W/sw.ts` | **same** |
