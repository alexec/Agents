---
diataxis: explanation
description: How the Mac window, the Remote, the web page, the hosts and the control plane work together at different versions, and what a version number means.
devices: [mac, iphone, ipad]
---

# Versions and capabilities

The Mac window, the Remote on iPhone and iPad, the web page, each host (`agentsd`) and the
control plane can each run a different version. A server's host can update a week after the
Mac, and the Remote updates when TestFlight sends it. This page explains how the parts know
what each other can do, and what a version number means (#1748).

## Capabilities decide

Each part sends a list of its **capabilities** when it connects. A capability is a name and a
number, such as `chat.branch/1` (Branch from Here) or `agents/1`. Each decision reads the
list, never the version:

- A client shows a feature only when the host has its capability. When it does not, the
  feature is disabled with "This host needs an update to do this". The client does not send the
  call and then show an empty pane.
- The control plane keeps a **required set**: the capabilities that it needs to route. A host
  without one of them shows "Needs an update", with the names that it does not have. A client
  without one of them is told to update the app.
- A part from before capabilities sends no list. Nothing is hidden or refused for it.

The version is for people: Settings, logs, "update to 0.8.0", and the release notes.

## Where the names come from

The schema owns the names. Each method and notification in `Packages/Wire/*.openrpc.json` has
`x-capability`, and `scripts/wire.sh gen` makes the constants for Go, Swift and TypeScript
(`Go/wire/capabilities_gen.go`, `Capabilities.generated.swift`,
`Web/src/protocol/capabilities.generated.ts`). The generator refuses a method without one.

- A method that was in 0.5.0 has its namespace: `agents/list` is `agents/1`.
- A method added after that has the name of its feature, so that a client can gate it:
  `agents/branchFrom` is `chat.branch/1`. The methods of one feature share its name.
- A host's list has a capability when the host serves every method that names it. A
  capability that no method names is declared by hand, in a document's
  `x-declared-capabilities`: `host.wire/1` and `client.wire/1` say that a peer sends its list.

## Where each part sends its list

- A host sends its list in `host/hello`, each time it connects.
- A client (the Mac window, the Remote, the web page) sends its list in the auth line of each
  connection.
- The control plane gives its own list and its required sets in `control/status`, and each
  host's list, with what it is missing, in `hosts/list`. When a host's list changes,
  `control/hostChanged` tells the clients.

The required sets start as `host.wire/1` for hosts and `client.wire/1` for clients. A client
without its set gets `-32008` on every call except `control/status`, with the missing names
and the version to update to.

## Changing a capability

- **A compatible change keeps the number:** a new optional field, or a new enum value with
  `x-fallback`.
- **A breaking change makes a new number.** A part sends each number that it still supports
  (`files/1` and `files/2`) until the old one is removed.
- **Deprecation is per capability.** A release marks `files/1` deprecated, in the schema and
  in the release notes. A later release takes it out of the required set, and then removes it.
  Before 1.0 this can happen in the next minor release; after 1.0, only in the next major.

The required set is the only window of versions that work together: it moves only when an old
capability number is removed.

## Version numbers

Versions follow [Semantic Versioning 2.0.0](https://semver.org). The tag `vX.Y.Z` gives the
version of every part: `agentsd`, `agents-control`, the web page, the Mac app and the Remote.
A build that is not on a tag is `X.Y.(Z+1)-dev.N+g<sha>`, which sorts after `X.Y.Z`. Before
1.0, a minor release can remove a capability number; a patch release never does.
