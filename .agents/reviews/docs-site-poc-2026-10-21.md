# Docs site PoC: docs.agentloops.dev (#1914)

2026-10-21. A spike for #1549: serve the docs site at `https://docs.agentloops.dev/`.

## Result

**It serves.** `https://docs.agentloops.dev/` serves the site from GitHub Pages, with a
Let's Encrypt certificate for `docs.agentloops.dev` (to 2027-01-19). HTTPS is enforced.

## What was done

| Step | How | State |
| --- | --- | --- |
| DNS | `deploy/cloudflare/dns.sh --names docs --cname alexec.github.io` (new `--cname` mode): CNAME `docs` → `alexec.github.io`, DNS only | made |
| Pages custom domain | `gh api -X PUT repos/alexec/Agents/pages -f cname=docs.agentloops.dev` | set |
| Certificate | Pages asked Let's Encrypt by itself, in under a minute | approved |
| Enforce HTTPS | `gh api -X PUT repos/alexec/Agents/pages -F https_enforced=true` | on |
| `docs/CNAME` | `docs.agentloops.dev` (the generator copies it to `site/`) | this PR |
| `site_url` | `https://docs.agentloops.dev/` in `mkdocs.yml` | this PR |

No step needed Alex. The Keychain item `agents-cloudflare-token` already had DNS rights for
the zone.

To undo: `gh api -X PUT repos/alexec/Agents/pages -f cname=` (no domain), then delete the
`docs` CNAME at Cloudflare, then revert this PR.

## Does it build

**Yes.** `scripts/docs-check.py` is clean (83 pages, 10 pictures), and the strict Zensical
build (`scripts/docs.sh check`) runs in the `docs-check` job on this PR and in
`docs-publish` on `main`. The site that serves now is the one `docs-publish` built from `main`
before this PR: Pages needs no new build for a custom domain. `docs/CNAME` does nothing for a
site that Actions publishes (the API setting is what counts), but it keeps the domain written
in the repo.

## Do the old links redirect

**Yes.** Pages sends every `alexec.github.io/Agents/<path>` to `docs.agentloops.dev/<path>`
with a 301, as #1549 said it would. Checked on 2026-10-21:

| Old link | Goes to |
| --- | --- |
| `https://alexec.github.io/Agents/` | `https://docs.agentloops.dev/` (301) |
| `…/Agents/how-to/add-a-project/` | `…/how-to/add-a-project/` (301), which serves 200 |
| `…/Agents/assets/logo.png`, `…/Agents/sitemap.xml` | the same path on the new name (301) |
| `…/Agents/no-such-page/` | the same path (301), then the site's 404 |

For some minutes after HTTPS was enforced, a few redirects went to `http://` and the CDN
served `http://docs.agentloops.dev/` without a redirect to HTTPS. That is the Pages CDN cache;
it clears by itself.

Until this PR merges, each page's canonical link and the sitemap still say
`alexec.github.io/Agents/`, because they come from `site_url`. The next publish from `main`
fixes them.

## Shipped features with no page

From the release notes v0.1.0 to v0.7.0, the feature matrix, the integrations page and `main`
since v0.7.0, compared with every page in `docs/`. A table row or a mention does not count as
a page. Most important first in each group. This list is the work for 0.10 (#1549).

### Integrations

1. **GitHub**: Connect GitHub (device flow, #1566), Connect your tools (#1592, #1594), the
   Pull requests and Issues views, the PR page (Comment, Merge, Approve, Request Changes, Ask
   the Agent to Fix), Create Pull Request (#1522, #713, #901–#906), Start Agent on a GitHub
   issue (#854), the CodeRabbit block (#1588, #1344). How-to: "Use GitHub".
2. **GitLab**, all of v0.7.0: Connect GitLab (device flow or access token, #1735, #1905), the
   merge request, issue and pipeline views (#1642), tasks, code review and CI from GitLab
   (#1737). How-to: "Use GitLab".
3. **Cloud workspace providers by API**: AWS EC2 (#1640), Google Compute Engine and
   Workstations (#1705); DigitalOcean, Codespaces and Coder (#1637) are in the reference only.
   How-to: "Set up a cloud workspace provider".
4. **Connector levels and "Made by Agents"** (#1520, #1428), now only in `integrations.md`.
   Explanation.

### Control plane and hosting

5. **Hosted sign-up for a user**: sign up with GitHub, the account page, Open in This Browser,
   Delete Account (#1807, #1827). `run-the-hosted-service` is for the operator. Tutorial.
6. **Relay for my devices** (#825, #902): how to turn it on and off. How-to.
7. **Capabilities**: a client shows only what its host can do, and an old host says so (#1748,
   #1891). A section in `explanation/versions`.

### Mac window (most are on all three clients)

8. **Find in Chat and session search** (#1590, #1532, #1600, #1696). How-to.
9. **Review page and approvals in Needs You** (#785, #1512). How-to.
10. **Usage, Cost and Time pages** (#828, #860, #1006, #1098). How-to.
11. **Reading a chat**: Show thoughts (#1734), where a chat opens (#1302), the plan card (#777).
    How-to.
12. **The sidebar**: smart groups, Activity, sessions under the session that started them, the
    Workflows fold, read and unread (#922, #818, #850, #886, #1363). Reference.
13. **The prompt bar**: earlier prompts with Up and Down (#1584), edit a queued prompt (#1586),
    quote a reply (#1587). Sections in `send-while-an-agent-works`.
14. **The file editor with language servers** (#1602, #1613, #1714, #1717). How-to.
15. **The simulator pane** (#1595, #1596, #1598, #1706, #1711). How-to.
16. **A shell command from a reply** (#1593, #1533). A section in `use-a-shell`.
17. **Undo Archive** (#1599, #1694, #1723). A section in `archive-and-stop`.
18. **Windows of their own**: a session or a project in its own window, an iPad scene (#889,
    #895, #1102). How-to.
19. **Rename a session** (#769, #1519). A section in `label-a-session`.
20. **The Get started checklist** (#1022, #1038, #1070). Reference.
21. **The new session form**: the Huddle (#1040), personas (#775, #918). A section in
    `first-agent`.
22. **Charts and Mermaid diagrams** in shown files and Markdown (#861, #908). Reference.
23. **Text size and Page zoom** (#787, #1476), **versions in Settings** (#1765). Rows in
    `reference/settings`.

### Remote (iPhone and iPad)

24. **Live Activities** for a turn sent from the Remote (#1745, #1832, #1877, #1885), with push
    from the control plane (#1487, #1744). How-to and an explanation.
25. **Remote gestures**: the iPhone ··· menu (#1020), the edge pull for panes (#1580), the
    project terminal on iPad (#418). Reference.

### Web page

26. **What the web can do now**: Settings, Review, Simulator, Providers, the GitHub, GitLab and
    Linear views, workspace providers (#1820). Rewrite part of `use-agents-in-a-browser` and
    add `web` to `add-a-workspace-provider`.

### Workflows

27. **The workflow page**: Activity and Configuration (#868), why each run started (#1582), Run
    now, a failed workflow in Needs You (#1036). How-to.
28. **A workflow that refers to a skill** (#1583), **manage_workflows run** (#1526). A section
    in `set-up-a-workflow`.

### Pages that are wrong now

- `how-to/use-agents-in-a-browser.md:71` reads a chat "at **Outcome**, **Steps** or
  **Details**"; v0.4.0 removed those (#1027, #1337). The same page says the web has no
  Settings, but `Web/src/views/Settings.tsx` is there.
- `reference/keyboard-shortcuts.md:48`: Command-F is Find in Chat since #1532 and #1590; Find
  Session moved to Option-Command-F when a chat is open.
- `reference/settings.md:40` says every smart group is on at first; Working and Unread start
  off (#990). The same page names "how much of a turn shows", which Show thoughts (#1734)
  replaced.
- `how-to/add-a-workspace-provider.md` says `devices: [mac, server]`; the web has it since
  #1820.
- The connector pages' file names and nav still say "MCP server" while their titles say
  "connector" (#1510).

## Left for #1549 (0.10)

- The help links in the three clients: `Shared/UI/HelpSite.swift` (Mac and Remote) and
  `Web/src/views/Sidebar.tsx`.
- `README.md` links and the repo homepage (`gh repo edit --homepage`). The old links redirect,
  so nothing is broken meanwhile.
- The docs-hosting row in `docs/reference/integrations.md`.
- The missing pages above.
