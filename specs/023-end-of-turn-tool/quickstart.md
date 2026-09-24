# Quickstart: proving One Call to End a Turn works

Seven checks. The first three are the feature; the fourth is the promise to conversations already
under way; the fifth is the briefing; the sixth is the only one that proves a real runtime will do
it; the seventh is by eye.

## Prerequisites

```bash
swift build --package-path Packages/AgentsKit
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
```

Three lanes share this tree. If the package does not build, `git worktree add --detach /tmp/023
HEAD`, copy the feature's files in, and run there.

## 1. The tool is offered, shaped right, and refuses in sentences

```bash
swift test --package-path Packages/AgentsKit --filter AppServiceTests
```

- `tools/list` returns five tools, `finish_turn` first, the two aliases last.
- `finish_turn`'s schema has the five-value enum, requires `outcome` and `message` only, and
  `next_prompts` items require `label` and `prompt`.
- An unknown outcome word is refused naming the five; an empty message is refused; a prefixed name
  reaches the same sink; more than four prompts become four; an empty prompt is dropped.
- Both aliases still reach their own sinks with their own arguments.

## 2. One call lands both halves, or neither

```bash
swift test --package-path Packages/AgentsKit --filter FinishTurnTests
```

Against the daemon over the real socket:

- One call with `done`, a message and two prompts → `report` set, two `suggestedPrompts`, one
  `agent/changed`, the `.workReported` entry at the foot of the transcript (FR-001, FR-004).
- The same with no prompts → report set, chips empty (FR-003).
- A call while a permission is pending → refused; `report` nil and chips unchanged (FR-005).
- Two calls in one turn, the second with no prompts → second report stands, chips empty (FR-008).
- The person prompts → both cleared (FR-009).
- The reply carries the outcome sentence then the chips sentence (FR-007).

## 3. The call is the app's own

```bash
swift test --package-path Packages/AgentsKit --filter 'TranscriptDisplayTests|PermissionRequest'
```

- A `finish_turn` tool call, prefixed or not, is not drawn in the transcript.
- `isTheApps` and `isAutoAllowable` are true for it, so Copilot's permission question is answered by
  the app.

## 4. A conversation briefed with the old names keeps working

```bash
swift test --package-path Packages/AgentsKit --filter 'FinishTurnTests/alias|SuggestedPromptTests|OutcomeReportTests'
```

- `SuggestedPromptTests` and `OutcomeReportTests` pass with no expectation changed (SC-007).
- In `FinishTurnTests`: the two old names in either order leave the agent in the same state as one
  new call with the same values; each alone touches only its half; an alias after the new call
  replaces only its half (FR-012, SC-006).
- The app's ask names `finish_turn`, and answering it with `report_outcome` still accounts for the
  ending (FR-018).

## 5. The briefing is one line shorter and names the tool

```bash
swift test --package-path Packages/AgentsKit --filter 'BriefingTests|ToolPolicyTests'
```

- Five lines at most, under 1,500 characters, for every built-in policy (SC-003).
- The first line contains `finish_turn` and neither old name (FR-015, FR-016).
- `RemitCategory.suggestions.instead` names `finish_turn` (FR-017).

## 6. The runtimes actually call it

```bash
AGENTS_LIVE=1 AGENTS_MCP_HELPER="$(xcodebuild -scheme Agents -showBuildSettings 2>/dev/null \
  | awk '/BUILT_PRODUCTS_DIR/ {print $3}')/Agents.app/Contents/MacOS/agentsd" \
  swift test --package-path Packages/AgentsKit --filter FinishTurnLiveTests
```

One turn per signed-in runtime. Record, per runtime: whether the turn ended with `finish_turn`, the
outcome, and how many prompts came with it. Write the numbers into `research.md` R10 beside 014's
R11. SC-004 holds if the share of normal endings that are accounted for is not below 014's number
for that runtime. A runtime that will not call it is a finding, not a failure of the design.

## 7. By eye

Launch the app (`env -i … open`, per memory) and run one short turn on Claude. Expect: chips above
the prompt, the row reading the agent's sentence, no tool-call line for `finish_turn` in the
transcript, and no "Finished without saying how it went".
