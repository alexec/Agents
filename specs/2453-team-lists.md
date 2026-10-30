# 2453: Pull requests and Issues for a team

Issue #2453. The Pull requests, Merge requests and Issues pages of the github, gitlab and
linear servers put each row in a section by how it relates to the person who looks at it.

## The viewer

The viewer is the login of the server's connection: the machine's user (one user per
machine, #1117). The server asks the provider who that is (GitHub's `viewer`). It needs no
call to the control plane.

## The four sections

Each list has four sections, in this order. A section with no rows is left out.

| Section | Pull or merge request | Issue |
|---|---|---|
| **Needs you** | a review is requested from the viewer; or the viewer's own, with failing checks, a conflict, or changes requested | assigned to the viewer |
| **Yours** | by the viewer, and nothing above | by the viewer, and not assigned to the viewer |
| **Team** | by a member, owner or collaborator of the repo, or by a bot | the same |
| **Others** | by anyone else: an outside contributor, a first-time contributor, a deleted account | the same |

- A row is in one section only: the first one, in this order, that it fits.
- Team and Others use #728's trust words: GitHub's `authorAssociation` (`OWNER`, `MEMBER`,
  `COLLABORATOR` are the team). A bot is in Team, with a **bot** pill on its name.
- An agent on one of the viewer's machines uses the viewer's connection, so its PRs are
  by the viewer: they are in Yours, or in Needs you.
- In a section, the rows keep the list's order (newest created first).
- With one person on a repository that only that person works on, Team and Others are
  empty: the page is as before, with Needs you on top.

## What the tool gives

`show_pull_requests` and `show_issues` give, on each row, `section` (`needs_you`, `yours`,
`team` or `others`) and `authorBot` when the author is a bot; on the result, `viewer`. The
pages draw the sections from `section` and keep no rules of their own.

`attention`, the sidebar's tinted count (#2033), is the number of rows in Needs you: on
Pull requests, the PRs that need the viewer (before: only the viewer's PRs with failing
checks); on Issues, the issues assigned to the viewer (before: none).

## Decisions

- Decided: bots go in Team, with a **bot** pill, not in a section of their own, because
  that is the issue's recommendation and keeps the page short. Alex can overrule.
- Decided: Start Agent on an issue keeps `--add-assignee @me`, because `@me` is the
  machine's own login, which is right on a bot's machine too. Alex can overrule.
- Decided: Linear's Needs you is "assigned to you" only, because Linear has no review.
  Alex can overrule.
- Decided: a review requested from a team the viewer is on is not Needs you yet, because
  GitHub's `reviewRequests` names the team, not its members, and a team's member list
  takes another call and a scope. Alex can overrule.

## Parts, one lane each

1. **This part (#2453):** the github server: sections, the bot pill and the Needs you
   count, from GitHub's own data.
2. **The gitlab server (#2952):** the same on Merge requests and Issues (GitLab's `reviewers`,
   `assignees`, and the project's members for Team).
3. **The linear server (#2950):** Issues: Needs you (assigned to you), Yours, Team (the
   workspace's members), Others.
4. **The people map (#2951):** the host passes the control plane's people and bots, with their
   logins, in the feeding tool's `_meta`, so a row names a person as the control plane
   knows them, Team is "people on this control plane", and the viewer's own sessions show
   "An agent is on it" (session label `#n` or `P#n`) with a link. A person who signed in
   with Google or Apple sets a GitHub (GitLab, Linear) login in Settings ▸ You, filled in
   from the machine's connection when it is signed in.

## Clients

The pages are the servers' own HTML, which the Mac window, the Remote and the web page all
draw. One change covers the three. The section headings and the bot pill must fit the
Remote's narrow width.
