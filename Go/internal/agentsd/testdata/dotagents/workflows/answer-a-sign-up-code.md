---
name: Answer a sign-up code
on:
  - email.received:
      server: email
      from: "noreply@github.com"
      authenticated: "true"
  - email.received:
      server: email
      from: "gitlab@mg.gitlab.com"
      authenticated: "true"
  - email.received:
      server: email
      from: "noreply@gitlab.com"
      authenticated: "true"
  - email.received:
      server: email
      from: "*@digitalocean.com"
      authenticated: "true"
  - email.received:
      server: email
      from: "*@*.aws"
      authenticated: "true"
  - email.received:
      server: email
      from: "*@amazon.com"
      authenticated: "true"
agent: new
labels: [email]
permission-mode: approve-for-me
enabled: false
when-done: archive
---

Mail came from a sender on this workflow's allowlist: one trigger for each sender, and only
when the receiving mail server authenticated the sender (`authenticated: "true"`). The
event's data says which message (id, from, subject); never its text. Follow the
`answer-a-sign-up-code` skill (`.agents/skills/answer-a-sign-up-code/SKILL.md`) from step 1
to the end. To trust another sender, add a trigger with its exact no-reply address as
`from` (never a whole domain that also sends notifications people write), and keep
`authenticated: "true"`.
