---
name: 733-team-enterprise-roadmap
description: "Team/enterprise roadmap (#733, PR #735) and Alex's 2026-10-11 decisions — self-hosted first, owner-only hosts, Google/Apple OIDC, policy from the control plane"
metadata:
  type: project
  modified: 2026-10-12T04:37:21.196Z
---

Enterprise review `.agents/reviews/enterprise/2026-10-11.md` (#724, PRs #725/#730). Alpha defects from it: #726–#729.

Roadmap `specs/research/733-team-and-enterprise.md`, in three tiers:
- **Team:** T1–T4.
- **Enterprise:** T5–T9.
- **Hosted:** T10, where an org = a store prefix.

Issues (2026-10-14, all parked): T1–T10 = #994–#1003, labels `team`/`enterprise`/`hosted`; umbrella #845, T1+T2 spec #736.

The first slice is T1 people/roles + T2 Google/Apple sign-in. `direction.md` is NOT changed: the alpha comes first.

**Decisions** (Alex, 2026-10-11):
- **Tenancy:** both, self-hosted first.
- **Hosts:** owner only, unless shared.
- **Identity:** Google + Apple via generic OIDC.
- **Policy:** from the control plane; MDM only pins the control plane.

**Why:** this supersedes the "one person per control plane" premise for future specs. It does not supersede [[one-grant-decision]] for a single person.

**How to apply:**
- New control-plane work should keep `owner` meaningful and stay inside the store prefix.
- Creating the Google/Apple client ids is Alex's job.
