---
diataxis: explanation
description: The general model that every deploy system maps into (artifacts, versions, components, environments, targets, deploys and checks), why it takes no side, and how each system fits it.
---

# The deploy model

Agent Loops reads deploys from many systems: GitHub and GitLab deployments, and later Argo CD,
Kargo, Octopus Deploy and others. Each system has its own words for the same things. Agent Loops
puts them all into one model, so a pull request's page, a release's page and the DORA
figures work the same for each system.

The model takes no side (Alex, 2026-11-13). It works for every deploy system, not only for
the way one repo deploys. The spec is `specs/5239-deploy-model/spec.md` (epic #5239). The
types are in the wire, `Packages/Wire/daemon.schema.json` (#5262), so every source and
every client uses the same ones.

## The rules that keep it general

- **The model takes the widest form that a real system has.** When one system has a set
  and another has one item, the model has a set. A set of one is the simple case.
- **A system's own words and states are kept** beside the model's. `kind` and labels are
  open strings. Each item keeps its `system`, its `id` there, and its `rawState`.
- **Who does the work is not part of the model.** A system that runs the deploy (Argo CD,
   Kargo) and a system that only records it (GitHub Deployments) give the same types.
- **Defaults fill what a system does not say.** A system that says only "sha X went to
  production" still fills the model.
- **Only what all systems share is a required field.** The rest is optional or a label.

## The types

| Type | Wire definition | What it is | Default when a system does not say |
|---|---|---|---|
| **Change** | (a lineage node: `pr`, `commit`) | one unit of work: a PR, an MR, a commit | the commits' PRs, from the forge |
| **Artifact** | `DeployArtifact` | one immutable thing that a build made: a commit, an image digest, a chart version, a package, a mobile build. It has `kind`, `system`, `id` and `builtFrom` (the changes) | the commit itself |
| **Version** | `DeployVersion` | the set of artifacts that go out together. A **Release** is a Version with a `name` | one artifact: the commit |
| **Component** | `DeployComponent` | what runs and has versions: a service, an app, a site | the repo |
| **Environment** | `DeployEnvironment` | a place where components run, shared by many components and repos. It has a `tier` and can be `ephemeral` | the forge environment |
| **Target** | `DeployTarget` | one component in one environment, with `labels` (region, cluster, tenant, machine) that tell instances apart | component × environment, no labels |
| **Deploy** | `Deploy` | one try to put a Version into a Target: `state`, `rawState`, `started`, `finished`, `rollback`, `share` | |
| **Check** | `DeployCheck` | a condition with a state: an approval, a test, a health status, a window. `when` is `before` (it can hold the deploy) or `after` (how what runs there is) | none |

Two enums are fixed, because every system maps to them:

- **`DeployState`:** `waiting`, `running`, `succeeded`, `failed`, `cancelled`. A deploy's
  and a check's state. The system's own word stays in `rawState`.
- **`EnvironmentTier`:** `production`, `staging`, `testing`, `development`, `other`, as
  GitLab's. A tier that a build does not know reads as `other`.

### Deploy states

| State | GitHub | GitLab | Argo CD | Kargo | Octopus | Kubernetes rollout |
|---|---|---|---|---|---|---|
| `waiting` | `waiting` | `blocked` | (sync window) | `Pending` | Queued (manual step) | paused |
| `running` | `queued`, `in_progress` | `created`, `running` | `Running` | `Running` | Executing | progressing |
| `succeeded` | `success` | `success` | `Succeeded` | `Succeeded` | Success | complete |
| `failed` | `failure`, `error` | `failed` | `Failed`, `Error` | `Failed`, `Errored` | Failed, TimedOut | degraded |
| `cancelled` | (run cancelled) | `canceled` | `Terminating` | `Aborted` | Canceled | aborted |

GitHub's `inactive` is not used. In a repo where two jobs share one environment, GitHub
sets the first job's Deployment `inactive` when the second ends, so it does not mean
"replaced".

## What is computed, not stored

- **A target's live versions:** what runs there now, each with its share of the traffic.
  Usually one at 100 %; two during a canary or a blue-green switch.
- **A target's next versions:** a deploy that waits or runs there, or a system's own
  "proposed" (GitOps Promoter, Kargo).
- **A changeset:** the changes between two versions, through each artifact's `builtFrom`.
- **A rollback:** a deploy whose version is older than the live version it replaced. A
  system that says it sets `rollback` directly.
- **Replaced:** a newer deploy to the same target succeeded.

A target can also report what it runs (Argo CD's live state, a machine's version when it
connects). A change in that report is a deploy with `observed: true`.

## Events

The sources send these events, from each system's MCP server:

| Event | When | Details (wire definition) |
|---|---|---|
| `deploy.waiting` | a deploy waits for an approval (#3587) | its own fields, and `DeployEvent`'s |
| `deploy.started` | a deploy goes `running` | `DeployEvent` |
| `deploy.succeeded` | a deploy goes `succeeded` | `DeployEvent` |
| `deploy.failed` | a deploy goes `failed` or `cancelled` | `DeployEvent`, with `outcome` |
| `check.changed` | a check on a deploy or a target changes state | `DeployCheckEvent` |

Each event's details also have `component`, `environment` and `tier` as flat fields. So a
workflow can start on "a deploy to any production environment failed" (`tier:
production`) with no list of names.

## The mapping: each system in the model

| System | Change | Artifact | Version | Component | Environment | Target | Deploy | Check | Path |
|---|---|---|---|---|---|---|---|---|---|
| **GitHub Deployments** | PR | the sha | the sha (one artifact) | the repo | environment | repo × environment | Deployment | protection rules (approval, wait timer, branch policy) | none |
| **GitLab** | MR | the sha | the sha | the project | environment (with tier) | project × environment | deployment | protected environment approvals | none |
| **Azure DevOps** | PR | the sha, pipeline artifacts | a pipeline run | the repo or pipeline | environment | pipeline × environment, with resources | deployment job | approvals and checks | stages |
| **Argo CD** | | revision, images | the revisions of a sync (more than one for a multi-source app) | the app | the destination (cluster, namespace) | Application | sync operation | health, sync windows | none (ApplicationSet progressive sync has steps) |
| **GitOps Promoter** | PR | dry commit, hydrated commit | the dry sha | the repo | environment branch | the branch pair (`ChangeTransferPolicy`) | merged promotion PR; `RestoreActiveCommit` is a rollback | `CommitStatus`: proposed (before) and active (after) | `PromotionStrategy` (a list or a DAG) |
| **Kargo** | | commits, images, charts, other artifacts | Freight | the Warehouse's subject | Stage's place | Stage | Promotion | verification, promotion windows | Stage's upstream Stages (a DAG) |
| **Octopus Deploy** | | packages | Release (a set of packages) | Project | Environment | Project × Environment (× Tenant) | Deployment | manual intervention, steps | Lifecycle phases |
| **Spinnaker** | | images, manifests | a pipeline's artifacts | Application | account, region | server group (cluster) | deploy stage | manual judgement, canary analysis | the pipeline's stages |
| **Flux** | | revision | the source revision | Kustomization or HelmRelease | cluster, namespace | the Kustomization or HelmRelease | a reconcile with a new revision | health checks | none (`dependsOn` is between components) |
| **CDEvents 0.5** | `change` | `artifact` | `artifact` | `service` | `environment` | service × environment | `service.deployed`, `upgraded`, `rolledback` | `testcaserun` | none |
| **TestFlight / App Store** | | the build | the version (marketing version) with its build | the app (bundle id) | TestFlight, App Store (tier production) | app × place | upload, submission | App Review, beta review | TestFlight → App Store |
| **Cloud Run** | | the image digest | the revision | the service | project, region | service in a region | a new revision | traffic share (several live versions) | none |
| **Vercel, Netlify** | PR | the build | the commit | the project | production, preview (ephemeral, one for each PR) | project × environment | deployment | checks | preview → production (promote) |

Every row fits with no new type. The rows that test the model:

- **Kargo, Octopus and Argo CD multi-source** need a Version with many artifacts.
- **Octopus tenants, Cloud Run regions and Argo CD clusters** need a Target with labels.
- **Argo CD and Kargo environments** are shared by many components, so an Environment
  does not belong to one repo.
- **Cloud Run, Argo Rollouts and Flagger** need more than one live version, each with a
  share.
- **Vercel previews and GitLab review apps** need ephemeral environments.
- **GitOps Promoter and Kargo** need a "next version" that the system itself says, and a
  path that is a DAG.

The Path (an order between targets, "after staging, production") is not in the wire yet:
no source reads one. It comes with the first source that has one.

## The simple case stays simple

For a GitHub repo that deploys with `environment:` jobs, the defaults fill everything:

| Type | Filled from |
|---|---|
| Artifact and Version | the Deployment's sha, with its `v*` tag as the Release's name |
| Component | the repo |
| Environment | the deploy notice's name, else the Deployment's environment |
| Target | repo × environment |
| Deploy | the Deployment and its statuses |
| Check | the environment's required reviewers, as a waiting deploy (#3587) |
