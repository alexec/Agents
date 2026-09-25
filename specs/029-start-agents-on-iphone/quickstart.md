# Quickstart: proving 029 works

Four levels, cheapest first. Each says who can run it. What an agent can run, an agent runs
before handing anything to Alex (memory: the run-app skill is how to test a change).

## 1. Unit tests (agent)

```sh
cd Packages/AgentsKit && swift test
```

New tests must cover, without mutating source to prove them:

- `StartRequest` and `Agent` decode without the new fields (records from before this feature).
- A repeated `requestID` returns the first agent and starts nothing, including while the first
  call is still in flight, and after reloading the agent store.
- A refused start records nothing against its `requestID`.
- Mode memory: written on start and on a mode `setOption`, not on a model `setOption`;
  `modes/import` fills gaps only; an undecodable entry is absent and survives in the file.
- `agents/discardDraft` ends the draft's session; discarding an unknown draft is not an error.
- A draft whose connection went is ended after the grace period and not before.
- `AgentsModel.defaultRuntimeID` picks the same runtime the Mac's did for the same agents.

The suite is broadly flaky under load (memory); compare runs on `main` before blaming this branch.

## 2. The daemon by hand (agent)

On a scratch root (`run-app` skill), over `daemon.sock`:

1. `agents/options` for a real runtime and folder, then `agents/start` with a `requestID`, then
   the same `agents/start` again: one agent, same id twice.
2. `agents/options`, then `agents/discardDraft`: the runtime process is gone
   (`pgrep -P <agentsd pid>`).
3. `agents/options`, then close the socket: the process is gone after about 30 s, not before.
4. `agents/start` with `startOptions.values.mode = "plan"`, then `modes/remembered`: `plan` for
   that runtime, and a `modes/changed` notification arrived on a second connection.
5. Set `prompt.mode.<runtime>` in the scratch app's defaults, launch the scratch app, then
   `modes/remembered`: imported. Launch it again after changing the daemon's value: not
   overwritten.

## 3. The Mac, unchanged for the person (agent)

Launch the scratch Mac app, start an agent with a mode chosen, open a new start form: the same
mode is offered first, as before this feature. Screenshot it.

## 4. The phone's screen (agent screenshots; Alex walks)

Build the Remote for the simulator, launched with the DEBUG arguments
`-project <name> -start` (the new `-start` flag opens the start sheet on that project), against
a scratch daemon's direct link. Screenshot at default text size and at the largest Dynamic Type
size, keyboard up. There is no Simulator GUI on this Mac, so nothing can be tapped here
(memory).

**Alex, on a real iPhone** (SC-006), same network as the Mac:

1. Project page → New agent → type a line → Send. The conversation opens; the agent is on the
   Mac in the same project.
2. Change runtime and mode, start; then open New agent on the Mac: the same mode is offered.
3. Attach a photo and start; the agent sees it. Choose a runtime that does not take pictures:
   refused before sending, photo kept.
4. Type a prompt, Cancel, reopen: the prompt is there.
5. Turn on airplane mode, Send: refused, prompt kept. Turn it off mid-send: exactly one agent.
6. Largest Dynamic Type: every control reachable with the keyboard up and down.

**Not yet possible**: the spec's cellular test and SC-002's mobile timing need the relayed link
(013 Track A, Alex's). Record them as waiting on it, not as passed.
