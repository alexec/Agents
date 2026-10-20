# Contract: the command provider (`workspace-commands`)

`workspace-commands` is a static Go MCP server (`Go/cmd/workspace-commands`,
`Go/internal/workspacecommands`; Swift in `Packages/MCPServers` until #1364). It follows the [provider contract](provider-contract.md) and speaks stdio. Its
whole configuration is the JSON in `WORKSPACE_COMMANDS_CONFIG`. Its secrets are the other
environment variables the control plane passes it, which its commands can use as `$NAME`.

```sh
WORKSPACE_COMMANDS_CONFIG='{"preset":"docker","containers":["agents-devbox"],"ssh":"alex@127.0.0.1 -p 2222"}' workspace-commands
```

## Workspaces, written out

```json
{
  "workspaces": [
    {
      "id": "devstack-1",
      "name": "devstack",
      "start": "cws start devstack-1",
      "stop": "cws stop devstack-1",
      "status": "cws status devstack-1",
      "ssh": "devstack-1.cws",
      "tunnel": false
    }
  ]
}
```

- `id` defaults to `name`.
- `${…}` with no value of its own (`${TOKEN}`) is left for the shell, so a secret in the
  environment can be used either way.
- `status` is optional. Without it, the state is the last start's or stop's result while the
  server runs, and `unknown` before that.

### Many workspaces from one entry (FR-070)

```json
{
  "list": "doctl compute droplet list --tag-name agents --format ID,Name,Status,PublicIPv4 --no-header",
  "columns": ["id", "name", "state", "ip"],
  "start": "doctl compute droplet-action power-on ${id} --wait",
  "stop": "doctl compute droplet-action power-off ${id} --wait",
  "ssh": "root@${ip}",
  "states": { "active": "running", "off": "stopped", "new": "starting" },
  "create": "…", "delete": "…"
}
```

- `list` prints one workspace per line, split on whitespace into `columns`. The last column
  takes the rest of the line.
- Or, instead of `columns`, `"json": {"items": "<path to the array>", "id": "<path>", "name":
  "<path>", "state": "<path>", …}` reads the output as JSON. The paths are those of the
  [tool map](tool-map.md), within each item. An empty `items` means the output is the array.
- `${column}` in a template is the value from the workspace's row. It is shell-quoted before
  the command runs.
- `create`, `delete` and `options` (US5) need `list`, which finds what `create` made by its
  name. `create` fills in `${name}`, `${firstBoot}` and each option's key; with `${firstBoot}`
  it answers `firstBootRuns: true`. `delete` fills in `${id}` and the workspace's columns.
  `options` is the New Workspace form's JSON Schema; a property's `default` fills in a
  choice left out. Only `docker` with an `image` has them (#1025).
- `states` maps the CLI's words to contract states. A status output is matched
  case-insensitively after trimming whitespace.

## Presets (FR-071)

`{"preset": "<name>", …parameters}`. A preset is a set of the commands above, compiled in.
Its parameters fill them in.

| Preset | Parameters | List / start / stop | ssh |
|---|---|---|---|
| `docker` | `containers` (names, optional), `ssh`, `image` (optional) | With `containers`: `docker inspect -f '{{.State.Status}}' ${id}` / `docker start ${id}` / `docker stop ${id}`. Without (#1024): `docker ps -a --filter label=agents.workspace --format '{{.Names}}\t{{.State}}\t{{.Label "agents.ssh"}}'`, columns `id state ssh`, with the same start and stop. A container opts in with `docker run --label agents.workspace --label agents.ssh='…'`.With `image` and no `containers`: create `docker run -d --name ${name} --label agents.workspace ${image} && docker exec ${name} sh -c ${firstBoot}`, delete `docker rm -f -v ${id}`, options `image` (default the given one). States: running→running, exited/created→stopped, restarting→starting. | each container's `agents.ssh` label; else `ssh` as given |
| `doctl` | `tag` | `doctl compute droplet list --tag-name ${tag} …` / `droplet-action power-on --wait` / `power-off --wait`. States: active/new/off. | `root@${ip}` or `user` param |
| `codespaces` | `repo` (optional) | `gh codespace list --json name,displayName,state` / `gh codespace ssh -c ${id} -- true` (a codespace starts when used) / `gh codespace stop -c ${id}`. States: Available→running, Shutdown→stopped, Starting→starting. | `gh codespace ssh --config` alias, `tunnel: true` |
| `coder` | none | `coder list -o json` / `coder start -y ${id}` / `coder stop -y ${id}`. Read as JSON (`latest_build.status`). | `coder.${name}` (from `coder config-ssh`) |
| `gcloud-workstations` | `cluster`, `config`, `region` | `gcloud workstations list … --format='value(name.basename(),state)'` / `start` / `stop`. States: STATE_RUNNING and so on. | `tunnel: true`; `gcloud workstations ssh` alias is noted in docs |

Each preset's exact command lines are fixed by unit tests that check the strings (no CLI is
run). A preset needs its CLI installed and signed in where the control plane runs. If the CLI
isn't there, its first command exits 127, and the error is "‹cli› isn't installed where the
control plane runs".

Since #1119, `list`, `start`, `stop`, `create` and `delete` may each be a web request, and three
API presets use them: `digitalocean-api`, `codespaces-api` and `coder-api`. They need only a
token as the provider's secret. Their requests are in
[Workspace providers](../../../docs/reference/workspace-providers.md#a-web-request-in-place-of-a-command-1119),
and fixed by tests against a fake server.

## Behaviour

- Commands run through `/bin/sh -c`, using `ChildProcess`, from the server's working
  directory (the control home).
- Timeouts: `status` and `list` 25 s; `start`, `stop`, `create` and `delete` 9 min 55 s.
- A non-zero exit is a failure. The text is the last 20 lines of stderr (or stdout), cut at
  1 KB.
- `workspace_start` runs `start`, then `status` if there is one, until it says running, every
  5 s within the timeout. `workspace_stop` does the same for stopped.
- No command runs as root, and nothing asks for sudo. A preset never adds `sudo`.
- It writes nothing to disk and logs to stderr. Commands are logged, but the environment is
  not, and neither are `${…}` values that come from secrets.
- `--version` prints the version, as `ci-watcher` does.
