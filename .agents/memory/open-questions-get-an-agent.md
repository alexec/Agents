---
name: open-questions-get-an-agent
description: An issue with open questions gets an agent that works the answers out with Alex; it is not held back
metadata:
  type: feedback
  modified: 2026-10-12T15:39:34.700Z
---

When an issue has open questions (design, layout, scope), start an agent to work out the answers with Alex instead of leaving the issue in the queue.

**Why:** Alex, 2026-10-12, when the scrum master held back #760 (personas) as "needs a design first". Holding it back leaves the questions unasked.

**How to apply:** The agent reads the issue and the code, puts the options in front of Alex with a recommendation (ask_form or AskUserQuestion), writes the answers back into the issue (or a spec), and builds only once they are settled. It takes a lane place like any other. See [[check-for-a-fix-before-starting-a-lane]] and [[explore-before-building]].
