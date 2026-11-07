---
name: machines-and-groups
description: "Alex 2026-10-15 multi-user/multi-host direction — one group per machine (Linux-style, for security), SSO-approved registration, direct local path; not yet filed or specced"
metadata:
  type: project
  modified: 2026-10-16T06:26:57.646Z
---

Alex pondered (2026-10-15) a re-shape of the team tier (#733, spec 736, T1 #994 / T2 #995):
- workspace and host merge into one thing, a machine — either started by the control plane (provider) or registered to it;
- first one group per machine, then REPLACED the same day: **one user per machine** (Alex decided), because MCP secrets act as whoever configured them and the Unix user is the only real boundary; config scopes are control plane / user / project; no sharing for now (decided);
- registration via SSO in place of the long host code (I proposed device-approval on a signed-in client, like `tailscale up`/`gh auth login`; started machines get a one-time join token);
- the control plane goes to the cloud, but the UI talks to a daemon on the same machine directly.

This contradicts spec 736 FR-021 (hosts never sign in) and control-plane.md:25 (no client→host direct). Filed #1117 (re-spec: "Machine" in UI, code keeps Host; groups; approve-to-join; MCP owned by the machine, decided) and #1118 (direct local path). Spec 736 not yet rewritten. Later the same day (all in #1117 comments): bot users are distinct users configured by admins; groups return for PROVIDERS only (set of users / one / everyone); removed person's started machines stopped+deleted; control plane holds user secrets (decided: encrypted with a CP key outside the store); channel identities linked by approval (+DKIM for email); workflows run once per trigger via the CP with `runs-on:` labels and scoped events (decided); #1120 MCP shim closed not planned. Bots: nobody starts them directly, only events (Alex). All questions answered; rewrite 736/733 when unparked. 2026-10-16: bot sessions get no ask tools; bot cost to its group; team workflows run by the bot (runs-on), personal ones per user; KMS = Google Cloud KMS (Alex); #61 cloud control plane UNPARKED (HTTPS web page, KMS, #1118 as parts; Alex makes droplet/DNS/GCP/APNs).

**Why:** multi-user and a cloud control plane (#61) need a model where solo use is unchanged.
**How to apply:** when filing, re-spec 736 and file a direct-path issue (area:control-plane); keep [[hosts-no-escalated-privileges]] in mind for Linux groups. Related: [[733-team-enterprise-roadmap]], [[691-workspace-providers]].

2026-10-16 later: Alex wants the daemon (then control plane) in Go, leaning on libraries. Spike filed #1125 (Go agentsd on Linux joins the control plane + one Claude turn over coder/acp-go-sdk, Mac window unchanged). #61 and #1118 re-parked until it reports. Order if it passes: Linux hosts → control plane (+ gocloud KMS) → Mac daemon; Agents Host + agents-relay stay Swift.
2026-10-16: Alex wants both spikes ready to test evening 2026-10-17, 'go far': #1125 widened to 5 stages (base, everyday Linux turn, schema-first wire, workflows/Landlock/hosted MCP, Go agentsd on Mac scratch root); #1126 Go control plane spike (store, auth, router, KMS local keeper, web page). Handed to Lead. Parked meanwhile: #61 #1118 #1009 #857 #829 #1119 #1122 #1123.
