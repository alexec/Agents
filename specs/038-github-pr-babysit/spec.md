# Feature Specification: My Pull Requests, Babysat

**Feature Branch**: `038-github-pr-babysit`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "GitHub support for each project. We can already create projects from a Git repository. If it is on GitHub (not sure how to identify whether it is, perhaps we just support if the host is `*github*`?) we also show pull requests created by the current user in project view. If the worktree changes state, the user should be able to specify a workflow that runs on the PR (i.e. local worktree) that \"babysits\" the PR, e.g. fixing review comments, broken builds."

## Why this feature exists

An agent's work usually ends as a pull request. After that, the app stops helping. A reviewer
leaves comments, a check fails, main moves on and the branch no longer merges. The person finds
out from an email or a GitHub tab, goes back to the app, finds the worktree the branch is in,
starts an agent there, and pastes in what the reviewer said or what the build printed. Nothing
in that needs a decision from them. It is only carrying messages.

The app already has both halves. Projects are git checkouts. Agents work in worktrees on their
own branches (030). Workflows run an agent when something happens (008). What's missing is
knowing that the project lives on GitHub, knowing which pull requests are the person's, and
treating a change to one of them as something a workflow can fire on.

So a project on GitHub gets a list of the person's open pull requests. A workflow can be set to
run when one of those pull requests needs attention. It runs an agent in that pull request's
worktree, with what changed in the prompt, and the agent can push its fix and answer the
reviewer.

**This feature does not change what a workflow is.** A babysitting workflow is an ordinary
workflow file with new triggers. It is listed, archived, run by hand and capped like any other.

## Clarifications

### Session 2026-09-24

- Q: Which of the person's pull requests does a babysitting workflow watch? → A: All of their open pull requests in the project that have a local worktree. There is no opt-in for each pull request. A workflow with a pull-request trigger applies to every pull request that qualifies (FR-012). Archiving the workflow is how to stop it.
- Q: What may the babysitting agent do on GitHub by itself? → A: Push to the pull request's branch, and reply to review comments. Both act as the person's own account (FR-020 to FR-022).
- Q: How does the app tell that a project is on GitHub? → A: The host of the project's `origin` remote contains `github`. That covers github.com and GitHub Enterprise hosts such as `github.example.com` (FR-001).
- Q: Whose review comments start babysitting, given that comment text goes into the prompt of an agent that can push as the person? → A: Only comments from people with write access to the repository: its owner, members of the owning organisation, and collaborators. Anyone else's comment never fires a trigger and never goes into a prompt (FR-011a).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See my pull requests in the project (Priority: P1)

The person opens a project whose repository is on GitHub. Under the agents there is a Pull
requests section. It lists the pull requests they opened on that repository that are still
open. Each row shows the title and number, whether it is a draft, whether its checks pass, fail
or are still running, whether reviewers approved or asked for changes, and whether it conflicts
with its base. If the branch is checked out in one of the project's worktrees, the row names
that worktree. Clicking a row opens the pull request on GitHub.

**Why this priority**: Everything else depends on it. The list is also useful by itself: it
answers "what state are my PRs in" without leaving the app.

**Independent Test**: In a project cloned from a GitHub repository where the person has two open
pull requests, one with a failing check, and someone else has a third: open the project. Confirm
exactly the two are listed, the failing one says so, and the row whose branch is in a worktree
names that worktree. Open a project from a repository that is not on GitHub. Confirm it has no
Pull requests section.

**Acceptance Scenarios**:

1. **Given** a project whose `origin` host contains `github`, **When** the person opens it, **Then** a Pull requests section lists their open pull requests on that repository, newest first.
2. **Given** a project with no `origin`, or one whose host does not contain `github`, **When** it is opened, **Then** no Pull requests section appears and nothing about GitHub is shown.
3. **Given** a listed pull request, **When** the person looks at its row, **Then** they see its title, number, draft or not, check status (passing, failing, running, none), review status (approved, changes requested, commented, none), and whether it conflicts with its base.
4. **Given** a pull request whose branch is checked out in the project folder or one of its worktrees, **When** it is listed, **Then** its row names that worktree, and leads to the agents working there.
5. **Given** a pull request that is merged or closed, **When** the list next refreshes, **Then** it is gone from the list.
6. **Given** the Mac has no GitHub sign-in that can read the repository, **When** the project is opened, **Then** the section says in one line that the app cannot see pull requests and what would fix it, instead of an empty list.

---

### User Story 2 - A failing check or a review gets an agent, without me (Priority: P2)

The person has a workflow in the project with a pull-request trigger, such as "when my pull
request's checks fail" or "when my pull request gets review comments". A reviewer asks for a
change on one of their pull requests. The app notices, starts or resumes an agent in that pull
request's worktree, and gives it the reviewer's comments. The agent makes the change, pushes it
to the branch, and replies to each comment with what it did. The person sees the run on the
workflow's row and on the pull request's row. The agent is in the list like any other.

**Why this priority**: This is the babysitting the request is about. It depends on User Story 1
to know which pull requests are the person's and where they are checked out.

**Independent Test**: With a `new`-mode workflow triggered on failing checks: push a commit that
breaks a check to a pull request whose branch is in a worktree. Within one refresh of the check
failing, confirm an agent starts in that worktree. Its prompt names the pull request, the failing
check and a link to its log. When it finishes, a new commit is on the branch. Repeat with a
review comment, and confirm the agent's reply appears under the comment on GitHub.

**Acceptance Scenarios**:

1. **Given** a workflow with a pull-request trigger, **When** one of the person's open pull requests with a local worktree changes in the way the trigger names, **Then** the workflow fires once for that pull request.
2. **Given** a fire, **When** the agent runs, **Then** it works in that pull request's worktree, and its prompt says which pull request it is (number, title, link, branch) and what changed (the failing checks with links to their logs, the new review comments with author, file and line, or the base it now conflicts with).
3. **Given** the agent has committed a fix, **When** it pushes, **Then** the push goes to the pull request's own branch and nowhere else.
4. **Given** the fire was for review comments, **When** the agent has dealt with one, **Then** it can reply to that comment on GitHub.
5. **Given** a run a pull-request trigger started, **When** the person looks at the workflow's row or the pull request's row, **Then** they can see that it ran, for which pull request, and go to the agent.

---

### User Story 3 - It stops when it should (Priority: P3)

Babysitting acts on GitHub as the person, unattended. A fix that doesn't work triggers another
run. So does a reviewer who keeps commenting, or a check that fails for reasons no commit can
fix. The app must not let that turn into a stream of commits or comments. It stops, and it says
on the pull request why it stopped.

**Why this priority**: Without it, the person cannot leave P2 running while they are away, which
is the whole point of it.

**Independent Test**: Make a check that always fails. Confirm babysitting fires, the agent
pushes, the check fails again, and after the limit the pull request's row says babysitting
stopped after that many tries in a row. Then push a commit by hand and confirm babysitting is
live again.

**Acceptance Scenarios**:

1. **Given** a pull request that has been babysat the limit number of times in a row with no commit or comment from anyone else in between, **When** it changes again, **Then** the fire is refused, and the pull request's row says babysitting stopped and why.
2. **Given** babysitting stopped on a pull request, **When** someone else pushes to it or comments on it, or the person chooses Resume on its row, **Then** the count starts over.
3. **Given** comments and commits made by the babysitting agent, **When** the app looks for changes, **Then** those comments and commits never count as a change that fires a workflow.
4. **Given** a run in flight on a pull request, **When** that pull request changes again, **Then** no second run starts. When the run ends, the change is looked at again if it still holds.

---

### User Story 4 - A babysitter to start from (Priority: P4)

The person has never written a workflow. In the Pull requests section they choose Babysit my pull
requests. The app adds a workflow to the project's workflows folder that fires on failing checks,
review comments and conflicts. Its prompt tells the agent to fix what it can, push, and reply to
each comment. It is live at once. The person can open it and change it like any other.

**Why this priority**: The triggers in P2 are usable without it, by writing a file or asking an
agent to. This just makes the common case take one click.

**Independent Test**: In a GitHub project with no workflows, choose Babysit my pull requests.
Confirm a workflow file appears in the workflows folder, is listed on the project page with its
triggers in plain words, and fires on the next failing check.

**Acceptance Scenarios**:

1. **Given** a GitHub project, **When** the person chooses Babysit my pull requests, **Then** a workflow with the three pull-request triggers and a starter prompt is written to the project's workflows folder and is live.
2. **Given** that workflow already exists, **When** the person looks at the Pull requests section, **Then** it offers to show the existing workflow instead of adding a second.
3. **Given** the project's workflow ceiling is full, **When** the person chooses it, **Then** it is refused with the same reason the ceiling gives anywhere else.

---

### Edge Cases

- **Pull request with no local worktree**: listed, with an action to check its branch out into a new worktree (030's location and naming, but on the pull request's existing branch). Until it has one, a pull-request trigger does not fire for it. The refusal is recorded as "no local worktree" on the workflow's row, counted like other repeated refusals, not once per refresh.
- **Branch in the project folder itself**: counts as the pull request's worktree. The agent works in the project folder.
- **Worktree with uncommitted changes, or an agent already working in it**: the fire is refused with that reason. Babysitting must not mix its changes into work in progress. It is looked at again on the next refresh.
- **Local branch behind or diverged from the pull request**: the agent is told. It must bring the branch up to date without discarding the remote's commits, and must never force-push.
- **Pull requests from a fork**: listed. Babysitting pushes only if the person can push to the fork's branch; otherwise the push fails and the agent says so.
- **Draft pull requests**: listed and babysat like any other.
- **App not running when something changed**: the first refresh after it starts sees the pull request as it is now. A condition that still holds (checks failing, unanswered comments, a conflict) fires once. Unlike a missed schedule, the state is still there to act on.
- **Several pull requests change at once**: each is its own fire. The project and machine workflow ceilings (008 FR-031b) still apply. Ones over the ceiling are looked at again on the next refresh.
- **A reviewer comments on the pull request as a whole**, not a line: counts as a review comment. The reply goes on the pull request.
- **A comment from someone without write access** (anyone, on a public repository): never fires, and is left out of every prompt. Their text never reaches an agent that can push as the person.
- **The person's own comments**: never fire. The person and the babysitting agent use the same account, so the app cannot tell them apart. Any comment from that account counts as not new.
- **Sign-in lost or rate-limited mid-way**: the section says so. The list keeps showing the last good state, marked with when it was fetched. No fires happen on stale state.
- **Remote renamed or changed to a non-GitHub host**: the section disappears on the next refresh. Workflows with pull-request triggers stay listed and do not fire.

## Requirements *(mandatory)*

### Functional Requirements

**Knowing it is GitHub and who the person is**

- **FR-001**: A project MUST count as on GitHub when the host of its `origin` remote contains `github`, in HTTPS or SSH form. No other remote is looked at.
- **FR-002**: The app MUST use the GitHub sign-in the Mac already has for that host, and MUST NOT ask for or store a separate token. "The current user" is the account that sign-in belongs to.
- **FR-003**: When no sign-in can read the repository, the Pull requests section MUST say so in one line, naming what would fix it, and nothing else about GitHub may fail louder than that.

**The list**

- **FR-004**: A project on GitHub MUST show a Pull requests section listing the open pull requests the current user authored on that repository, newest first.
- **FR-005**: Each row MUST show title, number, draft or not, check status, review status and whether it conflicts with its base, and MUST open the pull request on GitHub when clicked.
- **FR-006**: A pull request MUST be matched to a worktree when its head branch is the branch checked out in the project folder or one of the project's worktrees. A matched row MUST name the worktree and lead to the agents working there.
- **FR-007**: An unmatched row MUST offer checking the branch out into a new worktree of the project.
- **FR-008**: The list MUST refresh on its own at least every five minutes while the app is running, whether or not a window is open. It MUST also refresh when the person asks and when the project is opened. It MUST NOT poll faster than once a minute per project.
- **FR-009**: When a refresh fails, the list MUST keep its last good state, marked with when that was fetched.
- **FR-010**: The list and its status MUST be shown on the Mac. Showing it on phone and iPad is out of scope (see Assumptions).

**Triggers**

- **FR-011**: Workflows MUST gain three triggers: *pull request checks failed* (a check that was not failing is now failing); *pull request review comments* (a review asking for changes, or a comment by anyone but the current user, that is newer than the last fire for that pull request, from someone with write access as FR-011a says); *pull request conflicts* (the pull request can no longer merge cleanly into its base).
- **FR-011a**: A review or comment MUST count for *pull request review comments* only when its author has write access to the repository (owner, organisation member or collaborator). Comments from anyone else MUST NOT fire a trigger and MUST NOT appear in a prompt.
- **FR-012**: A pull-request trigger MUST apply to every open pull request by the current user in that project that has a matched worktree. There is no per-pull-request opt-in.
- **FR-013**: Each trigger MUST fire once for each distinct change, not once per refresh. The same failing check run, the same comments, or the same conflict MUST NOT fire twice.
- **FR-014**: A workflow's in-flight rule (008 FR-023) MUST apply per pull request. A change that arrives while a run is in flight on that pull request MUST be looked at again when the run ends, and fire then if it still holds.
- **FR-015**: A fire MUST be refused, with the reason recorded, when the pull request has no matched worktree, when the worktree has uncommitted changes, or when another agent is working in it.
- **FR-016**: The project page MUST describe these triggers in plain words, as it does the others.

**What runs**

- **FR-017**: A run from a pull-request trigger MUST start or resume its agent in the pull request's worktree. `new` starts a fresh agent there. `standing` keeps one standing agent per workflow per pull request. `triggering` resumes the agent last active in that worktree, and is refused, as 008 FR-017 says, when there is none that can take a prompt.
- **FR-018**: The prompt MUST carry the pull request's number, title, link, head and base branches, and what changed: the failing checks with links to their logs, or the new comments with author, file, line and text, or the base it conflicts with.
- **FR-019**: The pull request's row and the workflow's row MUST both show the latest run for that pull request, and lead to its agent.

**What the agent may do on GitHub**

- **FR-020**: The babysitting agent MUST be able to push commits to the pull request's head branch using the Mac's sign-in.
- **FR-021**: The babysitting agent MUST be able to reply to review comments on that pull request, and to comment on the pull request itself. Replies appear as the current user.
- **FR-022**: The babysitting agent MUST NOT force-push, push to any other branch, merge, close, reopen, approve, change the base of, or edit the title or description of the pull request. It MUST NOT comment on any other pull request or issue.

**Stopping**

- **FR-023**: After three babysitting runs in a row on one pull request with no commit or comment from anyone else in between, further fires on it MUST be refused. Its row MUST say babysitting stopped, after how many tries, and offer Resume.
- **FR-024**: A commit or comment by anyone other than the current user, or choosing Resume, MUST reset that count.
- **FR-025**: Archiving the workflow MUST stop all its babysitting at once, as it stops any workflow (008 FR-031a).

**Starter**

- **FR-026**: The Pull requests section MUST offer Babysit my pull requests. It writes a workflow with the three pull-request triggers and a starter prompt to the project's workflows folder, subject to the workflow ceilings. When one like it already exists, it MUST offer to show that one instead.

### Key Entities

- **GitHub project**: a project whose `origin` host contains `github`. Has a repository (owner and name) and the current user.
- **Pull request**: one of the current user's open pull requests on that repository. Has number, title, link, head and base branch, draft flag, check status, review status, conflict status, and at most one matched worktree.
- **Pull-request change**: a new failing check, new review comments, or a new conflict on one pull request. It is what a pull-request trigger fires on, and the app remembers it so it doesn't fire twice.
- **Babysitting count**: per pull request, how many runs in a row happened with nobody else acting. Stops babysitting at the limit.
- **Workflow**: unchanged, apart from the three new trigger kinds.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Opening a GitHub project shows the person's open pull requests, with their status, within 5 seconds. Pull requests by other people never appear.
- **SC-002**: A check that starts failing, or a review comment, on a pull request with a worktree starts a babysitting agent within 6 minutes, with nobody at the Mac.
- **SC-003**: The agent's prompt alone is enough to act on. In a sample of runs, no agent has to ask which pull request, which check or which comment it is dealing with.
- **SC-004**: Zero force-pushes, zero pushes to branches other than the pull request's, and zero merges, closes or approvals by babysitting agents.
- **SC-005**: A pull request whose problem cannot be fixed gets at most three babysitting runs before it stops and says so.
- **SC-006**: A project not on GitHub looks and behaves exactly as it does today.

## Assumptions

- **`*github*` is the test.** It could misfire on a host that has `github` in its name but is not GitHub; such a project shows a one-line "cannot see pull requests" and nothing else. GitLab, Bitbucket and others are out of scope.
- **The Mac is signed in to GitHub already**, in whatever way its Git and GitHub tooling use (the same principle as 027 FR-010). No token entry and no OAuth flow in the app.
- **Only open pull requests authored by the current user.** Not ones they are asked to review, not ones assigned to them, not merged or closed ones.
- **Mac only.** The phone and iPad see babysitting agents in the agent list as they see any agent. They do not get the Pull requests section in this version.
- **Resolving review threads, requesting re-review, and marking a draft ready** are not done by the agent. Those stay with the person.
- **Refreshing is by polling, not webhooks.** The app runs on a Mac with no public address. Minutes of delay are acceptable (SC-002).
- **Checkout of an unmatched pull request** reuses 030's worktree location. The branch is the pull request's existing branch, not a new `agents/` branch.
- **The limit of three runs in a row** is fixed in this version, matching 008's chain-depth default.
