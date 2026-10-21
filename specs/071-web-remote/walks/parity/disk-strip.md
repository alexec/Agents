# Parity: Disk strip

A screen of [the parity table](../parity.md), which says what the paths and verdicts mean.

| Feature | Mac | Remote | Web | Verdict |
|---|---|---|---|---|
| The strip while a volume is low or critical (#195, #196) | Under the offline strip over a chat, a project's page and a pinned page: `A/Sidebar/DiskStrip.swift` | Under the offline strip over a chat and the start sheet: `R/Chat/HostDiskStrip.swift` | Under the offline strip over a chat and a new session: `W/views/DiskStrip.tsx`, words held to `Fixtures/web/disk/lines.json` | **same** (words) |
| A server's disk | At that host's screens only, not named (#1329): `A/Sidebar/DiskStrip.swift`; `A/AppModel.swift` | At that host's screens only, not named: `R/Chat/HostDiskStrip.swift`; `R/RemoteModel.swift` | At that host's screens only, not named: `W/views/DiskStrip.tsx` | **same** |
| Low and Critical settings | Project Settings | None | None | **by design** |
