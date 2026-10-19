---
diataxis: reference
devices: [mac, server]
description: The tools a workspace provider offers - contract 1 - their arguments, their answers, the states, and how the control plane checks and calls them.
---

# Workspace providers

A workspace provider is an ordinary MCP server, over stdio or streamable http, that the
control plane uses to start and stop the machines hosts run on. This page is the contract
it follows, version 1. The control plane recognises a provider by its tool names and the
version its list reports; it needs no MCP extension.

## Tools

| Tool | Required | Takes | Answers |
| --- | --- | --- | --- |
| `workspaces_list` | yes | nothing | `{contract, workspaces: [Workspace]}` |
| `workspace_start` | yes | `{id}` | `{workspace: Workspace}` once it is running |
| `workspace_stop` | yes | `{id}` | `{workspace: Workspace}` once it is stopped |
| `workspace_options` | no | nothing | `{schema}`: the choices for a new workspace, as JSON Schema |
| `workspace_create` | no | `{name, options, firstBoot?}` | `{workspace: Workspace, firstBootRuns}` |
| `workspace_delete` | no | `{id}` | `{}` once it is gone |

### Making and deleting

- **`workspace_options`** answers a flat JSON Schema object: string, integer, boolean and
  `enum` properties, each with a `title`. The **New Workspace** form is drawn from it. An
  `enum` property may have `x-costs`, its values' costs, such as
  `{"s-1vcpu-1gb": "$0.009/hour"}`, which the confirmation shows.
- **`workspace_create`** takes the name, the chosen `options`, and `firstBoot`: one shell
  line that installs Agents and joins it as a host, with a host code that works once. It
  ends with the new host's name as its second argument. Run it as the workspace's own user on
  its first boot, never with sudo. Answer `firstBootRuns: true` if you will. Otherwise the
  person adds it over its `ssh`, as **Add as Host…** does.
- **`workspace_delete`** deletes the workspace and everything on it. The control plane then
  removes its host, as **Remove** does.

Agents asks the person before it makes or deletes anything. The first-boot line is never
logged.

## A workspace

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | Stable across restarts, and unique in the list: a second workspace with the same `id` is left out. What `workspace_start` and `workspace_stop` take. |
| `name` | string | Shown on the Providers page. |
| `state` | string | `running`, `starting`, `stopping`, `stopped` or `unknown`. Anything else is read as `unknown`. |
| `ssh` | string, optional | How the control plane's machine reaches it: `user@host`, an alias in its ssh config, or `user@host -p 2222`. |
| `tunnel` | boolean, optional | It can't reach the control plane, so the control plane holds a reverse tunnel over ssh. |
| `cost` | string, optional | Shown as it is, such as `$0.03/hour while running`. At most 120 characters. |

## Answers and failures

- **Answers.** A tool answers in `structuredContent`. A server that can't may put the same
  JSON in its first `text` content.
- **Failures.** A failure is a result with `isError: true`. Its text is shown to the person
  as it is, in the provider's words, cut at 1 KB, so write a sentence.
- **Repeats.** A start of a running workspace succeeds at once, and so does a stop of a
  stopped one.

## How the control plane uses it

- **Checks.** When a provider is added, its `tools/list` must have the three required
  tools. Its first `workspaces_list` must report `contract: 1`. If either fails, the
  provider is refused, naming what is missing.
- **Lists.** The control plane lists each provider when it starts, every five minutes,
  after every start and stop, and when the Providers page opens.
- **Time limits.** A list gives up after 30 seconds. A start or stop gives up after ten
  minutes, and the person is told so.
- **One at a time.** Starts and stops go one at a time per workspace. A second **Start**
  while one is under way joins it.
- **Connecting.** After a successful start, the control plane waits for the host's agentsd
  to connect. After two minutes it starts agentsd over the workspace's `ssh`, without
  installing anything. After ten minutes it gives up.
- **Linking what it made.** A workspace made with `firstBootRuns` is linked to its host
  when a host of its name joins, within ten minutes.
- **Where it runs.** Providers run on the control plane, never on a host, so they can start
  a host that is down. A control plane with several copies doesn't run them yet.

## Secrets

- **Where they live.** A provider's secrets are kept in `provider-secrets.json` in the
  control plane's own folder, readable by its user only. They are never in the store, never
  sent to a host or a client, and never logged.
- **How the provider gets them.** A server the control plane runs gets them as environment
  variables. A server at an address gets them through `${NAME}` in its configured headers.

## Tool maps

A server whose tools are named otherwise can be used through a tool map: which of its tools
stands for each of the above, how the arguments are written, and where each field is in its
answer. See [Add a workspace provider](../how-to/add-a-workspace-provider.md#a-tool-map-for-a-providers-own-mcp-server).

An agent can write the map, or a command provider's config, at Add Provider
([Let an agent write it](../how-to/add-a-workspace-provider.md#let-an-agent-write-it)). The
map is then the same as a map that you wrote. The provider's record says which runtime
wrote it, and when (`writtenBy`), until you change it.

## The command provider

The command provider, `workspace-commands`, ships with the control plane. It is a provider
that runs command lines you give it, or a preset's, through the shell. It follows the
contract on this page and speaks stdio. Its whole configuration is the JSON in
`WORKSPACE_COMMANDS_CONFIG`. Its secrets are the other environment variables the control
plane passes it, which its commands can use as `$NAME`.

```sh
WORKSPACE_COMMANDS_CONFIG='{"preset":"docker","containers":["devbox"],"ssh":"dev@127.0.0.1 -p 2222"}' workspace-commands
```

### Workspaces, written out

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

#### Many workspaces from one entry

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
  "<path>", "state": "<path>", …}` reads the output as JSON. The paths are those of a
  [tool map](#tool-maps), within each item. An empty `items` means the output is the array.
- `${column}` in a template is the value from the workspace's row. It is shell-quoted before
  the command runs.
- `create`, `delete` and `options` need `list`, which finds what `create` made by its
  name. `create` fills in `${name}`, `${firstBoot}` and each option's key; with `${firstBoot}`
  it answers `firstBootRuns: true`. `delete` fills in `${id}` and the workspace's columns.
  `options` is the New Workspace form's JSON Schema; a property's `default` fills in a
  choice left out.
  Of the presets, only `docker` with an `image` has them.
- `states` maps the CLI's words to contract states. A status output is matched
  case-insensitively after trimming whitespace.

### Presets

`{"preset": "<name>", …parameters}`. A preset is a set of the commands above, compiled in.
Its parameters fill them in.

| Preset | Parameters | List / start / stop | ssh |
|---|---|---|---|
| `docker` | `containers` (names, optional), `ssh`, `image` (optional) | With `containers`: `docker inspect -f '{{.State.Status}}' ${id}` / `docker start ${id}` / `docker stop ${id}`. Without: `docker ps -a --filter label=agents.workspace --format '{{.Names}}\t{{.State}}\t{{.Label "agents.ssh"}}'`, columns `id state ssh`, with the same start and stop. A container opts in with `docker run --label agents.workspace --label agents.ssh='…'`. With `image` and no `containers`: create `docker run -d --name ${name} --label agents.workspace ${image} && docker exec ${name} sh -c ${firstBoot}`, delete `docker rm -f -v ${id}`, options `image` (default the given one). States: running→running, exited/created→stopped, restarting→starting. | each container's `agents.ssh` label; else `ssh` as given |
| `doctl` | `tag` | `doctl compute droplet list --tag-name ${tag} …` / `droplet-action power-on --wait` / `power-off --wait`. States: active/new/off. | `root@${ip}` or `user` param |
| `codespaces` | `repo` (optional) | `gh codespace list --json name,displayName,state` / `gh codespace ssh -c ${id} -- true` (a codespace starts when used) / `gh codespace stop -c ${id}`. States: Available→running, Shutdown→stopped, Starting→starting. | `gh codespace ssh --config` alias, `tunnel: true` |
| `coder` | none | `coder list -o json` / `coder start -y ${id}` / `coder stop -y ${id}`. Read as JSON (`latest_build.status`). | `coder.${name}` (from `coder config-ssh`) |
| `gcloud-workstations` | `cluster`, `config`, `region` | `gcloud workstations list … --format='value(name.basename(),state)'` / `start` / `stop`. States: STATE_RUNNING and so on. | `tunnel: true` |

A preset needs its CLI installed and signed in where the control plane runs. If the CLI
isn't there, its first command exits 127, and the error is "‹cli› isn't installed where the
control plane runs".

### Behaviour

- Commands run through `/bin/sh -c`, from the server's working
  directory (the control home).
- Timeouts: `status` and `list` 25 s; `start`, `stop`, `create` and `delete` 9 min 55 s.
- A non-zero exit is a failure. The text is the last 20 lines of stderr (or stdout), cut at
  1 KB.
- `workspace_start` runs `start`, then `status` if there is one, until it says running, every
  5 s within the timeout. `workspace_stop` does the same for stopped.
- No command runs as root, and nothing asks for sudo. A preset never adds `sudo`.
- It writes nothing to disk and logs to stderr. Commands are logged, but the environment is
  not, and neither are `${…}` values that come from secrets.
- `workspace-commands --version` prints its version.

## Related

- [Start workspaces from Agents](../how-to/start-workspaces-from-agents.md)
- [Add a workspace provider](../how-to/add-a-workspace-provider.md)
