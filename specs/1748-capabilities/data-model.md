# Data model: capabilities (#1748)

## Capability

A string `<name>/<n>`. `name` matches `^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)*$`; `n` is an integer of
1 or more. A list may have more than one number of one name.

## Generated, per language

| What | Go (`Go/wire/capabilities_gen.go`) | Swift (`Capabilities.generated.swift`) | TypeScript (`capabilities.generated.ts`) |
|---|---|---|---|
| A constant per capability | `CapChatBranch1 = "chat.branch/1"` | `Capability.chatBranch1` | `Capability.chatBranch1` |
| Method → capability, per document | `HostCapabilities`, `ControlCapabilities` (`map[string]string`) | `Capability.host`, `Capability.control` (`[String: String]`) | `HostCapabilities`, `ControlCapabilities` |

## On the wire (`daemon.schema.json`)

| Type | New field | Meaning |
|---|---|---|
| `HostHello`, `HostAnnounce` | `capabilities?: [string]` | the host's list |
| `ControlAuth` | `capabilities?: [string]` | the client's (or peer's) list |
| `ControlStatus` | `capabilities?: [string]`, `required?: {host: [string], client: [string]}` | the control plane's list and its required sets |
| `ControlHost` | `capabilities?: [string]`, `missing?: [string]` | the host's list as last sent, and the required ones it does not have |

Each field is optional: a peer from before this feature does not send it (research R5).

## Host state

`needsUpdate` (exists): set when `missing` is not empty. It goes back to `online` when the host
reconnects with a list that has the required set.

## Failure

`-32008 WrongProtocolVersion` (exists): `data: {missing: [string], update: string}`.
