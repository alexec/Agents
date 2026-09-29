# Validate feature 064

Record the commands, results and any live check that could not run at the end of this file.

## 1. Automated

1. Run `swift test --package-path Packages/AgentsKit --filter Sandbox`. It covers:
   - settings persistence and a corrupt file
   - catalog args and env per choice
   - classification against `Fixtures/sandbox-failures/`
   - draft reuse
   - Codex mode coupling
   - the helper cap
   - recovery re-send and the continuation-after-tools case
2. Run the ClientPermission, ToolPolicy, PoolSwitch and ContinueWith suites, then the full suite. The suite is flaky under load; compare several runs against main before blaming the branch.
3. Build both Xcode schemes and the Linux gate. Run `scripts/docs.sh check`.

## 2. Routes (research R9)

There is no probe in the app (Alex, 2026-09-29). Re-measure a route with
`scripts/sandbox-probe.sh <runtime> <label> [--arg …] [--env …] [--meta …] [--mode …]`
whenever a runtime changes, and compare with research R9. Copilot's `--sandbox` and
`--no-sandbox` are to be measured once its quota resets.

## 3. Mac, on a scratch app (run-app skill)

1. **Settings ▸ Agent Runtimes**:
   - Every runtime shows **Command sandbox** set to **As configured by runtime**, with its explanation.
   - Cursor and Copilot show **Runtime controlled**, Antigravity and OpenCode **No sandbox**, each with why; Gemini has no **On**.
   - Codex's Off says approval prompts turn off too.
2. **Grok default Off**:
   - Start a Grok agent. The launch in `daemon.log` has `--sandbox off`.
   - The header shows **Sandbox Off** before the first command.
   - A Cursor agent started next is unaffected.
3. **Codex default Off**:
   - A new Codex agent starts in **Full access**.
   - Choose **Ask for approval** on it. Its override becomes On and the runtime default is unchanged.
   - Choose Sandbox On from Full access. The mode becomes **Ask for approval** and the note says prompts return.
4. **Inheritance**:
   - A workflow-started agent and an agent-started helper both follow the default.
   - A helper started by a sandboxed Codex agent stays sandboxed and gives the "limited by the agent that started it" reason.
5. **Mid-turn change**:
   - Change the override while a turn runs. The UI says it applies from the next turn.
   - The next turn's launch shows the new flag.
6. **Scope and policy unchanged (SC-007)**: with the sandbox Off, reach outside the project folder and use an app-controlled tool. Folder scope and existing approvals still refuse or ask as before.

## 4. Failure and recovery

1. **Induce a failure**: on the devbox, induce Codex's sandbox startup failure. Alternatively, use a fixture through the fake launcher on the Mac.
2. **The card**:
   - It names Codex and the sandbox, and has error details.
   - The agent is stopped.
   - Nothing is re-sent after waiting a minute (SC-009).
3. **Keep stopped**: the agent stays stopped.
4. **Continue without sandbox**:
   - Repeat the failure, then choose **Continue without sandbox**.
   - The override becomes Off, the mode Full access, and the original task resumes without retyping. That is at most three actions (SC-005).
5. **No recovery without an Off route**: a runtime with no Off route shows the card with the reason and no Continue button.
6. **Ordinary denial**: an ordinary command denied inside a working Grok or Cursor sandbox shows a normal tool failure and no card (SC-004).
7. **New agent**: if the failure happens at `session/new` of a new agent, the form keeps the prompt and **Start without sandbox** works.

## 5. Remote and servers

1. **Remote**: build for the generic simulator only. The start form Sandbox row, the header capsule and the card are in the build. The look on the iPhone and iPad is Alex's to judge.
2. **Servers**: change a default on the Mac. It reaches the devbox daemon, and again after a reconnect. The devbox shows its own capability.

## 6. Clean up

Stop scratch processes by pid, then remove the scratch roots and fixtures copied outside the repo.

## Results

_Not run yet._
