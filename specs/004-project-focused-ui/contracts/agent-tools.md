# Contract: the `project` MCP server

What a project lead is given, and what it may do with it. One MCP server over stdio, attached only to
agents whose role is `.lead`, spawned by the runtime as:

```text
agentsd mcp --agent <lead-uuid>
```

That process speaks MCP on its stdio and proxies each call to the daemon over the Unix socket. It
holds no state and decides nothing: every rule below is enforced in the daemon, where a test can
reach it.

## Before every call

Two things happen to every tool call, in this order:

1. **Scope check.** The call is refused unless it concerns the lead's own project. Refusals come back
   as a tool result the lead can read and act on, never as a transport error.
2. **Permission.** The daemon raises an ordinary `PermissionRequest` — the same one a tool call
   raises — and waits. The user answers allow once, allow always, or decline. "Always" is remembered
   per project and per tool, and is not asked again. A decline returns a refusal as the tool's result
   so the lead carries on rather than stalling.

`list_agents` and `read_transcript` are reads and are not held for permission; every tool that changes
something is. This is the rule 003 already set for files: a read is recorded, a change is asked.

Every call, allowed or declined, is written to the lead's transcript.

## Tools

### `list_agents`

**Takes**: nothing.

**Returns**: every agent in the project except the lead — id, title, state, when it was last active,
how it ended if it has, and its cost so far.

Read. Not held for permission.

### `start_agent`

**Takes**: `runtime` (optional, defaults to the lead's own), `instruction`, `title` (optional).

**Returns**: the new agent's id.

Always creates a `.worker`, in the project's folder, with no `project` server attached. A lead cannot
create another lead through this tool, and nothing else can create one either.

**Refuses**: a folder that is not there, a runtime that is not installed or not signed in — with the
same words the user would get.

### `prompt_agent`

**Takes**: `agent`, `text`.

**Returns**: acknowledgement that the prompt was queued.

Goes onto that agent's prompt queue, which already exists, so a prompt sent to a busy agent waits its
turn instead of being lost or jumping ahead of what the user typed.

**Refuses**: an agent in another project; an archived agent.

### `read_transcript`

**Takes**: `agent`, `limit` (optional), `before` (optional).

**Returns**: a page of that agent's transcript, newest last, the same shape `agents/transcript`
returns to the app.

Read. Not held for permission.

**Refuses**: an agent in another project.

### `stop_agent`

**Takes**: `agent`, `reason` (optional).

**Returns**: the agent's state after stopping.

Stops it exactly as the user stopping it would: the turn is cancelled, the runtime is released, the
state becomes `stopped`.

**Refuses**: the caller's own id — a lead cannot stop itself, that is the user's from its own
conversation; an agent in another project; an agent that has already settled, which is not an error,
just nothing to do, and the lead is told so.

## What is deliberately absent

- **No archive or unarchive.** Tidying is the user's (FR-038).
- **No tool that creates a lead.** Leads are created with their project and no other way.
- **No reach beyond the project.** There is no tool that names a project, so there is nothing to point
  at another one.
- **No lead-to-lead anything.** Leads do not coordinate each other.
- **No file or shell access of its own.** The lead is an agent: it already has its folder and whatever
  003 serves it, on the same terms as any agent.

## Refusal wording

Refusals are sentences the lead can act on, because the lead reads them and decides what to do next:

| Situation | What the lead is told |
|---|---|
| Another project's agent | "That agent is in another project. You can only work with agents in *<name>*." |
| User declined | "The user declined that. Ask them, or try something else." |
| Its own id to `stop_agent` | "You cannot stop yourself. Ask the user to stop you." |
| Agent already settled | "That agent already finished. Nothing to stop." |
| Folder gone | "<path> is not there any more." |
| Runtime missing | "<runtime> is not installed, or is not where we looked." |
