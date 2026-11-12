# Refs, one event bus, and workflows on it (#4724)

Status: draft, by Claude (Product Owner), 2026-11-11. Alex's idea, in Alex's words:

> Everything gets a ref which humans and agents understand. It encodes the provider, type,
> and id. It is readable. Every event gets a ref, type, provider, topic. Agents can
> subscribe to events by type, provider and topic. Topics are repo full name, Jira project,
> Slack channel, etc. All events go onto one bus, regardless of the machine. Two machines
> may produce the same events. The system will debounce. An event may be produced on one
> machine and consumed on others. Event producers can be distributed.

## What we have now

- **Refs exist, but only in lineage** (`specs/2348-lineage/spec.md`): `<scheme>:<id>`, for
  example `github:alexec/agents#123`, `gitlab:group/repo!45`, `linear:ENG-4`,
  `session:<id>`. The type is in a sigil (`#`, `!`) or not there at all.
- **Events are per machine.** Each agentsd writes `<root>/events.jsonl`
  (`Go/internal/agentsd/events.go`). A wait or a workflow hears only its own machine's
  events, with one exception: `agent.ended` with `agent` reaches every session of the
  project (`eventwaits.go`, #3799).
- **MCP server events are polled by each machine** (`Go/internal/mcpevents`). Two machines
  that listen for `pr.merged` on the same repo each poll GitHub, and each records the event.
- **Names are `noun.verbed`** (`pr.merged`, `agent.ended`). `server:` narrows a trigger to
  one MCP server. Filters (`where`) are each server's own (`repo`, `pr`, `branch`, …).
- **The control plane** routes messages between machines and clients, and merges each
  machine's lineage links (#4275). It holds no customer secrets (principle 6).

## The model

### A ref

A ref names one thing so that a person can read it and an agent can parse it.

```
ref      = provider ":" type ":" topic "#" id
provider = [a-z0-9-]+               github, gitlab, jira, linear, slack, email, sentry, agents
type     = [a-z0-9-]+               pr, issue, branch, commit, run, message, session, machine
topic    = any text without ":" or "#"; can be empty
id       = any text (the first "#" ends the topic; the id can hold "#" and "/")
```

| Thing | Ref |
| --- | --- |
| A pull request | `github:pr:alexec/agents#4702` |
| An issue | `github:issue:alexec/agents#4724` |
| A branch | `github:branch:alexec/agents#agents/fix-640` |
| A CI run | `github:run:alexec/agents#19283746` |
| A GitLab merge request | `gitlab:mr:group/sub/repo#45` |
| A Jira issue | `jira:issue:ABC#ABC-9` |
| A Linear issue | `linear:issue:ENG#ENG-4` |
| A Slack message | `slack:message:T01ABC/C02DEF#1699999999.000100` |
| A mail | `email:message:alex@example.com#<message-id>` |
| A session | `agents:session:alexec/agents#7f3c…` |
| A machine | `agents:machine:#mac-mini` |

- **The topic of a ref is the topic of its events** (below), so a ref says where to
  subscribe.
- **Lower case** for provider, type and topic; the id keeps its case (a Slack ts, a mail
  Message-ID).
- **The short forms stay as input.** `#123`, `P#123`, `github:alexec/agents#123` and
  `owner/repo#123` parse to the full ref, with the folder's `origin` for the topic and the
  forge's answer for the type when the form does not say it. The app always writes the
  full form.
- **One package** parses and formats refs (`Packages/Wire` type `Ref`, Go `wire.Ref`, the
  generated TypeScript), so the daemon, the control plane and the clients agree.
- **Lineage moves to it.** Lineage node refs are written in the full form; a reader takes
  the old form for one release.

Decided: `provider:type:topic#id`, because the existing `<scheme>:<path>#n` form cannot
say the type of a thing whose id holds `/` (a branch) and cannot be split from the right;
the `#` keeps it close to what people already type. Alex can overrule.

### An event

Every event, from the app or from any provider, has the same envelope. It is the
[CloudEvents 1.0](https://cloudevents.io) JSON format, with two extensions. We take the
format, and its official Go SDK where it fits (`github.com/cloudevents/sdk-go/v2`,
Apache-2.0), as AGENTS.md "Libraries before our own code" asks.

```json
{
  "specversion": "1.0",
  "id":       "github:pr:alexec/agents#4702@pr.merged",
  "type":     "pr.merged",
  "provider": "github",
  "topic":    "alexec/agents",
  "subject":  "github:pr:alexec/agents#4702",
  "source":   "github:alexec/agents",
  "time":     "2026-11-11T17:02:11Z",
  "producer": "agents:machine:#mac-mini",
  "data":     { "fixes": ["#4682"], "sha": "36a5616" }
}
```

| Field | What it is |
| --- | --- |
| `id` | **The event's ref**: the subject's ref, `@`, the type, and when the thing can have the same type of event again, `/` and the provider's key for this one: `…#4702@pr.commented/IC_kwDO…`, `…#4702@checks.passed/36a5616`. |
| `type` | The name we have now: `noun.verbed`. |
| `provider` | Who it is about: `github`, `jira`, `slack`, … The app's own events are `agents`. |
| `topic` | The provider's space: a repo's full name, a Jira project, a Slack channel. Table below. |
| `subject` | The ref of the thing it happened to. |
| `source` | `provider:topic`, as CloudEvents asks for one. |
| `producer` | The machine (or control plane copy) that first put it on the bus. Not part of its identity. |
| `data` | What it carries now (the `payloadSchema`), at most 256 KB, as now. |

**Two machines make the same `id`** for the same happening, because the id comes from the
provider's data, never from the machine or the clock. That is what lets the bus drop the
second copy.

### Topics

| Provider | Topic | Example |
| --- | --- | --- |
| `github`, `gitlab`, `forgejo`, `bitbucket` | the repo's full name | `alexec/agents` |
| `azuredevops` | organisation/project/repo | `contoso/web/site` |
| `jira`, `azureboards` | the project key | `abc` |
| `linear` | the team key | `eng` |
| `slack` | workspace/channel id | `t01abc/c02def` |
| `googlechat` | the space | `spaces/aaaa` |
| `whatsapp` | the business number | `+15550100` |
| `email` | the mailbox | `alex@example.com` |
| `sentry` | org/project | `alexec/agents-mac` |
| `betterstack` | the team | `agents` |
| `agents` (`agent.*`, `workflow.*`, `request.*`) | the project | `alexec/agents` |
| `agents` (`machine.*`, `mac.*`, `person.*`, `lease.*`) | the machine | `mac-mini` |

## The bus

```mermaid
flowchart LR
  subgraph M1[Machine A: Mac]
    P1[Producers<br/>agentsd raise<br/>MCP poll: github alexec/agents]
    O1[(events.jsonl<br/>outbox + local log)]
    C1[Consumers<br/>wait_for_event<br/>workflow on:]
    P1 --> O1
  end
  subgraph M2[Machine B: Linux server]
    P2[Producers<br/>MCP poll: jira ABC<br/>(standby: github alexec/agents)]
    O2[(events.jsonl)]
    C2[Consumers]
    P2 --> O2
  end
  subgraph CP[Control plane, 1..n copies]
    IN[Publish]
    DD{Seen this id?<br/>create-if-absent<br/>in the bucket}
    DB[Debounce<br/>per subscription]
    SUB[(Subscriptions<br/>provider, type, topic,<br/>filters, owner)]
    PL[(Producer leases<br/>provider + topic)]
    LOG[(Bus log<br/>last 100k envelopes)]
    IN --> DD -->|new| LOG --> DB --> OUT[Deliver]
    DD -->|seen| DROP[drop, count]
    SUB --> DB
  end
  WH[Webhooks<br/>hosted only, later] --> IN
  O1 -- control link --> IN
  O2 -- control link --> IN
  OUT -- control link --> C1
  OUT -- control link --> C2
  PL -. who polls .- P1
  PL -. who polls .- P2
```

### Delivery is best effort (Alex, 2026-11-11)

The bus makes no promise. It is fast and simple, and the consumer makes up the rest.

- **Usually once; sometimes never; rarely twice.** A rare duplicate can still reach a consumer (two
  control-plane copies racing, a resend after a lost acknowledgement). Debounce is best
  effort too.
- **No backfill.** An event that is not delivered when it happens is never delivered: a
  machine that was asleep, offline or restarting misses it. An outage of the control plane
  means no delivery for its length.
- **So every consumer is idempotent and reconciles.** A workflow or a woken agent treats
  an event as a hint, not as the truth: it reads the thing's state now (the PR, the issue,
  the session) by the event's `subject` ref, and doing it twice does no harm. Every wait
  already has a time limit; when it times out, the agent reconciles (asks the provider
  for the state now) instead of taking "no event" as "nothing happened". The Brief and
  the tools' descriptions say so.

### The steps

1. **A producer raises an event on its machine.** agentsd's own events and each MCP
   subscription's polled events get the envelope, go into `events.jsonl` as now (it is the
   machine's log), and are sent on the control link. When the link is down, the event is
   not sent later (no backfill); it stays in the machine's own log.
2. **The control plane drops copies by `id`, as best it can.** The first copy of an id is
   kept; a later copy from another machine is dropped and counted. With several
   control-plane copies behind the load balancer, the check is a create-if-absent write of
   the id in the shared bucket. The seen ids are the bus log's ids (below).
3. **It matches subscriptions.** A subscription is a wait or a workflow trigger, sent to
   the control plane when it is made: `provider`, `type` (a name or `noun.*`), `topic`
   (one, a list, or none for all of the bus), `subject`, the provider's filters, and the
   owner (session or workflow, machine). The control plane matches on the envelope fields
   only; the provider's own filters are matched on the producing side, as now (the server
   checks them), and travel with the subscription to whoever polls.
4. **It debounces per subscription, when asked, as best it can.** `debounce: 30s` on a
   wait or trigger holds events for the same `subject` and `type` for about 30 seconds and
   delivers the last one, with `count`. Without it, every event is delivered.
5. **It delivers on the control link** to the machine that owns each matching
   subscription, at once. The machine runs the workflow or wakes the wait, as now, and
   records the event in its own log. A machine that is not connected misses it.
6. **Producers are distributed by lease.** For each `provider` + `topic` that some
   subscription needs, the control plane gives a producer lease to one machine that has
   that provider's server and can see that topic. That machine polls; the others stand by.
   The lease is short (5 minutes, renewed with each poll); when the machine sleeps or goes
   offline, the next machine takes it and polls from now (no backfill). An overlap (two
   machines poll for a moment, or a webhook and a poll) is harmless: dedupe drops most
   copies, and consumers are idempotent for the rest.

### Who is on a bus

**A bus is one person's today:** each person's machines, sessions and workflows share
one bus, and nobody else's. Anyone who can reach a bus can subscribe to any event on it.
When teams come, a team gets a bus that its members share; nothing in the envelope
changes.

### The bus log

The control plane keeps the **last 100,000 envelopes per bus**, a limit on count only, with
no time limit. It is for dedupe and for the Events page, not for redelivery.

### The single-Mac shape

The Mac download runs the control plane on the Mac (principle 1's exception). The bus is
the same code with one producer and one consumer, and nothing leaves the Mac.

### What the control plane keeps (principles 6 and 7)

Envelope fields are routing data: refs, names, times. `data` can be a customer's words (a
Slack message, a PR comment).

**The control plane cannot read `data`** (Alex, 2026-11-11). `data` is sealed to the
person's machines (the same sealing as secrets, #3401); the control plane routes and
dedupes on the envelope only. The bus log keeps the envelope and the sealed `data`.

## Where agents and people use it

- **`wait_for_event`** and a workflow's **`on:`** take `provider`, `type` and `topic`:

  ```yaml
  on:
    - type: pr.merged
      provider: github
      topic: alexec/agents
    - type: issue.created
      provider: jira
      topic: abc
      debounce: 30s
  ```

  **`type` is the word everywhere** (Alex, 2026-11-11): the docs, the tools and the
  workflow files say `type`, not "event name"; `name` is read as an alias for one release.
  `server:` stays as an alias for one MCP server by its `mcp.json` name. A bare type with
  no `provider` keeps meaning what it means now (this folder's servers and the app).
- **A wait can name a ref** (`subject: github:pr:alexec/agents#4702`) instead of the
  provider's own filters (`pr: 4702`), the plain way to say "this thing".
- **Every event shows its ref** in a woken agent's message, a workflow's prompt and the
  Events page, and an agent can pass that ref to any tool that takes one. The message
  says the event is a hint: read the subject's state now before acting on it.
- **The Events page** (Mac + web) gets columns for provider and topic, and filters by
  provider, type and topic. It reads the bus log, not one machine's log, so a person sees
  one list.

## Clients

- **Mac:** Events page columns and filters; the workflow editor takes the new keys.
- **web:** the same (Mac + web tier, as the Events page is).
- **Remote:** tier mac+web; no change.
- **Daemon, control plane, wire:** most of the work.

## Decisions (Alex, 2026-11-11; spike #4726)

- **Delivery, dedupe and debounce are best effort.** No backfill; an outage means no
  delivery. Consumers are idempotent and reconcile after a timeout.
- **1. `data`:** the control plane cannot read it; sealed to the person's machines.
- **2. Who subscribes:** anyone who can reach the bus. Today a bus is one person's; teams
  later.
- **3. Bus log:** a limit on size only, 100,000 envelopes per bus to start.
- **4. Webhooks:** later, in an epic of their own. The envelope is made so that a webhook
  copy and a polled copy share an id.
- **5. `type`:** yes, everywhere, `name` as an alias for one release.

## Slices (the epic's sub-issues hold the order)

1. Spike: settle the open questions with Alex (done, above).
2. Task: the `Ref` type on the wire, its parser and formatter; lineage writes it.
3. Task: the event envelope on every event (`id` as a ref, `type`, `provider`, `topic`,
   `subject`); the providers' servers give the keys for the id.
4. Task: the bus on the control plane: publish, dedupe, bus log, deliver (best effort).
5. Task: subscriptions by provider, type, topic and subject, and `debounce`, in
   `wait_for_event` and workflow `on:`; consumers told to reconcile.
6. Task: producer leases: one machine polls each provider + topic, with failover.
7. Story: the Events page reads the bus and filters by provider, type and topic (Mac + web).
