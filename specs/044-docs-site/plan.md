# Implementation Plan: A Docs Site That Lives With the Code

**Branch**: `044-docs-site` | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/044-docs-site/spec.md`

## Summary

The docs are Markdown files under `docs/`, in four folders that match the four Diataxis sections. Each page
declares its section in front matter. **Zensical** turns them into a static site. Zensical is the successor
to Material for MkDocs, built by the same team, and gives us search, light and dark, phone layout and
redirects. It reads a root `mkdocs.yml`, so the same source still builds with Material for MkDocs if Zensical's
0.x line lets us down (research R1, R2).

Two things keep the docs true:

- **`scripts/docs-check.py`**, a Python script with no dependencies beyond the standard library, checks what
  the generator does not:
  - every page declares a section and sits in that section's folder;
  - every page is in the navigation;
  - every picture exists;
  - no page or picture carries a private path, name or token.

  It then runs Zensical's strict build, which fails on a dead link or anchor.
- **A "Docs" section in the spec template**, so each feature says up front which pages it touches.

Two GitHub Actions workflows do the rest:

- `docs-check` runs the check on every pull request and every push.
- `docs-publish` builds and deploys to GitHub Pages, only from `main` and only after the check passes.

One command, `scripts/docs.sh serve`, shows the site locally.

Most of the feature is content: two tutorials, ten guides, six reference pages and five explanations, with
screenshots taken from a scratch copy of the app through the `run-app` skill.

## Technical Context

**Language/Version**: Markdown (Python-Markdown with the Zensical/Material extensions), Python 3.9+ for the
check script (the system `python3` on this Mac is 3.9.6; CI uses 3.12), POSIX `sh` for `scripts/docs.sh`,
and YAML for two GitHub Actions workflows.

**Primary Dependencies**: `zensical`, pinned to an exact version (0.0.65 today; research R1), run through
`uvx` so nothing is installed globally. GitHub Actions: `actions/checkout`, `astral-sh/setup-uv`,
`actions/configure-pages`, `actions/upload-pages-artifact` and `actions/deploy-pages`, pinned by major version.
Nothing is added to the app, the daemon or any Swift package.

**Storage**: Files in the repository. The site is built into `site/`, which is ignored by git and never committed.

**Testing**: `scripts/docs-check.py` itself, plus `scripts/docs-check-selftest.sh`. The self-test copies `docs/`
into a temporary folder, breaks it in each of the ways the spec names (dead link, dead anchor, page not in the
navigation, page with no section, page in the wrong folder, missing picture, a `/Users/` path), and asserts that
each break fails with the file named. Following the memory rule "never mutate source to prove a test", the
real `docs/` is never touched.

**Target Platform**: Readers use any current browser on Mac, iPhone, iPad, Android or desktop. The site is
built on macOS locally and on `ubuntu-latest` in CI.

**Project Type**: A static documentation site inside an existing app repository.

**Performance Goals**: The check and build take under 60 s in CI. A page loads in under 1 s on a phone over
4G, because the site is static and search is client-side.

**Constraints**:
- The repository is private, so Pages needs Alex's account on GitHub Pro or above (spec A-001).
- Nothing outside `docs/` is published (FR-012).
- Screenshots come from a scratch root only (FR-013).
- The main checkout is never touched; all work happens in `.agents/worktrees/044-docs-site`.

**Scale/Scope**: About 25 pages at launch (FR-007) and about 30–50 screenshots. The site is expected to grow by
1–3 pages per feature.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unfilled template, so it sets no gates. The working rules this
repository follows instead (from the README and project memory) are checked here:

| Rule | How this plan holds to it |
|------|---------------------------|
| Every lane lives in its own worktree off main, and the main checkout is never touched | All work is in `.agents/worktrees/044-docs-site`. The merge happens when Alex says it is this lane's turn. |
| Prove it running, not only in tests | Quickstart V1–V7: the site is built and served locally, pages are read in a browser on the Mac, and the published site is opened on the phone. |
| Never mutate source to prove a test | The self-test breaks a temporary copy of `docs/`, never the real one. |
| Screens come from a scratch copy; never drive the real app | Screenshots use the `run-app` skill on `/tmp/run-044`. The phone and iPad pictures are Alex's (memory: no Simulator GUI). |
| Only one agent drives the screen | Screenshot sessions lease `screen` first and release it straight after. |
| Anything outward-facing waits for Alex | Turning Pages on for the repository and the first push to `main` are asked for, not done unprompted. |

**Result**: PASS, both before research and after design.

## Project Structure

### Documentation (this feature)

```text
specs/044-docs-site/
├── spec.md
├── plan.md              # this file
├── research.md          # R1–R9
├── data-model.md        # Page, Section, Screenshot, Nav entry, Docs note
├── quickstart.md        # V1–V7 validation
├── contracts/
│   ├── page-front-matter.md   # what every page must declare
│   ├── docs-check-cli.md      # the check's inputs, outputs, exit codes
│   └── spec-docs-section.md   # the "Docs" section added to the spec template
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks
```

### Source Code (repository root)

```text
mkdocs.yml                         # site config: name, URL, theme, nav, plugins (redirects), strict
docs/
├── index.md                       # home: what the app is, one "Start here", the four sections
├── tutorials/
│   ├── index.md
│   ├── first-agent.md
│   ├── follow-from-iphone.md
│   └── images/                    # first-agent-01.png …
├── how-to/
│   ├── index.md
│   ├── add-a-project.md
│   ├── start-in-a-worktree.md
│   ├── answer-a-question.md
│   ├── add-a-linux-server.md
│   ├── set-up-a-workflow.md
│   ├── watch-a-pull-request.md
│   ├── sign-a-runtime-in.md
│   ├── archive-park-stop.md
│   ├── attach-files.md
│   ├── read-an-agents-changes.md
│   └── images/
├── reference/
│   ├── index.md
│   ├── statuses.md
│   ├── runtimes.md
│   ├── agent-tools.md
│   ├── settings.md
│   ├── workflows.md
│   ├── keyboard-shortcuts.md
│   └── images/
├── explanation/
│   ├── index.md
│   ├── window-and-daemon.md
│   ├── scoped-tools.md
│   ├── projects-hosts-worktrees.md
│   ├── leases.md
│   ├── phone-and-ipad.md
│   └── images/
└── assets/                        # logo, favicon (from design/logo)
scripts/
├── docs.sh                        # serve | build | check
├── docs-check.py                  # the check (contracts/docs-check-cli.md)
└── docs-check-selftest.sh         # breaks a copy each way, asserts each fails
.github/workflows/
├── docs-check.yml                 # on pull_request + push: scripts/docs.sh check
└── docs-publish.yml               # on push to main (docs/**, mkdocs.yml): check, build, deploy Pages
.specify/templates/spec-template.md  # gains a "## Docs" section (contracts/spec-docs-section.md)
.gitignore                         # + site/, .cache/
README.md                          # + a line linking to the site for using the app
```

**Structure Decision**: The source lives in `docs/`, which already exists empty on main, with one folder per
Diataxis section so the section can be seen in the path. The config sits at the root as `mkdocs.yml`, which is
where both Zensical and MkDocs look for it. Pictures go in an `images/` folder inside each section, named after
their page, so a change to a page and a change to its pictures show up together in review.

## Complexity Tracking

No violations to justify.
