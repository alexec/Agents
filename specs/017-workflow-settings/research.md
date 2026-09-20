# Phase 0: Research

Six decisions. Each was a real fork, and five of them were settled by reading what this codebase
already does rather than by preference.

---

## 1. Where a permission mode comes from, and what it is

**Decision**: A permission mode is whatever the runtime advertises as its mode option. The workflow
file carries the runtime's own value as a string; nothing in this app defines, validates against, or
translates a vocabulary of modes.

**Rationale**: `ConfigOption` is already the whole of the start form — "All three runtimes advertise
their models, their modes and their effort levels through this one list, in this one shape." The
mode is found by `category == "mode"`, falling back to `id == "mode"`, and `ModeMemory.modeOption`
already does exactly that lookup with a unit test (`theModeIsFoundByCategoryNotByName`) holding the
precedence. Reusing it means the workflow and the prompt bar cannot come to disagree about which
advertised option is *the* mode.

`ConfigOption.isAboutPermission` is the existing statement of which options change what an agent may
do to a folder: `category == "mode" || category == "permissions"`. That comment is worth quoting
because it already names the asymmetry this feature is built on — permission "is the one that
changes what an agent can do to a folder, and the others only change how well it does it."

**Alternatives considered**:

- *An enum of modes this app owns, mapped per runtime.* Rejected: it puts this app in the business
  of asserting that Claude's plan mode and Copilot's are the same promise, which nobody can support,
  and it breaks the README's rule that no code asks which runtime it is talking to.
- *Accepting the choice's display name as well as its value.* Rejected for now: it makes a file's
  meaning depend on a label a runtime may localise or reword. The refusal message names the values
  that *are* offered, which is the better answer to a typo.

---

## 2. Why `ACPSession.apply` is left exactly as it is

**Decision**: Do not make `apply` strict. The workflow path validates before an agent exists.

**Rationale**: The comment on `apply` is correct for the case it was written for:

> One option a runtime has since stopped offering must not stop an agent starting, so a refusal
> here is noted and passed over.

A person has the control in front of them. If the runtime dropped their preferred model, losing the
agent is worse than losing the preference, and `ModeMemory` M2 already says the same thing about a
remembered mode: discard it silently.

An unattended workflow inverts every term. Nobody sees the control, nobody notices the silence, and
the setting being dropped is the one that says *do not change files*. The fallback is always in the
permissive direction. So the difference is not that workflows want stricter plumbing; it is that
they are a different question, and the answer belongs on their side of the line.

**How the check is actually made**: `DaemonCore.options` already shows the shape — make a session,
register it as a `Draft`, hand the draft id out, and let `start` reuse that same session. The
workflow path does the same thing without the caching: make the session, read `await session.options`
(populated from `session/new`), resolve, and either hand the draft id to `start` or end the draft and
record a refusal. No extra process is spawned: the session made here is the session `start` would
have made.

**Alternatives considered**:

- *Make `apply` return its failures and let callers decide.* Rejected as the first move — it changes
  a function every start goes through in order to serve one caller, and the decision the workflow
  needs (refuse the whole fire) cannot be taken at that point anyway, because by then the agent
  exists and is saved.
- *Validate against `OptionCache`.* Rejected outright, and it is worth saying why loudly: the cache
  is explicitly "what a runtime last said it offers", shown while the real answer is fetched. A
  stale entry claiming plan mode is available is precisely the failure FR-008 exists to prevent. The
  cache is good enough to populate a menu, which is what FR-023 and FR-024 use it for, and not good
  enough to decide whether an unattended agent may edit files.
- *Check after starting and stop the agent.* Rejected: the agent has been created, saved, broadcast
  and briefed by then. A refusal that leaves an agent behind is not a refusal.

---

## 3. Writing one key back without disturbing the file

**Decision**: A textual front-matter editor. It works on the lines between the opening `---` and its
closing fence, changes or inserts one top-level key, and refuses anything it cannot do safely.

**Rationale**: FR-022 is the requirement, and it is not fussiness — the workflow file is a file a
person wrote and will read again in a diff. `YAMLNode` is a deliberate subset reader with no writer,
and giving it one means deciding how to re-emit block sequences, inline sequences, quoting and
comments for every file anybody has already written. The first pull request where the app reflowed
somebody's `on:` block to change `permission-mode:` is the last time they let it near their
repository.

Textual editing is smaller *and* safer here because the target is always a top-level scalar. The
rules are stated in [contracts/front-matter-edit.md](./contracts/front-matter-edit.md); the ones that
matter are that only column-zero keys are considered (so a `model:` nested under a trigger is not
touched), a trailing comment on the line survives, and a key being added goes immediately before the
closing fence.

**Alternatives considered**:

- *Parse to `YAMLNode` and re-serialise.* Rejected above.
- *Append the key at the end of the file.* Not a real option — front matter is fenced — but worth
  recording that "somewhere in the block" is not good enough either: a key inserted in the middle of
  a block sequence changes what it belongs to.

---

## 4. Where a changed setting lives

**Decision**: In the file. Nothing joins `WorkflowState`.

**Rationale**: This was the clarification asked of the reader and answered *written into the file*.
It is also the answer that keeps the existing division honest. 008 is explicit that archived and the
standing agent are held by the app because "writing them to disk would put the app's own bookkeeping
into the repository's history, where nobody wants to review it." A permission mode is the opposite
kind of fact: it is exactly what somebody should review, and it is about the workflow rather than
about this machine's opinion of it.

It also removes a whole class of bug before it exists. With one source of truth there is no question
of which wins, no row that has to say the file and the app disagree, and no state to migrate.

**Consequence**: 008's FR-032 — "The project page MUST NOT offer editing a workflow's trigger or
body" — is amended by 017's FR-021 rather than contradicted. Triggers and the body stay
unchangeable from the page. This plan does not edit 008's spec; the amendment is stated in 017 and
cross-referenced, the way FR-024/FR-031a and FR-035 are handled inside 008 itself.

---

## 5. What a `triggering` workflow's settings mean

**Decision**: Nothing. Settings apply when a workflow *starts* an agent. A `triggering` workflow
never does, so its settings are inert — and, critically, `Workflow.summary` must not mention them.

**Rationale**: FR-011. The agent a `triggering` workflow resumes is very often one a person is
sitting in front of, and reaching into it to change what it is allowed to do is a worse outcome than
the workflow not applying a setting. 008 already refuses to substitute an agent in this mode for the
same class of reason: "substituting would send words meant for one conversation into another."

The summary point is not cosmetic. `Workflow.summary` is read by the project-page row *and* by the
reply an agent gets after writing a workflow. A row saying "in plan mode" about a workflow that will
never apply plan mode is a false statement in the one place this feature exists to make true. So the
clause is conditional on the mode, and the workflow page says the longer version — that these
settings do not apply to a workflow that resumes an existing agent.

`standing` is different and does not need special handling: its first fire starts an agent, and so
does any fire that has to replace one that has gone. Settings apply on exactly those.

---

## 6. How a workflow is opened

**Decision**: A second destination in the existing navigation stack. `model.selection: UUID?` is
left alone; a sibling `model.openWorkflow: Workflow.ID?` joins it, and the stack's path becomes a
`Page` of at most one, derived from whichever is set.

**Rationale**: `ContentView` already states the intent for a chat: "A chat is somewhere you go from
the project and come back out of, rather than a column sitting beside it, so it is a push and the
back button is the way home." A workflow is the same kind of thing, so it should be the same kind of
push.

`model.selection` is load-bearing in a way that is easy to underestimate — its `didSet` sets
`work.watching` and reloads the transcript, and it is threaded through the view tree as a binding in
some forty places. Widening it into an enum would touch all of them to serve one new destination. Two exclusive fields feeding one derived path
of at most one element costs one field and one binding, and every existing call site keeps working
unchanged.

**Alternatives considered**:

- *A sheet.* Rejected: modal, and it contradicts the reasoning already written into `ContentView`
  about what a destination is in this app.
- *Turning `selection` into `enum Page`.* The tidier end state, and the wrong first move: 46 call
  sites of churn, in a feature whose actual subject is permission modes.
- *Opening the raw file in `FilesPane`.* Rejected during specification — it is a pane that belongs
  to an agent's sidebar, and the settings would then have to be edited somewhere else anyway.

---

## Open questions

None. The three that could have blocked were put to the reader before the spec was written and are
recorded in its Clarifications section.
