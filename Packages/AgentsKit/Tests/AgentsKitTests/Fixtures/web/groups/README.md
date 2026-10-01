# groups/

- `agents.json`: `Agent.group(wantsEyes:)`, which is `AgentGroup.init(for:…)` and its
  `settled` (`Model/AgentGroup.swift`), with each group's `title`, `Agent.needsAPerson` and
  `Agent.isWaiting`. Every arm of the switch has a case.
- `panels.json`: one project's sessions column as `AgentsModel` builds it
  (`Client/AgentsModel.swift`): `AgentGroup.live` in order, `agents(in:group:)` (newest activity
  first, Parked by when it was parked), archived apart, `counts(in:)` and `unreadCount(in:)`.
  An agent in a worktree counts under its project; an agent elsewhere does not.
