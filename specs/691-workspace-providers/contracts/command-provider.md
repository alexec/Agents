# Contract: the command provider (`workspace-commands`)

`workspace-commands` is a static Swift MCP server in `Packages/MCPServers`, built on
`MCPServerKit`. It follows the [provider contract](provider-contract.md) and speaks stdio. Its
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

- `list` prints one workspace per line, split on whitespace into `columns`. If `list` starts
  with `json:`, it is read as JSON instead, with the paths of the [tool map](tool-map.md).
- `${column}` in a template is the value from the workspace's row. It is shell-quoted before
  the command runs.
- `states` maps the CLI's words to contract states. A status output is matched
  case-insensitively after trimming whitespace.

## Presets (FR-071)

`{"preset": "<name>", …parameters}`. A preset is a set of the commands above, compiled in.
Its parameters fill them in.

| Preset | Parameters | List / start / stop | ssh |
|---|---|---|---|
| `docker` | `containers` (names), `ssh` | `docker inspect -f '{{.State.Status}}' ${id}` / `docker start ${id}` / `docker stop ${id}`. States: running→running, exited/created→stopped, restarting→starting. | as given |
| `doctl` | `tag` | `doctl compute droplet list --tag-name ${tag} …` / `droplet-action power-on --wait` / `power-off --wait`. States: active/new/off. | `root@${ip}` or `user` param |
| `codespaces` | `repo` (optional) | `gh codespace list --json name,displayName,state` / `gh codespace ssh -c ${id} -- true` (a codespace starts when used) / `gh codespace stop -c ${id}`. States: Available→running, Shutdown→stopped, Starting→starting. | `gh codespace ssh --config` alias, `tunnel: true` |
| `coder` | none | `coder list -o json` / `coder start -y ${id}` / `coder stop -y ${id}`. Read with `json:` paths. | `coder.${name}` (from `coder config-ssh`) |
| `gcloud-workstations` | `cluster`, `config`, `region` | `gcloud workstations list --format=json …` / `start` / `stop`. | `tunnel: true`; `gcloud workstations ssh` alias is noted in docs |

Each preset's exact command lines are fixed by unit tests that check the strings (no CLI is
run). A preset needs its CLI installed and signed in where the control plane runs. If the CLI
isn't there, its first command exits 127, and the error is "‹cli› isn't installed where the
control plane runs".

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
