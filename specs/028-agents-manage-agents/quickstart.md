# Quickstart: Checking That 028 Works

Everything here runs in the worktree `/tmp/w-028`. Nothing touches the shared checkout or the
real daemon.

## 1. Package tests

```sh
cd /tmp/w-028/Packages/AgentsKit && swift test
```

Expected to pass, including new tests covering:
- **State table**: `stoppedByAgent` and `archivedByAgent` accept and refuse exactly the rows their
  `…ByUser` twins do, and set `.stoppedByAgent` / `.byAgent` (data-model.md).
- **Limit**: with three helpers not archived, a fourth start is refused and names the three.
  After one is archived, a start succeeds. Four concurrent starts against an empty project end
  with exactly three agents (SC-002). Assert with a fake runtime whose handshake waits, so the
  starts really do overlap.
- **Scope**: stop and archive are refused for the caller itself, for an agent the person started,
  for one a workflow started and for one another agent started. None of them changes state (SC-003).
- **No reach outside the project**: the helper's `cwd` equals the caller's standardised `cwd`
  (SC-004). The request type has no folder field, so there is nothing to test beyond that.
- **One level**: a helper's `appServer` args include `--no-agent-tools`, both when started and when
  picked back up. Its calls are refused even if made anyway.
- **Restart**: after the daemon is rebuilt from the store, `startedByAgent` and the count are
  unchanged.
- **Briefing**: `Briefing.lines` includes the helpers line when `managesAgents` is true, and leaves
  it out otherwise.
- **AppService**: `tools/list` has the four tools by default and none of them with
  `managesAgents: false`.

## 2. Builds

Both schemes, one after the other, with plugin validation skipped
(see memory: xcodebuild needs plugin-validation skipped):

```sh
cd /tmp/w-028 && xcodegen generate
xcodebuild -scheme Agents -configuration Debug -skipPackagePluginValidation -skipMacroValidation build
xcodebuild -scheme Remote -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation build
```

## 3. End to end on a scratch daemon (run-app skill)

Use the `run-app` skill to launch the app built from `/tmp/w-028` on a scratch root, with a scratch
project folder.

1. Start an agent with the prompt: *"Start two agents with start_agent: one that lists the files
   here, one that counts them. Then call list_my_agents until both have finished, and archive both."*
2. Expect:
   - Two new rows in the project, each with the started-by mark. Hovering (or the AX label)
     reads "Started by ‹first agent's title›".
   - Each helper's chat opens with "Started by …".
   - When the first agent finishes, both helpers are archived and their transcripts end with
     "‹title› archived this agent."
   - Screenshot the project page with the helpers present and after they are archived.
3. Limit: prompt the first agent to start four agents. Expect three to start, and the fourth call
   to come back with the refusal naming the three. Archive one from the Mac's card menu, prompt
   again, and expect the start to succeed.
4. Scope: prompt the first agent to archive itself, and then to stop an agent you started by hand
   (give it the id from `agents/list` on the scratch socket). Expect both to be refused and
   nothing to change.
5. One level: open a helper and ask it to start an agent. Expect it to say it has no such tool, or
   that the call was refused.

Stop the scratch app when done (the run-app skill covers how). Never kill `agentsd` by name.

## 4. Phone

The phone can't be tapped on this Mac (memory: no Simulator GUI). Boot the Remote app against the
scratch root and screenshot the project list with a helper present, to show the mark. The walk
itself is Alex's.
