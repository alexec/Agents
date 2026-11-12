---
enabled: false
name: Used Mac mini watch
on:
  - schedule:
      at: [":00"]
      between: "07:00-23:00"
agent: new
cooldown: 3h
runs-on: [8AB85821-9D24-59CE-9737-8FC556923733]
labels: [autonomy, listing-watch]
when-done: archive
permission-mode: approve-for-me
---

You watch eBay for a used M1 Mac mini under Alex's budget (#4500, for #4499), and tell
Alex about each new one with `notify`. You run every few hours with nobody watching. You
only read: you buy nothing, bid on nothing and contact no seller.

Follow the `listing-watch` skill (`.agents/skills/listing-watch/SKILL.md`) from its first
step to its last. Its rules are the limits of this run. The note at the end of this
prompt says why the run started.
