---
diataxis: reference
devices: [mac, web, server]
description: The tools a machine provider offers - contract 1 - their arguments, their answers, the states, and how the control plane checks and calls them.
---

# Machine providers

A machine provider is an ordinary MCP server, over stdio or streamable http, that the
control plane uses to start and stop the machines hosts run on. This page is the contract
it follows, version 1. The control plane recognises a provider by its tool names and the
version its list reports; it needs no MCP extension.

The Mac adds every kind in Settings ▸ Machine Providers. The web page adds the API
presets (`digitalocean-api`, `codespaces-api`, `coder-api`, `aws-ec2-api`,
`gcp-compute-api`) in Settings ▸ Machine providers, because a person in a browser has no
shell where the control plane runs to sign a CLI in (#1808).

**From a repository (#1809).** `providers/create` takes `repository`, an https address. A
provider whose New Machine form has a `repository` property makes the machine from it,
given as owner/name (Codespaces). Any other gets the same request with no repository, and the
host clones it once it joins, before `clones`. "Start a Machine from a Repository…" on all
three clients sends it.

## Tools

| Tool | Required | Takes | Answers |
| --- | --- | --- | --- |
| `workspaces_list` | yes | nothing | `{contract, workspaces: [Workspace]}` |
| `workspace_start` | yes | `{id}` | `{workspace: Workspace}` once it is running |
| `workspace_stop` | yes | `{id}` | `{workspace: Workspace}` once it is stopped |
| `workspace_options` | no | nothing | `{schema}`: the choices for a new machine, as JSON Schema |
| `workspace_create` | no | `{name, options, firstBoot?}` | `{workspace: Workspace, firstBootRuns}` |
| `workspace_delete` | no | `{id}` | `{}` once it is gone |

Contract 1 keeps these tool names and the `workspace`/`workspaces` payload fields; contract 2 may rename them.

### Making and deleting

- **`workspace_options`** answers a flat JSON Schema object: string, integer, boolean and
  `enum` properties, each with a `title`. The **New Machine** form is drawn from it. An
  `enum` property may have `x-costs`, its values' costs, such as
  `{"s-1vcpu-1gb": "$0.009/hour"}`, which the confirmation shows.
- **`workspace_create`** takes the name, the chosen `options`, and `firstBoot`: one shell
  line that installs Agents and joins it as a host, with a join code that works once. It
  ends with the new host's name as its second argument. Run it as the machine's own user on
  its first boot, never with sudo. Answer `firstBootRuns: true` if you will. Otherwise the
  person adds it over its `ssh`, as **Add as Machine…** does.
- **`workspace_delete`** deletes the machine and everything on it. The control plane then
  removes its host, as **Remove** does.

Agents asks the person before it makes or deletes anything. The first-boot line is never
logged.

## A machine

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | Stable across restarts, and unique in the list: a second machine with the same `id` is left out. What `workspace_start` and `workspace_stop` take. |
| `name` | string | Shown on the Providers page. |
| `state` | string | `running`, `starting`, `stopping`, `stopped` or `unknown`. Anything else is read as `unknown`. |
| `ssh` | string, optional | How the control plane's machine reaches it: `user@host`, an alias in its ssh config, or `user@host -p 2222`. It may change between starts, as a VM's address can: the tunnel and the ssh start use the one listed now, and check the host key trusted at the install (#1691). |
| `tunnel` | boolean, optional | It can't reach the control plane, so the control plane holds a reverse tunnel over ssh. |
| `hostKeyRenews` | boolean, optional | Its ssh host key is made again at each start, as a Google Cloud workstation's is. After a Start that the control plane made, its ssh start takes the key it is offered and pins it again; at any other time a changed key is refused (#1701). |
| `cost` | string, optional | Shown as it is, such as `$0.03/hour while running`. At most 120 characters. |

## Answers and failures

- **Answers.** A tool answers in `structuredContent`. A server that can't may put the same
  JSON in its first `text` content.
- **Failures.** A failure is a result with `isError: true`. Its text is shown to the person
  as it is, in the provider's words, cut at 1 KB, so write a sentence.
- **Repeats.** A start of a running machine succeeds at once, and so does a stop of a
  stopped one.

## How the control plane uses it

- **Checks.** When a provider is added, its `tools/list` must have the three required
  tools. Its first `workspaces_list` must report `contract: 1`. If either fails, the
  provider is refused, naming what is missing.
- **Lists.** The control plane lists each provider when it starts, every five minutes,
  after every start and stop, and when the Providers page opens.
- **Time limits.** A list gives up after 30 seconds. A start or stop gives up after ten
  minutes, and the person is told so.
- **One at a time.** Starts and stops go one at a time per machine. A second **Start**
  while one is under way joins it.
- **Connecting.** After a successful start, the control plane waits for the host's agentsd
  to connect. After two minutes it starts agentsd over the machine's `ssh`, without
  installing anything. After ten minutes it gives up.
- **Linking what it made.** A machine made with `firstBootRuns` is linked to its host
  when a host of its name joins, within ten minutes.
- **Where it runs.** Providers run on the control plane, never on a host, so they can start
  a host that is down. A control plane with several copies doesn't run them yet.

## Secrets

- **Where they live.** A provider's secrets are kept in the store at
  `v1/providersecrets/<provider>.json`, sealed by the keeper that seals people's secrets:
  `secrets-key` in the control plane's folder on a Mac, the KMS on a cloud machine (#2138).
  No value is in the store in clear, and a sealed record opens only at its own key. A store
  copy, a handover and a [backup](../how-to/back-up-a-control-plane.md) keep them. A control
  plane with no keeper keeps them in `provider-secrets.json` in its own folder, readable by
  its user only. They are never sent to a host or a client, and never logged.
- **How the provider gets them.** A server the control plane runs gets them as environment
  variables. A server at an address gets them through `${NAME}` in its configured headers.

## Tool maps

A server whose tools are named otherwise can be used through a tool map: which of its tools
stands for each of the above, how the arguments are written, and where each field is in its
answer. See [Add a machine provider](../how-to/add-a-machine-provider.md#a-tool-map-for-a-providers-own-mcp-server).

An agent can write the map, or a command provider's config, at Add Provider
([Let an agent write it](../how-to/add-a-machine-provider.md#let-an-agent-write-it)). The
map is then the same as a map that you wrote. The provider's record says which runtime
wrote it, and when (`writtenBy`), until you change it.

## The command provider

The command provider, `machine-commands`, ships with the control plane. It is a provider
that runs command lines you give it, or a preset's, through the shell. It follows the
contract on this page and speaks stdio. Its whole configuration is the JSON in
`WORKSPACE_COMMANDS_CONFIG`. Its secrets are the other environment variables the control
plane passes it, which its commands can use as `$NAME`.

```sh
WORKSPACE_COMMANDS_CONFIG='{"preset":"docker","containers":["devbox"],"ssh":"dev@127.0.0.1 -p 2222"}' machine-commands
```

### Machines, written out

```json
{
  "machines": [
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

#### Many machines from one entry

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

- `list` prints one machine per line, split on whitespace into `columns`. The last column
  takes the rest of the line.
- Or, instead of `columns`, `"json": {"items": "<path to the array>", "id": "<path>", "name":
  "<path>", "state": "<path>", …}` reads the output as JSON. The paths are those of a
  [tool map](#tool-maps), within each item. An empty `items` means the output is the array.
- `${column}` in a template is the value from the machine's row. It is shell-quoted before
  the command runs.
- `create`, `delete` and `options` need `list`, which finds what `create` made by its
  name. `create` fills in `${name}`, `${firstBoot}` and each option's key; with `${firstBoot}`
  it answers `firstBootRuns: true`. `delete` fills in `${id}` and the machine's columns.
  `options` is the New Machine form's JSON Schema; a property's `default` fills in a
  choice left out.
  Of the presets, `docker` with an `image` and `digitalocean-api` have them.
- `states` maps the CLI's words to contract states. A status output is matched
  case-insensitively after trimming whitespace.
- A path may pick an item of a list by a key's value: `networks.v4[type=public].ip_address`.
  `[]` takes the rest of the path in each item and joins the lists it finds:
  `reservationSet[].instancesSet`.

#### A web request in place of a command (#1119)

`list`, `start`, `stop`, `create` and `delete` may each be a request in place of a command:

```json
{
  "list": { "url": "https://cws.example/v1/machines", "headers": { "X-Api-Key": "${CWS_KEY}" } },
  "json": { "items": "machines", "id": "id", "state": "status" },
  "start": { "method": "POST", "url": "https://cws.example/v1/machines/${id}/start",
             "headers": { "X-Api-Key": "${CWS_KEY}" } },
  "stop": { "method": "POST", "url": "https://cws.example/v1/machines/${id}/stop",
            "headers": { "X-Api-Key": "${CWS_KEY}" }, "body": { "force": false } }
}
```

- `method` defaults to `GET`. `url` must be `https://` (or `http://`).
- `${…}` in `url` and in `body`'s text takes the machine's values. Each value in `url` is
  escaped as one path segment or query value.
- Only `headers` take a secret: `${NAME}` that is not a value is the provider's secret of that
  name. A secret is never put in an address, a log or an error. A secret that is not given
  fails the call with "It needs the NAME secret."
- A list request's answer is read as JSON: it needs `json`, not `columns`. With
  `"answer": "xml"` it is read as XML, into the same values: an element with children is an
  object, a list (children all `<item>`, or a name ending in `Set`) an array, and anything else
  its text. A refusal's words come from `Errors.Error.Message`, as AWS gives them.
- `"awsSign": {"service": "ec2", "region": "us-east-1"}` signs the request with AWS's
  Signature Version 4 from the secrets `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (and
  `AWS_SESSION_TOKEN` when given). The secret key is never sent.
- `"googleAuth": {"scope": "https://www.googleapis.com/auth/compute"}` sends the request with an
  OAuth access token for the scope, which the service account's JSON key in the secret
  `GOOGLE_SERVICE_ACCOUNT_KEY` gets from its `token_uri` with a signed JWT (RFC 7523). The
  token is kept until a minute before it ends. The key is never sent, logged or said.
- An answer other than 2xx is a failure, in the provider's own words (its JSON's `message`),
  cut at 1 KB. A redirect is not followed, so a header never goes to another address.
- An agent's draft with a request, or with a preset's `api` or `url`, is asked about before
  its check runs (#858), as the request could send a secret anywhere.

### Presets

`{"preset": "<name>", …parameters}`. A preset is a set of the commands above, compiled in.
Its parameters fill them in.

| Preset | Parameters | List / start / stop | ssh |
|---|---|---|---|
| `docker` | `containers` (names, optional), `ssh`, `image` (optional) | With `containers`: `docker inspect -f '{{.State.Status}}' ${id}` / `docker start ${id}` / `docker stop ${id}`. Without: `docker ps -a --filter label=agents.machine --format '{{.Names}}\t{{.State}}\t{{.Label "agents.ssh"}}'`, columns `id state ssh`, with the same start and stop. A container opts in with `docker run --label agents.machine --label agents.ssh='…'`. With `image` and no `containers`: create `docker run -d --name ${name} --label agents.machine ${image} && docker exec ${name} sh -c ${firstBoot}`, delete `docker rm -f -v ${id}`, options `image` (default the given one). States: running→running, exited/created→stopped, restarting→starting. | each container's `agents.ssh` label; else `ssh` as given |
| `doctl` | `tag` | `doctl compute droplet list --tag-name ${tag} …` / `droplet-action power-on --wait` / `power-off --wait`. States: active/new/off. | `root@${ip}` or `user` param |
| `codespaces` | `repo` (optional) | `gh codespace list --json name,displayName,state` / `gh codespace ssh -c ${id} -- true` (a codespace starts when used) / `gh codespace stop -c ${id}`. States: Available→running, Shutdown→stopped, Starting→starting. | `gh codespace ssh --config` alias, `tunnel: true` |
| `coder` | none | `coder list -o json` / `coder start -y ${id}` / `coder stop -y ${id}`. Read as JSON (`latest_build.status`). | `coder.${name}` (from `coder config-ssh`) |
| `gcloud-workstations` | `cluster`, `config`, `region`, `project` (optional: gcloud's default), `ssh` | `gcloud workstations list … --format='value(name.basename(),state)'` / `start` / `stop`. States: RUNNING (STATE_RUNNING in older gcloud) and so on; RECONCILING→starting. A workstation's ssh host key is new at each start: the ssh start after a Start takes the new one (#1701). | `ssh` as given (an ssh config host that reaches `gcloud workstations start-tcp-tunnel`), `tunnel: true`, `hostKeyRenews: true` |
| `digitalocean-api` | `tag`, `user` (default `root`), `sshKeys` (optional, key ids or fingerprints), `tunnel`, `api` (optional) | Secret `DIGITALOCEAN_API_TOKEN`. `GET /v2/droplets?per_page=200&tag_name=${tag}` / `POST /v2/droplets/${id}/actions` `{"type":"power_on"}` / `power_off`. Create `POST /v2/droplets` with the tag and `user_data` that makes the user `agents` and runs `${firstBoot}` as it, with linger; options `region` (`nyc3`), `size` (`s-1vcpu-1gb`), `image` (`ubuntu-24-04-x64`). Delete `DELETE /v2/droplets/${id}`. States as `doctl`. | `${user}@` the public IPv4 |
| `codespaces-api` | `repo` (optional, owner/name), `ssh` (optional), `api` (optional) | Secret `GITHUB_TOKEN`. `GET /user/codespaces` (or `/repos/${repo}/codespaces`) / `POST /user/codespaces/${id}/start` / `…/stop`. States as `codespaces`, and Queued, Awaiting, Rebuilding→starting. Makes a codespace from a repository (#1809): `POST /repos/${repository.owner}/${repository.name}/codespaces` with the name as `display_name`, the form's one option `repository` (owner/name); delete is `DELETE /user/codespaces/${id}`. It has no user data, so `firstBootRuns` is false: Add as Machine… installs Agents over ssh. | `cs.${id}.${branch}` (gh's `--config` host, ProxyCommand gh) or `ssh`; `tunnel: true` |
| `aws-ec2-api` | `region` (such as `us-east-1`), `tag` (a tag key, default `agents`), `user` (default `ec2-user`), `tunnel`, `api` (optional) | Secrets `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (and `AWS_SESSION_TOKEN` for a role's keys); each request is signed with SigV4. EC2's Query API, answered in XML: `DescribeInstances` with the tag and every state but terminated, read at `reservationSet[].instancesSet` / `StartInstances` / `StopInstances` with `InstanceId.1=${id}`. Name from the `Name` tag. States: pending→starting, running, stopping and shutting-down→stopping, stopped. No create or delete. | `${user}@` the public IPv4 |
| `gcp-compute-api` | `project`, `zone` (such as `us-west1-b`), `label` (a label key, default `agents`), `user` (default `agents`), `sshKeys` (optional, public key lines), `tunnel`, `api` (optional) | Secret `GOOGLE_SERVICE_ACCOUNT_KEY` (`googleAuth`). `GET /compute/v1/projects/${project}/zones/${zone}/instances?filter=labels.${label}:*` / `POST …/instances/${id}/start` / `…/stop`. Create `POST …/instances` with the label, a boot disk that is deleted with the VM, an external address on the `default` network, the keys in the metadata `agents-ssh-keys`, and a startup script that runs once: it makes the user `agents` with those keys (not Google's `ssh-keys`, whose user is a sudoer), turns on linger and runs `${firstBoot}` as it; options `machineType` (`e2-small`), `image` (`projects/debian-cloud/global/images/family/debian-12`), `diskSizeGb` (`20`). Delete `DELETE …/instances/${id}`. States: PROVISIONING and STAGING→starting, RUNNING, STOPPING and SUSPENDING→stopping, TERMINATED, STOPPED and SUSPENDED→stopped. | `${user}@` the external IPv4 |
| `coder-api` | `url` (the deployment) | Secret `CODER_SESSION_TOKEN`. `GET /api/v2/machines?q=owner:me` / `POST /api/v2/machines/${id}/builds` `{"transition":"start"}` / `stop`. States as `coder`. | `coder.${name}` (from `coder config-ssh`, ProxyCommand coder) |

A CLI preset needs its CLI installed and signed in where the control plane runs. If the CLI
isn't there, its first command exits 127, and the error is "‹cli› isn't installed where the
control plane runs". An API preset (`-api`) needs only its token, as the provider's secret.
`api` sends it somewhere other than the provider's own address (a proxy); the API presets'
tests point it at a fake server.

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
- `machine-commands --version` prints its version.

## Related

- [Start machines from Agents](../how-to/start-machines-from-agents.md)
- [Add a machine provider](../how-to/add-a-machine-provider.md)
