# 060 US3 walk notes

2026-09-27. Same scratch root as [the quickstart record](../final.md).

Socket, frame E's behaviour:

- `mcp/set-secret` wrote `CONTEXT7_API_KEY` back. The project file still has `${CONTEXT7_API_KEY}`, not the value, and the list stopped calling it missing.
- Remove of a server the app added, with forget, was refused while another entry named `GITHUB_TOKEN` (`secretStillInUse`). The entry and the secret both stayed.
- After that other entry was gone, remove took `github` out and forgot `GITHUB_TOKEN`, and left `CONTEXT7_API_KEY`.
- Remove of hand-written `notes` was refused. The file was left alone.
- Registry down: search returned no rows and `unreachable` for `127.0.0.1`. Nothing on disk changed. The fixture was brought back up afterwards.

The sheets, on that same window:

- **Set…** on `notes` opens "Set NOTES_TOKEN": "notes needs this. The value is saved in your ~/.agents/secrets.env, and it is not shown again." **Save** does not close it while the field is empty.
- **Remove…** on `context7`, while nothing else names its secret, offers **Also forget CONTEXT7_API_KEY** and says "Nothing else names it."
- After a hand-written entry also names that secret, the tick is gone and the sheet says "CONTEXT7_API_KEY stays, because another server still names it."
- `pulled` and `notes` have no **Remove**.

Registry down, from **Settings ▸ MCP servers ▸ Add server…**: the sheet stays on "Add an MCP server", and searching `github` says "Can't reach 127.0.0.1." The daemon logged `mcp: search "github" failed: unreachable(host: "127.0.0.1")`.
