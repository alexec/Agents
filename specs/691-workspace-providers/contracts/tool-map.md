# Contract: a tool map (FR-001a)

A tool map lets an MCP server whose tools don't follow the [contract](provider-contract.md)
be used as a provider. It is JSON, kept in the provider's record, and typed into the Add Provider
sheet or chosen from the shipped maps.

```json
{
  "list": {
    "tool": "droplet-list",
    "arguments": { "tag_name": "agents" },
    "items": "droplets[]",
    "id": "id",
    "name": "name",
    "state": "status",
    "ssh": "root@{networks.v4[0].ip_address}",
    "states": { "active": "running", "new": "starting", "off": "stopped", "archive": "stopped" }
  },
  "start": { "tool": "droplet-actions-power-on", "arguments": { "droplet_id": "{id}" } },
  "stop":  { "tool": "droplet-actions-power-off", "arguments": { "droplet_id": "{id}" } }
}
```

The `droplet-*` names are only an example. The DigitalOcean map that ships (FR-072) is written
against their server's real tool list in the US2 PR. If that list lacks power on and off, it is
left out and the `doctl` preset is the DigitalOcean example.

## Paths

- A path is dotted keys with `[n]` for an array index and `[]` for every element, as in
  `droplets[]` or `networks.v4[0].ip_address`.
- A path is evaluated against the tool's `structuredContent`, or against the first text
  content parsed as JSON.
- `{path}` inside a string template is replaced with the value at that path, read relative to
  the item. In `arguments`, `{id}` is the contract's argument, the workspace id.
- A path that finds nothing gives null. A null `id` or `name` drops the item. A null `state`
  is read as `unknown`.

## Keys

| Key | Required | Meaning |
|---|---|---|
| `list.tool`, `start.tool`, `stop.tool` | yes | The server's tools. Each must be in `tools/list` when the provider is added. |
| `*.arguments` | no | A JSON template for the call's arguments. |
| `list.items` | yes | The path to the array of workspaces. |
| `list.id`, `list.name` | yes | Paths within an item. |
| `list.state` | yes | A path within an item. Its value is looked up in `states`. If it isn't there, it is used as a contract state when it is one, and as `unknown` otherwise. |
| `list.ssh`, `list.tunnel`, `list.cost` | no | Paths or templates. |
| `create`, `delete`, `options` | no | The same shape as `start`. `create.workspace` gives a path to the new item. |

## Checking

When the provider is added, and when its map is changed:

- Every `tool` named must be in the server's `tools/list`. If one isn't, the refusal names it
  (US2 AS6).
- The paths must parse.
- The map is at most 30 lines when pretty-printed (SC-004). This is a guide, not enforced.
- Then one `list` is called, and its result must give at least the array at `items`. An empty
  array is fine.
