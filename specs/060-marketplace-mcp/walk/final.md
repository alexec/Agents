# 060 quickstart record

2026-09-27. Scratch root `/tmp/run-060`, personal home `/tmp/run-060-home`, fixture registry
on `127.0.0.1:8932`. The real daemon and `~/.agents` were not used.

## §2 socket

| # | Result |
|---|---|
| 1 | `catalog/search` `github` / `mcp` returned the fixture order. `known` only on `io.github.github/github-mcp-server`. |
| 2 | Preview of GitHub, remote, personal: `Authorization` is `Bearer ${GITHUB_TOKEN}`, required, destination free. |
| 3 | Add wrote `${GITHUB_TOKEN}` into `mcp.json`, the value into `secrets.env` at mode `0600`, sidecar key `personal/github`. The value was not in `mcp.json`. |
| 4 | Those are the files a session reads. Filling `${NAME}`, and leaving the server out when the name is missing, is `MCPPreviewAndAddTests` and `MCPProjectTests`. No runtime was started. |
| 5 | Add of Context7 to `/tmp/run-060/work` wrote `${CONTEXT7_API_KEY}` only. Approval key `/tmp/run-060/work\|.agents/mcp.json\|context7`. |
| 6 | A hand-written `notes` entry listed first as waiting, `isNew`. Context7 stayed approved. `mcp/approve` with the listed digest approved it. A wrong digest was refused (`staleDigest`, "That server has changed. Open it again."). |
| 7 | Deleting `CONTEXT7_API_KEY` from `secrets.env` made `mcp/list` report it missing. |
| 8 | `mcp/set-secret` set the name again. The list no longer calls it missing. The value is not in the project file. |
| 9 | `mcp/remove` of `github` with `forgetSecret` `GITHUB_TOKEN` was refused while another entry still named it (`secretStillInUse`), and neither the entry nor the secret was removed. After that other entry was taken out, remove forgot the secret and left `CONTEXT7_API_KEY`. Remove of hand-written `notes` was refused (`unmanaged`). |
| 10 | With the fixture answering 503, search returned no rows and `unreachable` for `127.0.0.1`. `mcp.json`, `secrets.env` and the sidecar were not rewritten. |

The error payload is the enum case `{"unreachable":{"host":"127.0.0.1"}}`, which is the host the scratch app was pointed at.

## §3 frames

Looked at on the scratch window after the screen was unlocked. Details are in
[us2](us2/README.md) and [us3](us3/README.md).

| Frame | What the window showed |
|---|---|
| D | **MCP servers** under Skills. `pulled` first, waiting, with **Approve**. `context7` marked **registry** at 4.1.1, with **Replace…** and **Remove…**. `notes` with **NOTES_TOKEN not set** and **Set…**. |
| E | Set sheet names `~/.agents/secrets.env` and does not show a value. Remove offers **Also forget** only when nothing else names the secret, and otherwise says the secret stays. |
| Offline | **Add an MCP server** says "Can't reach 127.0.0.1." when the fixture answers 503. |

The section had been showing "No MCP servers" until the app became active and listed again.
