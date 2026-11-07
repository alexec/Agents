---
name: local-first-no-cloud-login
description: "Alex 2026-10-16 — never require a cloud login; every cloud service has a local version; plain files in platform folders, no SQLite"
metadata:
  type: project
  modified: 2026-10-16T16:17:59.604Z
---

Alex 2026-10-16 (during the Go migration spikes, #1125/#1126):
- Users can never be forced to have a cloud login. Any service mandated in the cloud also needs a local version (control plane on the Mac, folder store beside S3, local key keeper beside Google Cloud KMS).
- Local versions keep their files in the correct local configuration folders: today's layout (~/.agents / AGENTS_ROOT, XDG_* on Linux, Application Support on the Mac where the Swift code uses them).
- No SQLite or similar embedded database: plain files. Both Go spikes kept to this as of 2026-10-16.

**Why:** solo, local use must keep working with no account; data stays inspectable files.
**How to apply:** check every cloud feature (#61, sign-in in [[733-team-enterprise-roadmap]], [[machines-and-groups]]) for a local, no-account path; refuse a database dependency in reviews.

2026-10-18: Alex chose one identity model over mandatory SSO (#995, #1117): every client belongs to a person; providers are Google, Apple, GitHub or a built-in "local owner" (no account, no network); codes are the local provider's sign-in. Mandatory outside sign-in on a public control plane (#61) is not decided.
