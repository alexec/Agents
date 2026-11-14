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
| The Go module path `github.com/agentloops-dev/agents/Go` (about 2000 imports) | Nothing outside this repo imports it, and the module is never fetched by its path. A rename is a large change across many files; do it on a quiet day, on its own issue (follow-up 3). |
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
| The agents' GitHub App `alexec-agents` (#3858, #3926) | **Does not move.** It is owned by the user `alexec` and is private, so it cannot be installed on another account. | After Alex's yes, an agent transfers the App's ownership to `agentloops-dev` and installs it on the organisation for this repo, in the agents' browser ("Transfer the agents' GitHub App", below; #5065). The App's id and key stay; the credential helper finds the new installation by itself (`connections/githubbot.go` lists `/app/installations`). |
| Container image `ghcr.io/alexec/agents-control` (#2140) | **Does not move.** A package belongs to its owner, not the repo. | The first release after the move pushes `ghcr.io/agentloops-dev/agents-control`. After Alex's yes by a form, an agent makes that package public (#5066). The live control plane then pulls the new name (`deploy/gcp/common.sh`). |
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
3. **Alex says yes, by a form; an agent transfers the agents' GitHub App** to the
   organisation and installs it there, in the agents' browser ("Transfer the agents' GitHub
   App", below; #5065). Do it just before step 4, with no lane running.
4. **Alex says yes, by a form; an agent transfers `alexec/Agents`** to `agentloops-dev`
   with `scripts/github-transfer.sh alexec/Agents agentloops-dev` (#5063): Alex's own `gh`,
   `POST /repos/{owner}/{repo}/transfer`, then a wait until the new name answers. Run it
   with `--dry-run` first: that does only the checks (the `repo` scope, admin on the repo,
   `alexec` an admin of the organisation, no repo of that name there). No lane runs at that
   time: the lead pauses new lanes and waits for open PRs to land or park. The other repos
   (step 8) go the same way, each after its own yes.
5. **An agent checks** (one lane): `origin` updated, a PR auto-merges, the ruleset and the
   environments are there, the bot posts as `alexec-agents[bot]`, a release dry run passes.
6. **The links PR lands** (follow-up 2): www, mkdocs, docs, skills, `deploy/` GHCR name,
   the docs CNAME.
7. **The next release** pushes `ghcr.io/agentloops-dev/agents-control`. The release skill
   (step 8, item 2, #5066) finds it private with
   `.agents/skills/release/scripts/ghcr-public.sh`; Alex says yes by a form (it cannot be
   undone); then an agent makes it public in the agents' browser, signed in as `alexec`
   (package settings ▸ Change visibility; no API), and checks again. Only then does the
   release's deploy move the live control plane to the new image.
8. **The other repos move** (if Alex says so): see below.

## Transfer the agents' GitHub App (#5065)

The runbook for step 3 of the order. It is for the bot App `alexec-agents` (#3858, #3926)
only, not for `agents-loops`, the App of the GitHub connection (#1335): that one stays
with `alexec`, and #5091 asks about it separately. GitHub has no API that transfers an App
or installs one, so an agent does it in the agents' browser (`browser_*`), signed in as
`alexec`.

**Before:**

1. **Alex's yes, by a form** (`ask_question`), each time. "Not now" is the first option. A
   transfer is hard to undo: only an owner of `agentloops-dev` can transfer it back.
2. **Tell the #4925 lead** (`message_session`) to start no new lane, as for step 4. Between
   the App's transfer and the repo's, the bot cannot reach `alexec/Agents`: GitHub
   uninstalls the App from the old owner when the transfer completes ("this app will be
   automatically uninstalled from your account"). So steps 3 and 4 go one right after the
   other.
3. **Write down the state now**, to compare after:
   - `curl -s https://api.github.com/apps/alexec-agents` answers 404 (a private App).
   - Alex's own `gh` (`/usr/local/bin/gh`, `GH_TOKEN` unset):
     `gh api orgs/agentloops-dev/installations --jq '.installations[].app_slug'` does not
     list `alexec-agents`.
   - The bot's installations, on the Mac's agents' bot row (Connectors ▸ Your connections)
     (the daemon lists `GET /app/installations`): one, on `alexec`. Note its id.

**Steps:**

1. `browser_navigate` to `https://github.com/settings/apps/alexec-agents/advanced`.
2. GitHub asks for "Confirm access" (sudo). Pass it with the agents' passkey: the sign-up
   skill's "GitHub sudo on `alexec`" (#5096): open the page first, then `browser_passkey`
   with `GITHUB_ALEXEC_PASSKEY`, load the page again, Use your passkey ▸ Use passkey
   (#5196). The secret is Ask before use, so the call waits for Alex's approval in the app.
   When the account is still in sudo mode from an earlier step, GitHub does not ask.
3. Under **Danger zone**, **Transfer ownership**. Type the App's name, `alexec-agents`, and
   the new owner, `agentloops-dev` (choose the **Organization** in the list, not the user
   `agentloops-dev-agent`), then **Transfer this GitHub App**.
4. GitHub opens the organisation's side, `organizations/agentloops-dev/settings/apps/transfers/<id>`,
   because `alexec` is its owner. Check the permissions it lists, then **Complete transfer**.
5. `browser_navigate` to `https://github.com/apps/alexec-agents/installations/new`.
   **Continue** as `alexec`, then the page installs on `agentloops-dev`. Choose **Only select repositories**: the repos that moved (`Agents` first;
   the others when they move). **Install**. Before `Agents` moves, the organisation has no
   repo to choose: then choose **All repositories**, and set it to the moved repos after
   step 4 of the order.
6. `browser_passkey` with `off`, if it was on.

**Done on 2026-11-13** (#5065), after Alex's yes by a form: installation 180039971 on
`alexec` went; installation 181675598 on `agentloops-dev`, All repositories.

**Checks after:**

- `https://github.com/organizations/agentloops-dev/settings/apps` lists `alexec-agents`,
  and `github.com/settings/apps` no longer does.
- Alex's own `gh`: `gh api orgs/agentloops-dev/installations --jq '.installations[] | select(.app_slug=="alexec-agents") | {id, repository_selection}'`
  gives one installation.
- The agents' bot row lists `agentloops-dev`. The App's id and
  private key do not change, so `~/.agents` needs no change: the daemon makes an
  installation token for each repo's owner (`connections/githubbot.go`, `BotTokens.For`).
  `github.com/settings/installations` no longer lists it on `alexec`, so the bot cannot
  post on `alexec/*` until each repo moves.
- After the repo moves: the bot pushes a scratch branch on `agentloops-dev/Agents` and
  deletes it, and `gh pr view <n> --json author` on the next lane's PR says
  `app/alexec-agents`.

**If it goes wrong:** an owner of `agentloops-dev` transfers the App back to `alexec` the
same way (the organisation's App settings ▸ Advanced ▸ Transfer ownership).

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
4. Repo name `agent-loops` (#5296, done 2026-11-13): `agentloops-dev/Agents` is now
   `agentloops-dev/agent-loops`, and `origin` is
   `https://github.com/agentloops-dev/agent-loops.git` in the main checkout. The links and
   the Go module path, which follow-ups 2 and 3 set to `agentloops-dev/agents`, change
   again in #5320.

## Open questions for Alex

1. The plan: Free now, Team when #1064 makes the repo private?
2. Move the starters and `agents-walk` too?
3. Go for the transfer, in the order above?

## Alex's answer

Alex, 2026-11-12, by form:

1. **Plan: Free now**, Team when #1064 makes the repo private.
2. **Move too:** `web-service-starter`, `iphone-app-starter` and `agents-walk`. Make
   `agents-releases` (#2145) in the organisation.
3. **Go for the transfer, in the order above.**
4. **The `release.yml` change waits for #4291:** Alex gives the agents' bot the Workflows
   permission first; then a lane pushes it as the bot. The transfer waits for it too.
