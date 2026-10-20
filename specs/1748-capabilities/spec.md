# Feature Specification: Capabilities decide, versions inform

**Feature Branch**: `agents/work-github-issue-1748`

**Created**: 2026-10-20

**Status**: Draft

**Input**: GitHub issue #1748. Capability lists decide what mixed versions of clients (the Mac
window, the Remote, the web page), hosts (`agentsd`) and the control plane can do. Versions
follow Semantic Versioning 2.0.0. Alex chose this on 2026-10-20; the rule is in the issue.

## The rule (from #1748)

1. **Capabilities decide, versions only inform.** No code compares versions to decide. The
   version is for people (Settings, logs, "update to X") and for the release.
2. **A capability is a name and a number:** `chat.branch/1`. A compatible change keeps the
   number. A breaking change makes a new number, and a peer sends each number that it still
   supports until the old one is removed.
3. **The schema owns the names.** Each method and notification in `Packages/Wire/*.openrpc.json`
   names its capability. The generator makes the constants for Go, Swift and TypeScript. A
   check fails when a method has no capability.
4. **Each peer sends its list:** a host when it connects, a client when it connects, the
   control plane in its status, with the list of each host.
5. **Clients gate the UI on capabilities.** They do not send a call and then show an empty pane.
6. **The control plane has a required set.** A host that does not have all of it shows
   "Needs an update"; a client that does not have all of it gets `-32008` with the missing names.
7. **Deprecation is per capability.** Before 1.0, a number can go in the next minor; after
   1.0, only in the next major.
8. **SemVer for the version string.** A tag `vX.Y.Z` gives the version of every part. A build
   that is not on a tag is `X.Y.(Z+1)-dev.N+g<sha>`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An older host does not show empty panes (Priority: P1)

Alex opens a host that runs an older `agentsd` from a newer window, Remote or web page. A
feature that the host cannot do is not shown as an empty pane or an error after a tap. It is
hidden, or it is disabled with "This host needs an update to do this".

**Why this priority**: This is the problem that users see today. Hosts on servers and
workstations update later than the Mac and the phone.

**Independent Test**: Connect a client to a host whose list does not include
`chat.branch/1`. The "Branch from Here" action is disabled with the update text, and the
client sends no `agents/branchFrom` call.

**Acceptance Scenarios**:

1. **Given** a host whose list has no `chat.branch/1`, **When** Alex opens a chat's turn menu
   on any of the three clients, **Then** "Branch from Here" is disabled and says the host needs
   an update.
2. **Given** a host whose list has `chat.branch/1`, **When** Alex opens the same menu,
   **Then** the action works as it does today.
3. **Given** a host that sends no list (a build from before this feature), **When** a client
   opens it, **Then** nothing is gated, and the client works as it does today.

---

### User Story 2 - Alex sees what each host can do, and its version (Priority: P2)

In Settings on each client, Alex sees the version of the control plane and of each host. A
host that does not have the control plane's required set shows "Needs an update", with the
missing capabilities and the version to update to.

**Why this priority**: Alex needs to know which part to update. Today the Remote and the web
page show no versions.

**Independent Test**: Connect a host that does not have one required capability. Its row
shows "Needs an update" on all three clients, with the missing name.

**Acceptance Scenarios**:

1. **Given** a control plane and two hosts, **When** Alex opens Settings ▸ Control plane on the
   Remote or the web page, **Then** Alex sees the control plane's version and each host's.
2. **Given** a host without a required capability, **When** it connects, **Then** its state is
   "needsUpdate" and each client shows the missing names.
3. **Given** a host that reconnects with a new list, **When** its list changes, **Then** every
   client sees the new list without a reload.

---

### User Story 3 - A client that is too old is told to update (Priority: P2)

A client whose list does not have the control plane's required set connects. Its calls are
refused with `-32008 WrongProtocolVersion`, which names the missing capabilities and the
version to update to. The client shows that to Alex, not a list of failed calls.

**Why this priority**: Before 1.0 a minor can remove a capability number. An old Remote must
then say "Update the app", not fail in many places.

**Independent Test**: Connect a test client that sends a list without a required capability.
Every call except `control/status` gets `-32008` with the missing names.

**Acceptance Scenarios**:

1. **Given** a client without a required capability, **When** it calls a method, **Then** the
   answer is `-32008` with `missing` and `update` in its data.
2. **Given** a client that sends no list, **When** it connects, **Then** it is not refused.

---

### User Story 4 - Developers add a method and its capability in one step (Priority: P1)

A developer adds a method to the schema. The generator refuses a method without a capability.
The generated constants give each language the name, and each server's list follows from the
methods it serves, with no list to keep by hand.

**Why this priority**: Every other story reads these names. It is the first PR.

**Independent Test**: Remove `x-capability` from one method and run the check. It fails and
names the method.

**Acceptance Scenarios**:

1. **Given** a method without `x-capability`, **When** the generator runs, **Then** it fails
   with the method's name.
2. **Given** the generated constants, **When** the Go host starts, **Then** its list has each
   capability whose methods it all serves, and no other method capability.

---

### User Story 5 - One version string, from the tag (Priority: P3)

Every part built from tag `v0.7.0` says `0.7.0`. A build from a later commit says
`0.7.1-dev.N+g<sha>`, which sorts above `0.7.0`. The release skill checks that the parts agree
and writes the capabilities added, deprecated and removed in the release notes.

**Why this priority**: The version is only for people, but it must be true and comparable.

**Independent Test**: Run the version script on a tag and on a commit after it, and compare
the output with SemVer's order.

**Acceptance Scenarios**:

1. **Given** HEAD on `v0.7.0`, **When** any build script stamps a version, **Then** it is `0.7.0`.
2. **Given** HEAD 12 commits after `v0.7.0`, **When** a script stamps a version, **Then** it is
   `0.7.1-dev.12+g<sha>`.

### Edge Cases

- A peer sends a capability name that this build does not know: it is kept and shown, never an
  error.
- A peer sends two numbers of one capability (`files/1`, `files/2`): `has` is true for each.
- A host serves only some of the methods of a capability: the capability is not in its list.
- A host's list changes while a client is open: the client gates on the new list at once.
- The control plane itself is older than a client: the client reads the control plane's own
  list in the same way as a host's.
- The web page is served by the control plane, so it always has the control plane's version;
  it still gates on each host's list.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Each method and notification in `Packages/Wire/*.openrpc.json` MUST have
  `x-capability`, a name and a number in the form `<name>/<n>`.
- **FR-002**: `scripts/wire.sh gen` MUST make the capability constants and the
  method-to-capability table for Go, Swift and TypeScript; `scripts/wire.sh check` MUST fail
  when one is stale or when a method has no `x-capability`.
- **FR-003**: A host MUST send its list in `host/hello` on each connect.
- **FR-004**: A client MUST send its list in the auth exchange (`ControlAuth`) on each connect.
- **FR-005**: The control plane MUST give its own list and its required set in
  `control/status`, and each host's list on its `ControlHost` record (`hosts/list`).
- **FR-006**: A change to a host's list MUST reach the clients without a reload.
- **FR-007**: A host's and the control plane's list MUST be made from the methods they serve
  (a capability is in it when every method that names it is served) plus capabilities they
  declare by hand.
- **FR-008**: The control plane MUST set a host to `needsUpdate` when its list does not have
  the required set, and MUST answer a client without it with `-32008`, with the missing names
  and the version to update to. A peer that sends no list MUST NOT be refused.
- **FR-009**: Each client MUST have one `has(capability)` check on its model of a host, and
  MUST gate the features that came after 0.5 on it.
- **FR-010**: The Remote and the web page MUST show the control plane's and each host's
  version in Settings; all three MUST show "Needs an update" with the missing names.
- **FR-011**: Every build script and the web manifest MUST take the version from the tag in the
  form of rule 8; the release skill MUST check that they agree.
- **FR-012**: `docs/explanation/versions.md` MUST say the rule.

### Key Entities

- **Capability**: a name and a number, `chat.branch/1`. Owned by the schema.
- **Capability list**: what one peer sends. Made from the methods it serves and what it declares.
- **Required set**: the capabilities the control plane needs of a host or a client to route.
- **Version**: a SemVer string from the tag. For people and releases only.

## Success Criteria *(mandatory)*

- **SC-001**: No code outside the version display and the release decides on a version
  string (a search of the three clients, Go and the scripts finds none).
- **SC-002**: 100% of the methods and notifications in the schema have a capability, enforced
  by CI.
- **SC-003**: On a host without a gated capability, each of the gated features is hidden or
  disabled on all three clients, and no call for it is sent.
- **SC-004**: An old host or client that sends no list works as it did before this feature.
- **SC-005**: A build on a tag and a build after it give SemVer versions in the right order.

## Assumptions

- Decisions settled by decide-and-tell on #1748 (Alex can overrule):
  - **Names** are lower case, with dots for parts and hyphens in words (`chat.branch/1`,
    `connections/1`). Each method that was in v0.5.0 takes its namespace, `<namespace>/1`
    (`agents/1`). Each method added after v0.5.0 takes the name of its feature, so that the
    clients can gate it.
  - **Clients send their list in `ControlAuth`,** not in `ClientAnnounce`: announce is sent once
    when a device pairs, and a client's list changes with each update.
  - **No new `host/capabilitiesChanged` notification:** a host's list is a field of its
    `ControlHost` record, and `control/hostChanged` already tells each client when that record
    changes.
  - **A peer that sends no list** is a build from before this feature: nothing is gated or
    refused for it, as today.
  - **The required sets** start as `host.wire/1` for hosts and `client.wire/1` for clients,
    capabilities each peer declares by hand (in the documents' `x-declared-capabilities`).
- Not in this feature (from #1748): `hosts/update` (the push of a new `agentsd`) and a CI skew
  test against the last release. They are filed after this lands.
- The held 0.8 audit lane (#996, PR #1752) changes the same wire files. This lane does not
  change its methods or types; a conflict in a generated file is settled by running the
  generator again.
