# 060 · Quickstart: proving it works

Every step runs on a scratch root with a scratch personal home, so the real `~/.agents`, the
real daemon and the person's own servers are never touched (FR-010). Contracts:
[contracts/](contracts/). Shapes: [data-model.md](data-model.md).

## 0 · Fixture registry

`specs/060-marketplace-mcp/walk/fixture-server.py` stands in for
`registry.modelcontextprotocol.io`:

- `GET /v0/servers?search=&version=latest` → trimmed real responses (GitHub, a Smithery remote,
  an npm package with secrets, a docker-only server, an unavailable-on-Mac case).
- `GET /v0/servers/{name}/versions/latest` → full entries for those fixtures.
- `POST /_down` → every route 503, for offline.

```sh
python3 specs/060-marketplace-mcp/walk/fixture-server.py --port 8932 &
```

## 1 · Launch a scratch app pointed at it

```sh
S=.claude/skills/run-app/scripts
HOME2=/tmp/run-060-home && mkdir -p $HOME2
eval "$($S/launch.sh --slug 060 \
  --env AGENTS_PERSONAL_HOME=$HOME2 \
  --env AGENTS_TEST_MCP_REGISTRY_URL=http://127.0.0.1:8932)"
mkdir -p $ROOT/work && git -C $ROOT/work init -q
$S/rpc.py $ROOT call projects/add "{\"folder\":\"file://$ROOT/work\"}"
```

## 2 · Over the socket (no screen needed)

| # | Call | Expect |
|---|---|---|
| 1 | `catalog/search {"query":"github","kind":"mcp"}` | Fixture rows in fixture order; `known` true only for known publishers |
| 2 | `mcp/preview` of GitHub, `run:"remote"`, personal | `entry.headers.Authorization` is `Bearer ${GITHUB_TOKEN}`; `variables` lists it required; `destinationState.free` |
| 3 | `mcp/add` with the token | `~/.agents/mcp.json` has `${GITHUB_TOKEN}` only; `secrets.env` is 0600 and holds the value; sidecar names `github` |
| 4 | Start a session (or inspect `sessionServers` via test) | Server present with the token filled in |
| 5 | `mcp/add` to the project destination | `<work>/.agents/mcp.json` written; approval stored; next project session has it |
| 6 | Write a second project server by hand into the file | `mcp/list` shows it `waiting`; sessions omit it until `mcp/approve` with the listed digest |
| 7 | Remove the secret from `secrets.env` | List shows missing; sessions omit that server |
| 8 | `mcp/set-secret` | Name set again; sessions include it |
| 9 | `mcp/remove` with `forgetSecret` | Entry gone; secret gone only if nothing else names it |
| 10 | `POST /_down`, then search | `error.kind = unreachable`; nothing on disk changed |

## 3 · Walk the frames on a scratch app

Use `run-app` against the same root. Check each frame against [look/](look/README.md):

| Frame | Check |
|---|---|
| A | Add server…; registry chip; set/missing; Remove only on managed |
| B | Kind switch; publisher; known; remote host chip; grey unavailable |
| C | Exact command/URL; `${NAME}`; Add disabled until secrets filled; reach dots |
| D | Section after Skills; waiting row; Set…; copy about committed file / personal secrets |
| E | Set sheet; Remove with forget-secret tick only when unused |

## 4 · Done when

- `swift test --filter MCP` (or Catalog) is green on the branch.
- Socket table above passes on a scratch root.
- Frames A–E match the approved look on a scratch app.
- Docs in the spec's Docs list are written.
