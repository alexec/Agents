# Quickstart: Read Another Session's History

Use a scratch root and fake runtimes; do not use a real account or spend provider credit.

## Session history

1. Create two sessions in one project with distinct titles. Include a user request, an agent
   reply, a tool call with a file path and a plan update in the source session.
2. From the second session, call `list_sessions` and check both sessions are listed with their
   ids, runtime names, status and last activity. Confirm `lastSaid` is omitted when unavailable.
3. Call `read_session` by the source id, then by its exact title. Confirm the readable history
   contains the request, reply, tool activity and last plan.
4. Compare the source agent record, transcript, activity time and status before and after the
   read; all remain unchanged.
5. Check duplicate titles return the match list, unknown titles return the not-found sentence,
   retired sessions return the gone sentence, and another project's id is indistinguishable
   from a missing id.
6. Repeat from a helper agent. It can list and read the same project but cannot name another
   project.
7. Build a history over 80,000 characters. Check the first request and plan remain, newest
   complete turns are retained, and the omission count is correct.

## Allowance ending

1. Have a fake runtime return a recognized spent-allowance result during a turn.
2. Check the chat stays on the same runtime, receives the allowance note and **Its allowance
   ran out** status, and has no pending carry or allowance wait.
3. Start or prompt a second chat on the same runtime; it is not blocked or marked out.
4. Return a short rate limit and check the same chat retries on the same runtime according to
   the existing delay policy.

## Compatibility and removal

1. Open a transcript containing old pool-switch, handoff and settings-changed entries; all
   entries still decode and draw.
2. Open an agent record containing legacy pool fields and an allowance wait. It decodes, the
   wait is cleared without starting a turn, and the standalone blocked-chat **Carry on** remains.
3. On Mac, iPhone and iPad, confirm the Pool page, Pool settings, Continue with, Matching
   models and allowance-wait status are absent.
