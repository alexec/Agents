# Move the repo to the `agentloops-dev` organisation (#4929)

**Status:** plan, 2026-11-12. Epic #4925. Name and organisation from #4927
(`specs/4927-final-name/spec.md`): Agent Loops, `agentloops-dev`, agentloops.dev.
**Clients:** none directly (tooling, CI, docs). Links in all three may change.
**Direction (`docs/explanation/direction.md`):** no principle changes. The control plane
stays at control.agentloops.dev; only the place of the code and its CI moves.

Alex makes the organisation and approves the transfer. Agents make no outside account and
transfer nothing without Alex's yes.

## What reads `alexec` today

A survey of `git grep alexec` on main (1431 files). Most of them need no change.

### No change

| What | Why |
|---|---|
| Bundle ids `com.alexecollins.*` (`project.yml` `bundleIdPrefix`, the App Store records, Keychain groups) | They are App Store records. A change makes new apps. They are not GitHub names. |
| The Go module path `github.com/alexec/agents/Go` (about 2000 imports) | Nothing outside this repo imports it, and the module is never fetched by its path. A rename is a large change across many files; do it on a quiet day, on its own issue (follow-up 3). |
| Test fixtures and examples (`*_test.go`, `Tests/`, `Web/test`, `specs/`, `.agents/reviews/`, doc comments in `WireRef.swift`, `ref.ts`, `WorkLook.swift`…) | They are sample data. `alexec/agents` in a test is as good as any repo. |
| `.github/CODEOWNERS` (`@alexec`) | Alex stays a person and is an owner of the organisation. A user name is valid in an organisation's CODEOWNERS. |
| `alex-todo` assignments to `alexec`, `<!-- agent -->` markers, "posts as `alexec`" | They name Alex the person, not the repo's owner. |
| Alex's own app repos (`make_app_repository`, the private apps) | They are Alex's apps, not the product's. |

### Changes on GitHub (they move with the transfer, or need Alex)

| What | What happens at the transfer | Step |
|---|---|---|
| Issues, PRs, stars, watchers, labels, milestones, wiki, releases | Move. GitHub redirects web, git and API URLs from `alexec/Agents`. | none |
| Actions secrets, variables, environments (`release`, `app-store`, `github-pages`, `copilot`) and their gates | Move with the repo. | Check one release dry run after. |
| Ruleset `main` (incl. *Require approval of changes not attributed to a person*) | Moves. A bypass actor that is a user App may need to be added again. | Check the ruleset after. |
| Dependabot (config, alerts, security advisories) | Moves. | none |
| The agents' GitHub App `alexec-agents` (#3858, #3926) | **Does not move.** It is owned by the user `alexec` and is private, so it cannot be installed on another account. | Alex transfers the App's ownership to `agentloops-dev` (App settings ▸ Advanced ▸ Transfer ownership), then installs it on the organisation for this repo. The App's id and key stay; the credential helper finds the new installation by itself (`connections/githubbot.go` lists `/app/installations`). |
| Container image `ghcr.io/alexec/agents-control` (#2140) | **Does not move.** A package belongs to its owner, not the repo. | The first release after the move pushes `ghcr.io/agentloops-dev/agents-control`. Alex makes that package public. The live control plane then pulls the new name (`deploy/gcp/common.sh`). |
| GitHub Pages, docs.agentloops.dev (#1549) | The Pages site moves. The DNS name points at `alexec.github.io`. | Point the `docs` CNAME at `agentloops-dev.github.io` (`deploy/cloudflare/dns.sh --names docs --cname agentloops-dev.github.io`), and verify agentloops.dev in the organisation's Pages settings. |
| The app's folder record and every clone's `origin` | Git still works by the redirect. | `git remote set-url origin https://github.com/agentloops-dev/Agents.git` in the main checkout (worktrees share it). |
| The app's stored refs: lineage (`github:pr:alexec/agents#…`, about 12 000 lines), `workflows.json`, `mcp-events.json` | **Old refs do not match new events.** A PR opened before the move and merged after it has two refs, and a `wait_for_event` that names the old repo never wakes. | Follow-up 1: a repo alias (old owner → new owner) when the daemon reads refs, made from GitHub's own redirect. It must land before the transfer. |

### Changes in this repo (this PR)

Two kinds, so the PR is safe to merge at any time:

1. **Owner from the repo, not a literal (safe now):**
   - `.github/workflows/release.yml`: `IMAGE: ghcr.io/${{ github.repository_owner }}/agents-control`.
     The agents' bot cannot push a workflow file (#4291), so this one goes on its own PR,
     pushed as `alexec` with Alex's yes. It must land before the first release after the
     transfer: an organisation's release cannot push to the user's package.
   - `scripts/release-secrets.sh`: `RELEASE_REPO` defaults to the `origin` remote's repo.
   - `.agents/skills/release/scripts/advisory.py`: the repo from `gh repo view`.
   - `scripts/docs-check.py`: the private-repo link check (#1064) also matches `agentloops-dev/Agents`.
2. **Links (safe after the transfer; before it, a link to the new owner is a 404):** www,
   `mkdocs.yml` `repo_url`, AGENTS.md's needs-approval list, the skills and docs that link
   the repo, the GHCR name in `deploy/`. These go on a second PR that lands right after the
   transfer. Old links keep working by the redirect, so there is no hurry.

## The order of the move

1. **Alex makes the organisation** `agentloops-dev` (plan below) and is its owner.
2. **This PR lands** (owner-agnostic scripts and CI), and follow-up 1 (the ref alias) lands.
3. **Alex transfers the agents' GitHub App** to the organisation and installs it on the
   organisation.
4. **Alex transfers `alexec/Agents`** to `agentloops-dev` (Settings ▸ General ▸ Danger
   Zone ▸ Transfer). No lane runs at that time: the lead pauses new lanes and waits for
   open PRs to land or park.
5. **An agent checks** (one lane): `origin` updated, a PR auto-merges, the ruleset and the
   environments are there, the bot posts as `alexec-agents[bot]`, a release dry run passes.
6. **The links PR lands** (follow-up 2): www, mkdocs, docs, skills, `deploy/` GHCR name,
   the docs CNAME.
7. **The next release** pushes `ghcr.io/agentloops-dev/agents-control`; Alex makes it public;
   `ship-app --control-plane` moves the live control plane to the new image.
8. **The other repos move** (if Alex says so): see below.

## How it fits #1064, #2145 and #2147

- **#1064 (make the repo private).** In a Free organisation a private repo has no Pages, no
  rulesets and no environment gates. So a private repo needs **Team** ($4 per user per
  month), which replaces the GitHub Pro plan that #1064 says to buy. A public repo needs
  only Free. #1064's checklist changes from "buy Pro" to "move the organisation to Team".
- **#2145 (the public download).** Its releases-only repo is planned as
  `alexec/agents-releases`. Make it as `agentloops-dev/agents-releases` instead, so the
  public place is under the product's name.
- **#2147 (no public link into the repo).** It removes the links this plan moves. When
  #2147 lands first, follow-up 2 has fewer links to move; when it lands after, it removes
  the new ones. The `docs-check.py` rule covers both owners (this PR).

## The other repos

| Repo | Recommended |
|---|---|
| `web-service-starter`, `iphone-app-starter` (the `make_app_repository` starters) | Move: they are part of the product. GitHub redirects their template URLs. |
| `agents-walk` (the walk fixtures) | Move. |
| `agents-releases` (#2145, not made yet) | Make it in the organisation. |
| `www.alexecollins.com` and Alex's own apps | Stay with `alexec`. |

## Follow-ups

1. Daemon: repo alias for an owner that moved, so old refs and new events match (task, before the transfer).
2. Links to `agentloops-dev/Agents` in www, docs, skills, `deploy/` and the docs CNAME (task, after the transfer).
3. Go module path `github.com/agentloops-dev/agents/Go` (task, on a quiet day).

## Open questions for Alex

1. The plan: Free now, Team when #1064 makes the repo private?
2. Move the starters and `agents-walk` too?
3. Go for the transfer, in the order above?
