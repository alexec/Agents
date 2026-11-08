---
name: robustness-performance-priority
description: "Alex ranks robustness and performance very highly; after each batch lands, run a review of logs and of code paths that scale with hosts, clients, projects and sessions, and file every finding"
metadata:
  type: feedback
---

Alex, 2026-10-03: "Robustness and performance are very important to me. Once everything is landed, start an agent to review these. It should look at logs, as well as analyse the code from places where performance might hurt, e.g. due to large numbers of hosts, clients, projects, sessions etc."

**Why:** the app fans out across hosts, phones, web pages and many sessions. Cost that grows with those counts, and fragile failure paths, matter more to Alex than new features.

**How to apply:**
- The reviewer prompt is in ~/.agents/project-lead/robustness-perf-review-prompt.md.
- Start it once in-flight work has landed.
- Its findings become bug issues, and bugs go first in the lanes (see [[bugs-before-features-and-board-status]]).
- Ask every lane to keep scale and failure paths in mind. Earlier review: [[073-robustness-review]].
