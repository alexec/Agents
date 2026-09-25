---
diataxis: how-to
devices: [mac]
description: Have an agent fix failing checks, answer review comments and resolve conflicts on your GitHub pull requests.
---

# Have an agent watch a pull request

For a project on GitHub, the project's page lists your open pull requests. With one click
you can have an agent step in whenever one of them needs something: a check fails, a
reviewer leaves comments, or it stops merging cleanly. The agent works in the pull
request's worktree, pushes its fix to the branch and replies to the comments, as you.

## Before you start

- A project cloned from GitHub (or GitHub Enterprise): its `origin` remote is on a host
  with `github` in the name. See [Add a project](add-a-project.md).
- The GitHub CLI, `gh`, installed on the Mac and signed in with an account that can read
  and push to the repository. In Terminal:

  ```sh
  brew install gh
  gh auth login
  ```

  Agents uses this sign-in and never asks for a token of its own.
- The pull request's branch checked out in a worktree of the project. Step 2 below can do
  that for you. See [Start an agent in its own worktree](start-in-a-worktree.md).

## Steps

1. Open the project's page and scroll to **Pull requests**. It lists your open pull
   requests on the repository, such as `example/repo`, newest first: the title and
   number, **Draft**, whether checks pass, fail or are running, what reviewers said, and
   **⚠ conflicts** when it no longer merges. Click a row to open it on GitHub.

   The list refreshes by itself every few minutes; the refresh button beside the heading
   fetches it now.
2. A pull request that says **Not checked out here** cannot be watched yet. Click **Check
   out into a worktree**. The row then names the worktree.
3. Click **Babysit my pull requests** beside the heading.

   This adds a workflow called **Babysit my pull requests** to the project. It watches
   every one of your open pull requests that has a worktree; there is nothing to set per
   pull request. The button becomes **Show babysitter**, which opens the workflow.
4. Leave it. When a check fails, a reviewer comments, or the pull request conflicts with
   its base, a new agent starts in that pull request's worktree with what changed:
   the failing checks and links to their logs, the comments with file and line, or the
   base it conflicts with. It fixes what it can, runs the build and tests, commits,
   pushes to the branch, and replies to each comment with what it did.

   The pull request's row says **Babysitting now** while it works, then **Babysat** and
   when. The agent is on the project's page like any other.
5. By default the agent edits files without asking, and asks before running builds,
   tests or git. Answer it as usual (see [Answer a question or a permission
   request](answer-a-question.md)), or change **Permission mode** on the workflow's page.

What the agent may do on GitHub is limited: push to that pull request's branch (never
force-push) and reply on that pull request. It cannot merge, close, approve or touch
anything else. Only comments from people with write access to the repository set it off;
anyone else's comments are ignored and never reach the agent.

**Stop watching**

- For one pull request: after three tries in a row with nothing new from anyone else, the
  row says **Babysitting stopped after 3 tries in a row**. Click **Resume** to let it try
  again.
- For all of them: open the workflow with **Show babysitter** and click **Archive**. See
  [Set up a workflow](set-up-a-workflow.md).

Pull requests are on the Mac only; iPhone and iPad show the agents the babysitter starts,
not the list.

## If it doesn't work

- **Can't see pull requests: the GitHub CLI isn't installed.** Run `brew install gh` in
  Terminal.
- **Can't see pull requests: gh isn't signed in.** Run the `gh auth login` command the
  line shows, in Terminal.
- **Can't see pull requests on example/repo with the account …** That account cannot read
  the repository. Sign `gh` in with one that can.
- **Couldn't reach GitHub** with a time: the list is from that time. It refreshes when
  GitHub answers again.
- The row says **Did not run —** and why, for example that the worktree has uncommitted
  changes or an agent is already working in it. Commit or archive, and it runs on the
  next change.
- No **Pull requests** section at all: the project's `origin` is not on GitHub.
