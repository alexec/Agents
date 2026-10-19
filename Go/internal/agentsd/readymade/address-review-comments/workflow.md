---
name: Address review comments
on:
  - review.posted
agent: new
cooldown: 10m
labels: [github]
permission-mode: auto
enabled: false
when-done: archive
---

A review of a pull request is done. The event's data says which PR, branch and commit.
Follow the `address-review-comments` skill
(`.agents/skills/address-review-comments/SKILL.md`) from step 1 to the end.
