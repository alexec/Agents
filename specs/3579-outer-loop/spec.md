# The outer loop: from idea to production and back, shown as Lineage (#3579)

The spike #3580 of the epic #3579. Feature `feature:delivery`. Docs only: no product code.

## The question

What is the smallest outer loop that takes a dictated feature to production and brings
its health back as work, with Lineage as the way a person sees it?

## The north star

Alex, 2026-11-05 (voice): a person dictates the features they want. Agents takes them all
the way to production. It organises the work, ships it (TestFlight and App Store builds on
a person's iPhone, updates rolled out, a service behind a status page), and watches the
system's health. What health finds comes back as new work.

`docs/explanation/direction.md` has this as "From idea to production", because that page
says where the product goes.

The inner loop is there today: voice mode, the Product Owner, the Scrum Master, leads,
lanes, auto-merge. This folder also runs a version of the outer loop for Agents itself:
the release skill tags, `release.yml` uploads to TestFlight, and the crash-reports skill
files issues from the crashes on this Mac. This epic makes that a product feature for any
app.

## The shape

The pipeline is: idea → issue → PR → build → release → deploy → health → new issue.

- **The pipeline is in the background.** There is no pipeline screen. Each stage is a
  lineage node, so "where is my feature?" and "what did this outage come from?" are walks
  of the graph (#2348).
- **A person sees it in Lineage's data and one line (#3588):** #3506 removed the Lineage
  section and pane, and no new one takes their place. Under the title of an issue's, a PR's
  or a release's Work page, one line names the pipeline in reach, each stage a link out:
  `Release v1.2.0 · CI run · TestFlight 42 · Sentry issue 4321`. It comes from one
  `lineage/walk`, 4 links deep, on the machine that keeps the links.
  - **Back ("what did this come from?"):** a bug that `reports` a health signal says
    `From Sentry issue 4321 · seen in v1.2.0 · TestFlight 42 · PR #12 · #10`: the release
    and deploy it was seen in, that release's PRs and the issues they fix. A release's page
    says its PRs and their issues the same way. Reports ▸ Value's release rows open that
    page.
  - At most 3 of a kind are named; the rest are counted ("2 more").
  - Mac + web (#2796); the Remote's Work page leaves the line out.

## Each stage as a node and a link

The graph is `Go/internal/lineage` (#2348). Kinds, rels and sources are open lists, so a
new stage needs no wire change: only a new linker in the host.

| Stage | Node (`kind`, `ref`) | Link into the chain | Today |
| --- | --- | --- | --- |
| Idea (dictated, voice mode) | `session`, `session:<id>` | — | there |
| Epic and its children | `issue` | child `part-of` epic | there (#3582) |
| Issue filed by an agent | `issue` | session `opens` issue | there (#3582) |
| Work on the issue | `session` | session `works-on` issue | there (#2349) |
| PR | `pr`, `github:<o>/<r>#n` | session `opens` PR; PR `fixes` issue | there (#2349) |
| Build (CI run) | `ci-run`, `github:<o>/<r>/actions/run/<id>` | `ci-run` `builds` PR, or `builds` release | there (#3581): `checks.*` and `run.completed` on a `v*` tag; a PR keeps its last 20 runs |
| Release | `release`, `github:<o>/<r>/release/<tag>` | PR `part-of` release; milestone `shipped-in` release | there (#3023) |
| Deploy | `deploy`, `<target>:<id>/<version>`, as `testflight:<bundle id>/<build>` or `cloudrun:<project>/<region>/<service>/<revision>` | release `deployed-as` deploy; deploy `part-of` its target | there (#3584, Cloud Run #3654): a job's `::notice title=deploy::<ref>`, read from `run.completed` on a `v*` tag |
| Health signal | `health`, `<source>:<id>`, as `sentry:<org>/<issue id>` | health `seen-in` release or deploy | there (#3585): `health.issue_new` and `health.issue_regressed`, matched to the release by version |
| New issue | `issue` | issue `reports` health | there (#3586): the ready-made **File a bug from Sentry**; the bug its session labels itself with |

- The `ci-run` kind is new, not `workflow-run`: `workflow-run` is an Agents workflow's run
  (`run:<id>`), not a forge's CI.
- With these links, a walk from an issue reaches its release, its deploy and the health
  signals seen in it. A walk from a health signal reaches the release, its PRs and the
  issues they fix.
- The walk's limits stay (4 links, 500 nodes). Issue → PR → release → deploy → health is 4
  links.

## Decisions

- **Decided: the north star goes in `direction.md`, as "From idea to production", and this
  spec has the detail.** Because `direction.md` says where the product goes, and every spec
  agrees with it. Alex can overrule.
- **Decided: the first deploy target is TestFlight.** Because the release skill and
  `release.yml` do it for Agents now, and it puts the build on a person's iPhone, as the
  north star says. A cloud service (Fly, Cloud Run, Vercel or similar) is the second.
  Alex can overrule.
- **Decided: the second deploy target is Google Cloud Run (#3654).** Because the customer's
  CI signs in to it with no key (Workload Identity Federation, by the official
  `google-github-actions/auth`), so no long-lived credential sits in their secrets to leak;
  `gcloud`, its official CLI, is already on GitHub's runners; and a revision's ref names
  its project, region and service, so each client links to it in the console. Not chosen:
  Fly (its deploy token is long-lived), Vercel (it is made to deploy from its own Git
  integration, not from the customer's CI), and Google's `deploy-cloudrun` action (no
  update since 2025-09). Alex can overrule.
- **Decided: a deploy runs in the customer's own CI** (GitHub Actions, or GitLab CI),
  started by a tag, as `release.yml` does it now. The signing secrets are the repo's CI
  secrets. A machine of the customer's (a Mac as a self-hosted runner) is the option when
  their CI has no macOS runner. Agents watches the run and links it. It never runs the
  deploy on the control plane. Because:
  - Principle 1: nothing relies on the Mac. A hosted macOS runner builds an iOS app.
  - Principle 5: customers bring their own compute.
  - Principle 6: the control plane holds no compute or signing credential and cannot act.
  - Principle 7: the App Store Connect key stays in the customer's CI.

  Alex can overrule.
- **Decided: the approval step is the forge's.** A GitHub environment with required
  reviewers (GitLab: a protected environment) holds the deploy until a person approves.
  Agents shows the waiting deploy as a card and approves it through the forge's API, with
  the person's own sign-in. Because the forge already has the gate and its audit, and
  Agents only shows it. Alex can overrule.
- **Decided: the first health source is Sentry, as an MCP server.** Because one service
  has crashes (Apple platforms, Android), errors (web, Go, Node), uptime monitors and cron
  checks. It knows each release by its version, so a Sentry issue says the release that
  first saw it: that is the `seen-in` link. Sentry has an official MCP server
  (`getsentry/sentry-mcp`), and direction.md says every integration is an MCP server. The
  customer's app holds the Sentry SDK, which is MIT (`sentry-cocoa`, `sentry-go`), not
  Agents. Alex can overrule.
  - The official server has tools, not the events that a workflow waits on. The first
    child decides whether to add events to it, or to write a small events server, as
    `github-mcp` does for GitHub.
  - Not chosen first: App Store Connect's TestFlight crashes and feedback (only Apple
    platforms, no uptime); Grafana (more to set up); our own checks (AGENTS.md: a library or
    a service before our own code). The crash-reports skill stays for this folder.
- **Decided: a status page comes later**, after the loop works. Sentry has none. Better
  Stack, Instatus and Atlassian Statuspage are the choices then. Alex can overrule.
- **Decided: health comes back as an issue, by a ready-made workflow.** A new or regressed
  Sentry issue starts a workflow. Its agent files an issue (or comments on the one that
  tracks it), as the crash-reports skill does, and links issue `reports` health. Because
  the inner loop then takes it as any other issue: a bug with no milestone, for the bug
  lane. Alex can overrule.
- **Decided: no milestone for the epic now.** Because no milestone's goal names delivery,
  and work goes by epic (#3465). Alex can put it in a milestone. Alex can overrule.
- **Decided: the Remote gets health as notices it gets now** (a notice is Core), and no new
  screen. The Lineage view is Mac + web, as before. Alex can overrule.

## The plan (the epic's children)

The children are sub-issues of #3579, with "blocked by" links. Step 1 can start at once. The lead owns the plan from here.

| Step | Child | Level | Blocked by |
| --- | --- | --- | --- |
| 1 | #3581 Lineage: link a CI run to its PR and its release (`ci-run`) | task | — |
| 1 | #3582 Lineage: link a child issue to its epic, and an issue to the session that filed it | task | — |
| 1 | #3583 Sentry as an integration: tools and events (new and regressed issues) | task | — |
| 2 | #3584 Lineage: a TestFlight build as a deploy node, linked to its release | task | #3581 |
| 2 | #3585 Lineage: a Sentry issue as a health node, `seen-in` its release | task | #3581, #3583 |
| 3 | #3586 A ready-made workflow: health back into work (an issue that `reports` health) | story | #3585 |
| 3 | #3587 Approve a waiting deploy from Agents (a forge environment's gate) | story | #3584 |
| 3 | #3588 Lineage shows the whole pipeline: from an issue to its deploy and health, and back | story | #3584, #3585 |

Later, filed by the lead when the loop works:

- A cloud service as the second deploy target (Fly, Cloud Run or Vercel): Cloud Run, #3654.
- A status page.
- A new app from nothing, by voice: a repo, outside accounts and secrets.
- The App Store (not only TestFlight) as a deploy target, with Alex's approval for each
  release to App Review: #3657. `app-store.yml` waits at the `app-store` environment's gate
  (#3587), then submits; its run says `appstore:<bundle id>/<version>` and the TestFlight
  build it submitted, which is `deployed-as` that version.

## Clients

Docs only. mac: docs only, remote: docs only, web: docs only. The children say their own
tiers: the Lineage view is Mac + web (#2796); a health notice is Core.
