# Contract: capability lists (#1748)

## The schema

Each entry of `methods` in `Packages/Wire/daemon.openrpc.json` and `control.openrpc.json`:

```json
{ "name": "agents/branchFrom", "x-capability": "chat.branch/1", … }
```

`scripts/wire.sh check` fails when a method has none, or when its value is not `<name>/<n>`.

Capabilities that no method names are at the top of a document:

```json
"x-declared-capabilities": [{ "name": "host.wire/1", "by": "host", "description": "…" }]
```

## The handshake

```text
host → control   host/hello {…, "capabilities": ["agents/1", "chat.branch/1", …]}
client → control {"auth": {…, "capabilities": ["client.wire/1"]}}
client → control control/status → {…, "capabilities": [...], "required": {"host": [...], "client": [...]}}
client → control hosts/list → [{"id": …, "version": "0.7.0", "capabilities": [...], "missing": [], "state": "online"}]
control → client control/hostChanged (as today, when a host's record, its list among it, changes)
```

## Refusal of an old client

```json
{"error": {"code": -32008, "message": "This app needs an update.", "data": {"missing": ["client.wire/2"], "update": "0.8.0"}}}
```

## Clients

Each client has `has(capability, host)` on its model. It is true when the host's list has the
capability, or when the host sent no list (research R5).
