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
| `id` | string | Stable across restarts. What `workspace_start` and `workspace_stop` take. |
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

## Related

- [Start workspaces from Agents](../how-to/start-workspaces-from-agents.md)
- [Add a workspace provider](../how-to/add-a-workspace-provider.md)
