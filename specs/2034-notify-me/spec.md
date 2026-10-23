# Feature Specification: Notify me

**Issue**: #2034, "Notify me: a person chooses server events (checks failed on my PR, review requested) that send a notification"

**Created**: 2026-10-22

**Status**: Draft

## Why this feature exists

The github, gitlab and linear servers send events: a PR's checks failed, a PR is in conflict, an issue was opened. Today, only workflows and agents' waits hear them. A person hears nothing unless a workflow starts an agent.

Alex (2026-10-21): "it might be nice to enable notifications to the user from this MCP server, such as pull requests. What can we do in this space?"

This feature lets a person choose events that tell **them**. The notification goes the same way as a Needs you notification (spec 021): to the device the person is on, and it stays quiet while they look at the app.

## Decisions

These come from #2034 and its comments. Alex can overrule any of them.

- **D1. A "Notify me" list on each server.** It is not a workflow with no agent, and it is not MCP's `notifications/message`. It needs no workflow, and it uses spec 021's way to deliver.
- **D2. One meaning of "yours", shared with #2453.** The person is the owner of the server's connection, so their login on GitHub, GitLab or Linear. On a machine there is one user (#1117), so that owner is the person. *Your PR* is a PR that they authored. *A review requested from you* names them as a reviewer. *An issue assigned to you* names them as an assignee.
- **D3. Two events are on at first for github and gitlab:** "a PR of mine failed its checks" and "a review was requested from me". The others are off.
- **D4. A notice is not a Needs you row.** Needs you is for things that block an agent (#1802). A notice is a banner that goes away when the person opens it, or after a day.
- **D5. The trust filter of #728 does not apply to your own PRs and issues.** You are always trusted for them.

## What the person sees

### The Notify me list

In a server's settings (Settings ▸ Agent Configuration ▸ Connectors ▸ the server on the Mac, and the server's page on the Remote and the web), under its events, there is **Notify me**. It is one switch for each event that a person can be told of:

| Server | Events |
| --- | --- |
| github | A PR of mine failed its checks · A PR of mine is in conflict · A review was requested from me · An issue was assigned to me |
| gitlab | The same, for merge requests and pipelines |
| linear | An issue was assigned to me |

The choices are the person's, for each project. They are kept on the host that has the server, in `<root>/notify-me.json`, and not in the project, because a notice is for one person and a project is for its team.

### The notice

- **The banner:** "Checks failed on #123 Fix the walk" (title), and "github · agents" (the server and the project), on the Mac, the iPhone or iPad, or the web page (when it allows notifications). Spec 021 chooses where it goes.
- **Opening it** opens the item on its site (the PR, the issue), in the browser.
- It is not a row in Needs you, and it does not count in the badge.

## How it works

1. **The servers** get what the list needs.
   - `mine: true` on `checks.failed` and `pr.conflicted` (github, gitlab): only PRs by the connection's owner.
   - A new `review.requested` (github, gitlab): a review was requested from the connection's owner on an open PR. It is raised again after the request is removed and made again.
   - A new `issue.assigned` (github, gitlab, linear): an open issue was assigned to the connection's owner. It is raised again after it is unassigned and assigned again.
2. **The host** makes one subscription for each chosen event, as it does for a workflow's trigger. The subscription is shared when a workflow names the same event and arguments.
3. **When a chosen event comes**, the host keeps a notice: an id, the project, the server, a headline and the item's address. Spec 021's ladder offers it as a need of the kind `notice`: to the window, or else through the control plane to a device. A notice that was opened, or that is a day old, is withdrawn.
4. **The clients** draw the list (`notify/list`, `notify/set`) and post the banner. They leave notices out of Needs you.

## Wire

- `NeedKind`: `notice`. `NeedID`: `notice: {id}`.
- `Need.url`: the address that a notice opens.
- `notify/list {folder}` → `{servers: [{server, title, events: [{event, title, on}]}]}`.
- `notify/set {folder, server, event, on}` → the same as `notify/list`.
- `notice/open {id}`: the notice was opened, so withdraw it everywhere.

## Delivery in parts

1. **Servers** (one PR, Refs #2034): `mine`, `review.requested` and `issue.assigned` on github, gitlab and linear, with their tests and the rows in `docs/reference/integrations.md`.
2. **Host, wire and the three clients** (one PR, Fixes #2034): `notify-me.json`, the subscriptions, the `notice` need, the Notify me list and the banner on the Mac, the Remote and the web. The parity row.

## Not in this feature

- Events from other servers. Any server's events can come later: the list shows only the events that this spec names.
- Mute for a time, digests, and quiet hours.
