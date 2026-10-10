# groups/

- `agents.json`: `Agent.group(wantsEyes:)`, which is `AgentGroup.init(for:…)` and its
  `settled` (`Model/AgentGroup.swift`), with each group's `title`, `Agent.needsAPerson`,
  `Agent.isWaiting`, `Agent.showsUnread` and `Agent.asksToArchive` (#584). Every arm of the switch has a case.
- `panels.json`: one project's sessions column as `AgentsModel` builds it
  (`Client/AgentsModel.swift`): `AgentGroup.live` in order, `agents(in:group:)` (newest started
  first, #182; Archived newest activity first), each heading's unread and asking-to-archive
  counts, archived apart,
  `counts(in:)` and `unreadCount(in:)`.
  An agent in a worktree counts under its project; an agent elsewhere does not.
