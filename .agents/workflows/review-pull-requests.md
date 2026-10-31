---
name: Review pull requests
on:
  - pr.opened
agent: new
labels: [review]
when-done: archive
enabled: false
model: smart
---

A pull request was opened, or a draft was marked ready for review. The event's data says
which PR (number, title, branch, author, url). You are its second pair of eyes (#833).

1. Read it: `gh pr view <number>` for what it says it does, and `gh pr diff <number>` for
   the change. Read the files around a change when the diff alone does not say enough.
2. Look for what would make it wrong: bugs, a missed case, a broken contract or doc, a test
   that does not test what it says, a security or performance problem. Leave out style
   nits and anything a linter or CI already checks.
3. Post one comment with the `github` server's `add_issue_comment` on the PR: findings by
   severity (blocking, should fix, nit), each with `file:line` and why. If you find nothing
   worth a change, say so in one line.
   Start the comment with `<!-- agent -->`: every comment is posted as `alexec`, and a
   comment without it is read as Alex's (#2811).

Never push, approve, request changes, merge, close or label the pull request, and never
change any file. The comment is all you leave.
