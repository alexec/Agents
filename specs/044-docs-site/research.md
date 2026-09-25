# Research: 044 Docs Site

## R1 — Which generator turns the Markdown into a site

**Decision**: Zensical, pinned to an exact version (0.0.65 on 2026-09-25) and run with `uvx zensical`.

**Rationale**:
- It is the successor to Material for MkDocs, from the same team, and it covers every site-level requirement
  in the spec without add-ons:
  - search built in (FR-015);
  - light and dark that follow the reader's preference (FR-014);
  - phone layout (FR-014, SC-007);
  - redirects built in with `redirect_maps`, including anchors (FR-015);
  - navigation tabs that show the section on every page (FR-004).
- Tried on this Mac on 2026-09-25: `zensical build --strict` exited 1 on a link to a page that does not exist,
  and exited 0 on a clean site.
- It needs Python only, through `uv`, which is already installed here and has a first-party GitHub Action.
  There is no Node toolchain to keep current beside the Swift one.
- The source stays plain Markdown with front matter, so it reads well in the repository and in the app's own
  files pane (041).

**Risk**: Zensical is still 0.x. A dependable 0.1.0 line is announced for 2026-11-05. Material for MkDocs, its
predecessor, is in maintenance until 2027-05-05. This is contained two ways:
- the version is pinned exactly;
- the config is a root `mkdocs.yml`, which Zensical reads (R2). If Zensical breaks us, `uvx --from mkdocs-material
  mkdocs build --strict` builds the same source, a one-line change in `scripts/docs.sh`.

**Alternatives considered**:
- **Material for MkDocs**: mature, but new work there ends in 2027. Choosing it means a migration we can
  already see coming.
- **Astro Starlight** (0.42, active): good search (Pagefind), with link validation through a community plugin.
  It adds Node, `package.json`, a lockfile and `node_modules` to a Swift repository, and pages become `.mdx`-leaning.
  Heavier for no gain here.
- **Docusaurus 3**: React and Node, the heaviest option. It suits versioned docs, which the spec rules out.
- **Jekyll (Pages' built-in)**: it needs no Actions, but it has no built-in search, and link checking and a
  dark/light theme would each need a plugin that Pages' built-in Jekyll does not allow.
- **Hugo**: fast, single binary, but its themes and shortcodes would be our own to keep. No team maintains a
  docs theme to Zensical's level.

## R2 — Config file: `mkdocs.yml` or `zensical.toml`

**Decision**: A root `mkdocs.yml`.

**Rationale**: Zensical reads it natively, and so does Material for MkDocs, which is the fallback in R1. The same
file serves both, so the escape hatch stays open without keeping two configs in step. `zensical.toml` is the
project's forward format. Moving to it later is a mechanical change, to be made once Zensical's 0.1 line is
settled.

## R3 — What the check checks, and who checks it

**Decision**: `scripts/docs-check.py` runs these checks, then `zensical build --strict`:
1. **Section**: every page under `docs/` has front matter `diataxis:` set to one of `tutorial`, `how-to`,
   `reference`, `explanation`, `index`, and sits in the folder of that section. `index` is allowed only for
   `docs/index.md` and each section's `index.md`.
2. **Reached**: every `.md` under `docs/` appears in the `nav:` of `mkdocs.yml`, and every `nav:` entry exists.
3. **Pictures**: every picture referenced by a page exists. Every file in an `images/` folder is used by some
   page, so unused pictures are flagged and do not pile up.
4. **Nothing private** (FR-013, SC-006): no page contains `/Users/`, `/private/`, `/tmp/run-`, a home-directory
   `~/` path other than the documented `~/Library/Application Support/Agents`, `alexcollins`, an IPv4 address
   other than `127.0.0.1`, or a token shape (`ghp_`, `github_pat_`, `sk-ant-`, `xox`). Pictures are checked by
   size and name only. What they show is checked by eye in quickstart V6, because the check cannot read them.

Then the strict build catches dead links and dead anchors (verified in R1).

**Rationale**: A missing picture does not fail Zensical's strict build: it exited 0 with a missing
`![pic](missing.png)` on 2026-09-25. Zensical also does not treat "page not in nav" as an error, and it knows
nothing of Diataxis. The rest has to be ours, and a standard-library script is the smallest way to do it.
Output is one line per problem, `path:line: message`, so both Xcode-style readers and GitHub's log make it
clickable.

**Alternatives considered**: markdownlint and lychee catch style and external links. External links would
make the check depend on other people's sites, so they are left out of the required check (FR-009 asks only
about links within the docs).

## R4 — Publishing to GitHub Pages

**Decision**: Publish with GitHub Actions ("Source: GitHub Actions" in the repository's Pages settings) using
the official `configure-pages` → `upload-pages-artifact` → `deploy-pages` chain, in `docs-publish.yml`:
- **Trigger**: `push` to `main` where `docs/**`, `mkdocs.yml`, `scripts/docs*` or the workflow changed, plus
  `workflow_dispatch`.
- **Order**: the job runs `scripts/docs.sh check` first. The build and deploy steps run only if it passes. A failed
  run leaves the last deployed site in place, which is how Pages behaves (FR-016).
- **Concurrency**: the group is `pages` with `cancel-in-progress: false`, so two quick merges publish in order.
- **Permissions**: `pages: write` and `id-token: write` on the deploy job only; `contents: read` everywhere else.
- **URL**: `https://alexec.github.io/Agents/`, set as `site_url` in `mkdocs.yml`.

`docs-check.yml` runs the same check on `pull_request` and on `push` to any branch, so a feature branch sees
its failures before merge (User Story 5), and never deploys.

**Rationale**: Deploying from Actions means nothing built is ever committed. There is no `gh-pages` branch, so
the rule "only `docs/` is published" holds by construction: the artifact is `site/`, built from `docs/` alone.

**Prerequisite, Alex's**: the repository is private (checked 2026-09-25, `has_pages: false`), so Pages needs
GitHub Pro or above on `alexec`. Turning Pages on is a settings change on a live repository and waits for him.
It is `gh api -X POST repos/alexec/Agents/pages -f build_type=workflow` or Settings ▸ Pages ▸ Source ▸ GitHub
Actions.

**Alternatives considered**: `mkdocs gh-deploy` to a `gh-pages` branch commits built HTML into the repository
and needs a push token. It was rejected.

## R5 — Screenshots without leaking anything

**Decision**:
- **Mac**: screenshots come from the `run-app` skill on scratch root `/tmp/run-044`. The skill captures by window
  id, so Alex's screen is never taken. Its projects are demo folders created for the purpose (`~/Demo/weather-app`
  style names in text, real folders under `/tmp/run-044/demo/`), and it uses one real runtime turn for the
  tutorial. The screen lease is taken first and released straight after.
- **Phone and iPad**: Alex takes these on his devices against the scratch root. There is no Simulator GUI
  here (memory).
- **Format**: PNG, 2× scale, the window only, cropped to the part a step talks about. The size is under 400 KB each,
  checked by `docs-check.py`.
- **Names**: `<page>-NN.png` in the section's `images/` folder.

**Rationale**: FR-013 and SC-006. A scratch root has no real conversations, and demo folder names are chosen,
not inherited.

## R6 — What each Diataxis page is allowed to be

**Decision**: One short page template per section, in `contracts/page-front-matter.md`:
- **Tutorial**:
  - "What you'll have at the end", with a picture;
  - "Before you start";
  - numbered steps, each ending in "You should see…";
  - "Where next".
  - No branches or options. The one path always works.
- **How-to guide**:
  - the title is the task ("Add a Linux server");
  - "Before you start" links to what it assumes;
  - numbered steps, with platform differences inline;
  - "If it doesn't work" for the known failure;
  - no background.
- **Reference**: one table or definition list per page. Every entry has the same columns. There are no
  instructions; a "See also" links to guides.
- **Explanation**: prose under headings, no numbered steps, ending in "Related".

**Rationale**: FR-005. The check enforces what it can: explanation pages have no ordered lists, and tutorials
end with a "Where next" heading. The rest is judged in review against these templates.

## R7 — Keeping docs in step with features

**Decision**:
1. `.specify/templates/spec-template.md` gains a `## Docs` section (after Success Criteria). It lists the pages
   a feature adds or changes, or says "None" with a reason (`contracts/spec-docs-section.md`).
2. `/speckit-tasks` turns each listed page into a task in the feature's own tasks.md, in the polish phase.
   This follows from the spec listing them. No change to the skill is needed.
3. The check runs on every push and pull request.

**Rationale**: FR-010. Asking at spec time is cheaper than remembering at merge. A heuristic that fails a change
touching `App/` without touching `docs/` was considered and rejected: most app changes don't change what a user
reads, and a check that is usually wrong gets ignored.

## R8 — Seeing it locally

**Decision**: `scripts/docs.sh`:
- `serve` runs `uvx zensical@<pin> serve` on `127.0.0.1:8000` with live reload;
- `build` builds into `site/`;
- `check` runs `python3 scripts/docs-check.py` and then the strict build.

The pin lives in one place, the script. CI calls the same script.

**Rationale**: FR-011. There is one command, and it is the same in CI, so "it passed locally" means it passes.

## R9 — Current facts the reference pages start from

These are taken from the README and shipped specs. Each is re-checked against the running scratch app when its
page is written (SC-003):
- **Runtimes**: Claude (npm ACP adapter through Node), Grok (`agent`), Copilot, Cursor (`cursor-agent`). Copilot
  sessions get none of the app's MCP tools (036 finding).
- **Statuses and groups** (039, 040): Needs attention, Blocked, Working, Complete, Stopped, Parked, and
  Archived.
- **Agent tools** (the app's MCP server): `finish_turn`, `show_file`, `suggest_next_prompts`/`next_prompt`,
  `start_agent`, `stop_agent`, `archive_agent`, `list_my_agents`, `report_outcome`, `lease_resource`,
  `release_resource`, `list_resources`, `manage_workflows`, `push_pull_request` and `reply_on_pull_request`, plus
  042's event tools if 042 has merged first.
- **Where they come from**: statuses from `AgentGroup` in AgentsKit, tools from the MCP helper's tool list, and
  settings from the Settings views.
