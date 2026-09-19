# Research: Complete ACP coverage

**Date**: 2026-09-18. Every claim below was proved by handshake or by a real turn against the
runtimes installed on this Mac, not by reading documentation. Raw captures were taken with a probe
client that answers every request an agent can make.

Versions: protocol version 1, schema from `@agentclientprotocol/sdk` 1.4.0. Claude adapter
`@agentclientprotocol/claude-agent-acp` 0.78.0, Copilot 1.0.86, Grok 1.0.34.

## 1. What the app advertises changes what the agent does

The probe ran the same turn twice against each runtime: once with the capabilities the app sends
today (no file access, no terminal), once with everything.

| Runtime | Client requests when we advertise nothing | Client requests when we advertise everything |
|---|---|---|
| Claude adapter | none | none |
| Copilot | permission only | permission only |
| Grok | none | `fs/read_text_file` (3), `fs/write_text_file` (1), `terminal/create`, `terminal/wait_for_exit`, `terminal/output`, `terminal/release` |

**Decision**: serve the file and terminal methods, and advertise them.

**Rationale**: Grok changes behaviour on the strength of the flag. With it off, Grok edits files
behind our back; with it on, every read and every write comes through us, which is the app being
able to show what an agent touched at the moment it touches it. This is the evidence the 001
decision lacked, and it is why User Story 8 was approved.

**Consequence worth stating**: advertising the capability is a promise. A runtime that takes us up
on it and gets a wrong answer has no fallback, so these methods have to work before the flag is
turned on. They go in behind the flag, tested against a fake agent, and the flag flips last.

**Alternatives considered**: advertise reads but not writes (Grok would then split its work across
two mechanisms for no gain); keep it off (rejected by the spec).

## 2. Diffs are real, and not every runtime sends them

Asked to change a word in a file, each runtime reported it differently.

| Runtime | How the edit arrived |
|---|---|
| Copilot | `tool_call_update` carrying `content: [{type: "diff", path, oldText, newText}]` |
| Grok | the same, plus `_meta` with line numbers, and a second diff for the same edit |
| Claude adapter | it ran `sed` and reported `content: [{type: "content", ...}]` holding a fenced console block |

**Decision**: render `diff` blocks as a before-and-after with the path, render `content` blocks as
content, and render a `terminal` block from the terminal we are running for that agent.

**Rationale**: two of three send structured diffs today. The third sends text, which the markdown
renderer built in 002 already draws. Nothing is invented for the runtime that does not participate:
it keeps the display it has now.

## 3. Usage is already arriving, several times a turn

Claude adapter, one short turn: seven `usage_update` notifications, each `{used, size}` against a
1,000,000 token window, the last one carrying `cost: {amount: 0.244, currency: "USD"}`. The
`session/prompt` response carried a separate `usage` object with input, output, cached read and
cached write tokens. Copilot sent four usage updates in its turn. Grok sent none.

**Decision**: the context meter is driven by `usage_update` (`used` over `size`); the per-turn
record is the `usage` on the prompt response; cost is shown only where the runtime sends it.

**Rationale**: they are different facts. `used/size` is how close the agent is to trouble and moves
during a turn. The prompt response is what that turn actually consumed. A runtime that sends
neither shows neither, rather than showing zero.

## 4. Boolean options exist, but only if you ask for them

The Claude adapter's `fast` setting arrives as a two-choice select when we advertise nothing, and as
`type: "boolean"` when we advertise `session.configOptions.boolean`. Same runtime, same session, one
flag apart.

**Decision**: advertise the boolean capability and render a switch.

**Rationale**: the runtime is already choosing to degrade for us. A setting that is on or off should
look like one, and a runtime with a boolean-only setting would otherwise show nothing at all.

## 5. Grouped choices are a shape nobody sends yet, and would break the start

`SessionConfigSelectOptions` is either a list of options or a list of groups, where a group has
`group`, `name` and its own `options` and no `value`. None of the three sends groups today: Copilot
sends 18 models flat. Our decoder requires `value` on every entry, and the failure is not contained,
because the options list is decoded as part of the `session/new` result, so the whole start fails.

**Decision**: decode options leniently. A group flattens into its choices with the group's name as a
heading; an entry that is neither is dropped; a failure anywhere in the list costs that one option
and never the session.

**Rationale**: this is the one gap in the audit that can lose an agent rather than a feature, and it
turns on a runtime shipping a shape the protocol already allows.

## 6. Images and file references are accepted today

The Claude adapter accepted a prompt carrying a text block and an `image` block, and a prompt
carrying a `resource_link` to a file, answering both. `promptCapabilities` on this Mac:

| Runtime | image | audio | embeddedContext |
|---|---|---|---|
| Claude adapter | yes | no | yes |
| Copilot | yes | no | yes |
| Grok | no | no | yes |

**Decision**: the composer offers an attachment when the runtime's capabilities allow it, and says
why when they do not. Resource links need no capability: they are baseline.

## 7. Session housekeeping works and returns more than we use

Against the Claude adapter in one folder: `session/list` returned both sessions with `sessionId`,
`cwd`, a title the runtime wrote itself, and `updatedAt`. `session/fork` returned a new session id.
`session/delete` succeeded and removed it.

**Decision**: adopt from the list, fork into a second agent, delete on explicit request with a
confirmation. Archive stays local.

**Rationale**: the runtime's list is the only way to find work started elsewhere. Delete is the
only irreversible thing in this feature, which is why it is the only one behind a confirmation.

## 8. Still not proved: the signed-out failure

Carried over from 001 (task T085). No runtime on this Mac is signed out, so the error a runtime
returns when it needs authentication has still not been seen. The protocol reserves `-32000` for it
and the SDK names it `authRequired`.

**Decision**: map `-32000` from any session method to "needs signing in", show the runtime's own
auth methods, and keep the existing behaviour for every other code. Prove it during implementation
by signing a runtime out deliberately rather than by guessing.

## 9. Nobody asks for elicitation yet

No runtime sent an elicitation request in any probe, with the capability advertised. It is in scope
because the cost of being wrong is an agent that stops working on a day we are not watching, and
because the form shapes are small and fully described by the schema.

**Decision**: implement it, drive it from a fake agent in tests, and advertise it. No runtime
behaviour changes on this Mac today.

## 10. Plans did not arrive in these turns

Neither the Claude adapter nor Copilot sent a `plan` update for the work the probe asked for, which
was too small to plan. 001 recorded plans arriving from real work, and the entry kind is already
stored. `plan_update` and `plan_removed` are gated behind a client capability we have never
advertised, so they cannot have arrived.

**Decision**: advertise the plan capability, render entries with their state, and apply updates to
the plan already on screen. Test with a fake agent; confirm against a real one during implementation
on a task large enough to plan.

## 11. Two things in the schema that our code silently loses

Both found by reading, both confirmed in captures.

- A tool call reports `rawInput` when it starts and `rawOutput` when it finishes. Our merge replaces
  the whole raw blob, so expanding a finished call no longer shows what it was called with.
- Content that is not text (an image in a reply) is turned into an empty string by the chunk reader,
  so it draws as an empty line.

**Decision**: merge field by field, and model content as blocks rather than as a joined string.

## Out of scope, with the evidence

- `nes/*` and `document/did*`: no runtime advertises them. They describe an editor watching a buffer.
- `mcp/connect`, `mcp/message`, `mcp/disconnect`: no runtime asked. All three take MCP servers as
  configuration on `session/new` instead, which is what we will send.
- `$/cancel_request`: no runtime requires it. We cancel turns.
- Vendor `_meta`: Grok's `x.ai/hooks`, `x.ai/capabilities` and `x.ai/fs_notify`, the Claude adapter's
  `jetbrains`, `steering` and `goal`, Copilot's `copilotUsage` and `terminal-auth`. One exception,
  unchanged from 001: `terminal-auth`, because it names the exact command that fixes a signed-out
  runtime and inventing that advice ourselves would be worse.
