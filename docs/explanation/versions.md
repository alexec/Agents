---
diataxis: explanation
description: How the Mac window, the Remote, the web page, the hosts and the control plane work together at different versions, and what a version number means.
devices: [mac, iphone, ipad, web]
---

# Versions and capabilities

The Mac window, the Remote on iPhone and iPad, the web page, each host (`agentsd`) and the
control plane can each run a different version. A server's host can update a week after the
Mac, and the Remote updates when TestFlight sends it. This page explains how the parts know
what each other can do, and what a version number means (#1748).

## Capabilities

Each part sends a list of its **capabilities** when it connects. A capability is a name and a
number, such as `chat.branch/1` (Branch from Here) or `agents/1`. Each decision reads the
list, never the version. The version is for people: Settings, logs, "update to 0.8.0", and
the release notes.

So a client shows only what its host can do, and it says so where something is missing. It
does not send a call that the host cannot answer and then show an empty pane, which would
look like a fault. The words are the same on the Mac, the Remote and the web page.

### A feature the host is too old for

The client keeps the control, greyed, with **This host needs an update to do this.** as its
help, so you can see that the feature exists and why it is not offered here:

- **Branch from Here**, in a prompt's menu and in the Prompts list.
- **Edit** on a queued prompt.
- **Find in Chat**. On the Mac it keeps **⌘F** (Command-F), so the key does not move you
  out of the chat to Find Session. On the Remote the line is under the menu item.

Where a whole section or pane needs the feature, the line is in its place:

- A folder's connector set-up, and your own connections on the connectors page.
- The **Simulator** pane. On the Mac and the Remote it says **Needs an Update** above the
  line.
- **Language-server problems** in a file say it as their heading, and an asked completion
  says it as its note. No call goes to the host.

Each host has its own list, so the same chat feature can be there for a folder on one host
and greyed for a folder on another.

### A host too old for the control plane

The control plane keeps a **required set**: the capabilities that it needs to route. A host
without one of them is still connected and serves what its list says, but its row says
**Needs an update**, with a second line: "Update this host to Agents 0.9.0. It does not have
…", and the names it is missing, and **Update…** in its menu updates it over ssh (#1766). A
Mac does not wait for that: at each join the control plane names its own version as the
release (`host/release`, to a host that says `host.update/1`), and Agents Host updates itself
to it when it is newer, between turns and with no admin password (#2178). On the Mac this is in **Settings ▸ Control plane**, on the
host's row. On the Remote and the web page it is in **Settings ▸ Versions**, which also gives
the control plane's version and each host's, such as **Agents 0.9.0 (Go)** for a host written
in Go.

### An app too old for the control plane

A client without the control plane's required set is refused, as
[Where each part sends its list](#where-each-part-sends-its-list) says, with the error "This
app needs an update to work with this control plane." The client says what to do: "Update
this app to Agents 0.9.0 to use this control plane. It does not have …", with the missing
names. On the Mac this is under the control plane's row
in **Settings ▸ Control plane**; on the Remote it is in **Settings ▸ Versions**. The web page
says "Update this page …" in the same place. The control plane serves the web page, so a
page loaded fresh always has the control plane's version; only a tab left open across an
update can see this.

### A part from before capabilities

A part from before capabilities sends no list. Nothing is hidden or refused for it: the
client offers every feature, and a call that the host does not know fails as it did before.

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

On a control plane with more than one person (a team), the required sets also have
`host.team/1` and `client.team/1` (#1763). A build from before the team tier cannot tell
people apart, so it is refused. A client without `client.team/1`, or with no list, gets
`-32074` (`updateToJoinTeam`, "Update Agents to join this team") on every call except
`control/status`. A host without `host.team/1` is "Needs an update", and each call to it
gets `-32074`. When only one person is left, they work again.

## Changing a capability

- **A compatible change keeps the number:** a new optional field, or a new enum value with
  `x-fallback`.
- **A breaking change makes a new number.** A part sends each number that it still supports
  (`files/1` and `files/2`) until the old one is removed.
- **Deprecation is per capability.** A release marks `files/1` deprecated, in the schema (a
  document's `x-deprecated-capabilities`) and in the release notes, which list the
  capabilities each release adds, deprecates and removes. A later release takes it out of the required set, and then removes it.
  Before 1.0 this can happen in the next minor release; after 1.0, only in the next major.

The required set is the only window of versions that work together: it moves only when an old
capability number is removed.

CI's `skew` job (`scripts/skew-test.sh`, #1767) checks this on every change to the Go code. It joins
the last release's `agentsd` to the new control plane, which must not call it out of date
unless the required set moved, and pairs the new client with the last release's control plane,
which must answer it. It also lists what the clients hide for the older host.

## Version numbers

Versions follow [Semantic Versioning 2.0.0](https://semver.org). The tag `vX.Y.Z` gives the
version of every part: `agentsd`, `agents-control`, the web page, the Mac app and the Remote.
A build that is not on a tag is `X.Y.(Z+1)-dev.N+g<sha>`, which sorts after `X.Y.Z`;
`scripts/version.sh` prints it, and every build script stamps it. The Mac app and the Remote
say `X.Y.Z` (Apple takes digits and dots only): the tag's, or `X.Y.(Z+1)` after it. The web page
has no version of its own: the control plane serves it, so it is the control plane's. Before
1.0, a minor release can remove a capability number; a patch release never does.
