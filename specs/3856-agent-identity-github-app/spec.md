# Agent identity: GitHub App permissions and tokens (spike #3856)

Part of epic #3855. This spike ends in decisions, not in product code. The children of the
epic build what this says.

The github MCP server (`Go/internal/githubmcp`, `Go/cmd/github-mcp`) embeds the official
`github-mcp-server` as a library, with the toolsets `context, repos, issues, pull_requests,
actions, labels` (`upstream.go:26`), and adds its own tools and its events. It reads its
token from the host's connections store (`githubmcp.Token()`, `rest.go:1142`). Today that
token is a user token of the GitHub App `agents-loops`, from the device flow
(`Go/internal/connections/github.go`).

Two identities follow from the epic's design:

- **User token** (design 1, the default): the `agents-loops` App, acting as the person.
- **Bot** (design 2, optional): `<login>-agents[bot]`, an App that the person makes with the
  manifest flow, with installation tokens made from its private key on the person's machine.

## 1. Permissions per tool

"Write" includes read. Metadata (read) is in every App and is not listed.

| Tools and events | GitHub permission |
|---|---|
| `show_issues`, `show_issue_details`, `issue_read`, `list_issues`, `search_issues`, events `issue.*`, `pr.labelled`, `pr.unlabelled`, `pr.commented` | Issues: read |
| `issue_write`, `add_issue_comment`, `update_issue_comment`, `sub_issue_write`, `label_write`, `coderabbit_review`, `coderabbit_resolve`, `SetLabels`, `SetState`, `CreateIssue`, `AddSubIssue`, `SetBlockedBy` | Issues: write |
| `show_pull_requests`, `show_pull_request`, `show_pull_request_diff`, `pull_request_read`, `list_pull_requests`, `search_pull_requests`, events `pr.*`, `review.*` | Pull requests: read |
| `create_pull_request`, `update_pull_request`, `update_pull_request_branch`, `add_reply_to_pull_request_comment`, `coderabbit_reply` | Pull requests: write |
| `get_file_contents`, `list_branches`, `list_commits`, `get_commit`, `list_tags`, `get_tag`, releases, `search_code`, `Compare`, `Tags` | Contents: read |
| `create_or_update_file`, `delete_file`, `push_files`, `create_branch`, a git push over HTTPS; merge and the branch delete after it (`merge_pr`, `MergeBy`, auto-merge) | Contents: write (with Pull requests: write for a merge) |
| The checks in `show_pull_request`, `show_pull_requests`, `run.completed` (check runs, annotations) | Checks: read |
| The status rollup in the same views (`statusCheckRollup` includes commit statuses, for example CodeRabbit's) | Commit statuses: read |
| `failed_log`, `actions_list`, `actions_get`, `get_job_logs`, events `checks.failed`, `checks.passed`, `run.completed`, `deploy.waiting` | Actions: read |
| `rerun_failed`, `actions_run_trigger` (dispatch, rerun, cancel) | Actions: write |
| `ReviewDeployments` (Approve or Reject a waiting deploy) | Deployments: write |
| `SetActionsSecret` (`set_ci_secret`) | Secrets: write |
| `SetActionsVariable` (`set_ci_variable`) | Variables: write |
| `SetEnvironmentGate` (`set_environment_gate`), `MakeRepository`, `create_repository`, `fork_repository` | Administration: write |
| `get_teams`, `get_team_members`, the team look-up in `SetEnvironmentGate` | Members: read (organisation) |
| A push or file write under `.github/workflows/` | Workflows: write |
| `get_me`, `AppReach` (`user/installations`) | none (user token only) |

**Question 1: can all of them work with contents, pull requests, issues and checks only?
No.** The read views and the events also need **Commit statuses: read** and **Actions:
read**; `rerun_failed` and `actions_run_trigger` need **Actions: write**. The rest of the
table (deploys, secrets, variables, environments, new repositories, teams, workflow files)
needs the permissions that the epic forbids for a bot.

### The bot's manifest

```json
"default_permissions": {
  "contents": "write",
  "pull_requests": "write",
  "issues": "write",
  "checks": "read",
  "statuses": "read",
  "actions": "write"
},
"default_events": []
```

The manifest has no `hook_attributes`: the server polls (`events.go`, every 30 s) and needs no
webhook. `request_oauth_on_install` is false.

Decided: the bot gets **Actions: write**, because a lane reruns failed checks every day
(AGENTS.md, "Questions that already have an answer"), and Actions: write gives no secret, no
environment and no deploy approval: an environment's required reviewers still stop a
dispatched deploy. Alex can overrule; then `rerun_failed` uses the user token.

Decided: **Checks: read, not write**, because no tool makes a check run. Alex can overrule.

Decided: the tools that need a forbidden permission (`set_ci_secret`, `set_ci_variable`,
`set_environment_gate`, `make_app_repository`, deploy Approve and Reject, `merge_pr` and
`review_pr` in the hosted views, teams, workflow files) **keep the person's user token** of
`agents-loops`, and never use the bot. They are person actions already, or tools that the app
gates. GitHub limits a user token to the person's rights (question 3), so this gives the
agents no more than the person. Alex can overrule.

With the bot, these upstream tools fail with "Resource not accessible by integration", and
that is correct: `create_repository`, `fork_repository`, `get_teams`, `get_team_members`, and a
`push_files` or `create_or_update_file` under `.github/workflows/`. The test of the epic's
acceptance criterion "Small, fixed permissions" reads the manifest and fails on any key that
is not in the list above.

**A cost for this repo:** with no Workflows permission, a bot cannot change
`.github/workflows/`. The `ci-speed` skill and every lane that edits CI must push as the
person. This is the intent: a bot that can change a workflow can change the required check.

### The `agents-loops` App (user tokens)

The user token can only do what the App also has. For every tool above to work, the App
needs every permission in the table except Workflows (a lane pushes a workflow file with
git, as the person): Contents, Pull requests, Issues (write); Checks, Commit statuses
(read); Actions, Deployments, Secrets, Variables, Administration (write); Members (read),
for team reviewers in `set_environment_gate`. `docs/how-to/use-github.md` already
names Deployments and Administration. Alex sets these on github.com; this spike changes
nothing there.

## 2. Long sessions: token refresh

**Yes, and it is built.** The device flow (`connections/github.go:184-277`) gives an access
token that ends after 8 hours and a single-use refresh token that ends after 6 months. Only the
host refreshes: `RefreshIfDue` (`connections/keep.go:35-63`) renews a token 10 minutes before
its end, from the agentsd loop (`agentsd/connections.go:861`). The github MCP server never
refreshes; `TokenReader` reads the store again at most once a minute, or at once when its token
has ended (`keep.go:74-110`). So a session of any length keeps a valid token.

The refresh token is kept with the access token, in one item:

- **Mac:** a Keychain generic password, service `agents.connection.<hash of the root>`,
  account `github` (`connections/store.go:145-150, 226-318`), written through
  `security -i` on stdin, so the token is never in an argument list.
- **Linux:** `~/.agents-secrets/connections.json`, mode 0600 in a 0700 folder
  (`store.go:114, 154-222`).

When a refresh is refused or the refresh token has ended, the connection is marked
`SignInAgain` and the person signs in again (`keep.go:40-53`).

**Cost:** none for the MCP server. A tool that is given the token once at the start, such
as `gh` with `GH_TOKEN` set in the agent's environment, has a dead token after 8 hours. It
must read the token at each call (a `gh` and git credential helper that asks the host). See
question 3.

**The bot** has no refresh token. An installation token ends after 1 hour. The host makes a
new one when it needs one, from a JWT signed with the private key on that machine. Its cost is
the same loop as the refresh above, with the key in the same store.

## 3. The App's badge and the overlap

**Overlap: yes.** GitHub limits a user token to what both the person and the App can
access, and to the repositories that the App is installed on. An agent with the user token can
never do more than the person, and can do less.

**Badge: yes for comments, issues, pull requests and reviews; no for commits.** An issue, a
comment, a pull request or a review made with a user token shows the person as the author and
the App's badge ("with agents-loops"). The REST API gives it as `performed_via_github_app`
on issues and issue comments. A commit has no badge: a commit made through the contents API
names the person, and a git push keeps the local author. The epic's commit trailer is
therefore necessary.

**Cost (the largest finding):** agents in this repo do not write through the MCP server.
They write with `gh` (`gh pr create`, `gh issue comment`, `gh pr merge`) and git, with the
person's own `gh` token. Those posts get no badge. For the badge, and to replace the
`<!-- agent -->` marker with `performed_via_github_app.slug`, the agent's `gh` and git must
use the App's token, through a credential helper that asks the host for the current token
(question 2). This needs a child of the epic.

## 4. A one-click manifest setup

**Yes, from both clients, with the hand-back page that the Linear sign-in uses.**

1. The client opens a page that posts a form to
   `https://github.com/settings/apps/new?state=<state>` (or
   `https://github.com/organizations/<org>/settings/apps/new?state=<state>`) with the
   manifest. Its `redirect_url` is the static hand-back page
   `https://oauth.agentloops.dev/oauth/callback` (`connections/linear.go:30`,
   `deploy/site/`). The state carries the web page's origin, as `NewPKCE` does
   (`linear.go:95-118`).
2. The person chooses **Create GitHub App** on github.com. GitHub sends the browser to the
   hand-back page with `?code=…&state=…`.
3. The hand-back page gives the code to `agents://oauth/callback` (Mac, and the Remote) or by
   `postMessage` to the web page's origin. The client gives it to the person's machine over
   the existing connection.
4. **The machine**, never the client or the control plane, calls
   `POST https://api.github.com/app-manifests/<code>/conversions` (no authentication, within
   one hour). The answer has the App's id, slug, client id, client secret, webhook secret and
   private key. The machine seals the key to the person's machines (#3401).
5. The client opens `https://github.com/apps/<slug>/installations/new` to install the App
   on the repositories. On an organisation that does not let members install, GitHub sends
   the request to the org owner.

A manifest code has no PKCE verifier: whoever has the code gets the key. The hand-back page
keeps no log (`deploy/site/site.caddy`), and the machine converts the code at once. A code
can be converted only once, so when the machine's conversion fails because the code was
used, the setup says that the key may be stolen and tells the person to delete the App. A
stolen code is seen, not silent. Principle 6 holds: the control plane routes the code and
never holds the key.

Decided: the App is **private** ("Only on this account", `"public": false`) when the
repositories belong to the person's own account, and **public** when an organisation must
install it, because GitHub lets only the owning account install a private App. A public App
that another account installs gives the person's bot access to that account's repositories
only, and only by that account's choice. Alex can overrule.

Decided: the App's name is `<login>-agents`, so the bot is `<login>-agents[bot]`, because
App names are unique on GitHub and at most 34 characters. On a name that is taken, the setup
adds a number. Alex can overrule.

**Cost:** a new manifest form page for each client (Mac, web; the Remote is tier mac+web), a
conversion method on the host, and the hand-back page accepting a state with no PKCE.

## 5. The required check as a reusable workflow

**Yes, with no secret, but it is a short job, not one line.** A repository adds:

```yaml
# .github/workflows/agent-bots.yml
on:
  pull_request:
  pull_request_review:
permissions:
  contents: read
  pull-requests: read
jobs:
  agent-bots:
    uses: alexec/Agents/.github/workflows/agent-bot-check.yml@v1
```

The reusable workflow uses only `GITHUB_TOKEN`:

- It reads `.github/agent-bots.yml` from the **base** branch through the API, never from the
  pull request's head, so a pull request cannot change its own rules.
- When the pull request's author is a bot in the file, it reads the owner's access with
  `GET repos/{r}/collaborators/{owner}/permission`. Under write, it fails, and says that the
  org owner must remove the install.
- It reads `GET repos/{r}/pulls/{n}/reviews`. It ignores reviews by bots, and fails when the
  only approvals are the owner's (a repository can turn this rule off in the file).
- `pull_request_review` runs it again after each review, on the head commit, so the
  required check follows the reviews.

The required check's name is `agent-bots / <job>`. A ruleset or branch protection makes it
required. On GitHub Team and Enterprise, an organisation ruleset can require the workflow on
every repository, with no file in each one.

**Cost:** a public repository that holds the workflow at a pinned tag (this repository is
public), and one child to build it. The caller's file is under `.github/workflows/`, which
the bot cannot change (question 1), so a bot cannot turn its own check off.

To check in that child, on a scratch repository: that `GITHUB_TOKEN` can read a
collaborator's permission on a personal and an organisation repository, and that the run of
`pull_request_review` reports to the same required check.

## Children that this spike finds

- Write through the App's token: a `gh` and git credential helper that asks the host for
  the current token, so that agents' posts get the badge (questions 2 and 3).
- The manifest setup and the conversion on the machine (question 4).
- The reusable check workflow (question 5).
- The manifest test: it fails on any permission not in the list (question 1).
