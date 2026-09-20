# Quickstart: One Grouping

What to check by hand once the tasks are done, and what each check proves. Everything else
is held by tests.

1. **The count is the list.** Open a project with agents in several states. The row's
   caption ("2 working · 1 complete", or "Needs attention") matches the rows under each
   heading in the panel. Have an agent show you a file and do not open it: the row says
   Needs attention and the panel lists that agent under it. Open the conversation: both
   move it out together (US1-1, US1-4, SC-002, SC-003).
2. **Stopped is not wanted.** With an agent that asked to be looked at, stop it. The row
   stops saying Needs attention and the agent is under Stopped (US2-1, US2-2).
3. **The app's question does not move anything.** Let a turn end without a report. Watch
   the panel through the question and its answer: the agent stays under Complete until
   the answer lands, then moves once or not at all (US3-1..3, SC-004).
4. **Prompting mid-question is work.** While the question is in flight, send a prompt. The
   agent moves to Working (US3-4).
5. **Mac and phone.** The same project on both: every agent under the same heading, except
   one whose file the Mac has been shown and has not opened — Needs attention on the Mac,
   Complete or Working on the phone, which is the spec's second edge case (SC-005).
6. **Nothing moved that should not.** Headings, their order and the archived toggle look
   as they did (FR-022).
