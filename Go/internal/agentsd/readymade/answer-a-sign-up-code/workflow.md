---
name: Answer a sign-up code
on:
  - email.received:
      server: email
      from: "*@gitlab.com"
  - email.received:
      server: email
      from: "*@*.gitlab.com"
  - email.received:
      server: email
      from: "*@github.com"
  - email.received:
      server: email
      from: "*@digitalocean.com"
  - email.received:
      server: email
      from: "*@*.aws"
  - email.received:
      server: email
      from: "*@amazon.com"
agent: new
labels: [email]
permission-mode: auto
enabled: false
when-done: archive
---

Mail came from a sender on this workflow's allowlist: one trigger for each sender. The
event's data says which message (id, from, subject); never its text. Follow the
`answer-a-sign-up-code` skill (`.agents/skills/answer-a-sign-up-code/SKILL.md`) from step 1
to the end. To trust another sender, add a trigger with its address as `from`.
