---
name: Address review comments
on:
  - review.posted
  - review.comment:
      server: gitlab
agent: new
cooldown: 10m
labels: [dev-loop]
permission-mode: approve-for-me
enabled: false
when-done: archive
---

A review of a pull request is done (GitHub), or a line of a merge request was commented on
(GitLab, which has no event for a whole review: the cooldown gathers a reviewer's comments
into one run). The event's data says which pull request or merge request and branch, and
the event's server says which forge. Follow the `address-review-comments` skill
(`.agents/skills/address-review-comments/SKILL.md`) from step 1 to the end.
