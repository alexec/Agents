# Data Model: 044 Docs Site

There is no stored data. The "entities" are files and the rules they must follow. Every rule marked **(checked)**
is enforced by `scripts/docs-check.py` (contracts/docs-check-cli.md).

## Page

A Markdown file under `docs/`.

| Field | Where | Rule |
|-------|-------|------|
| `title` | first `# ` heading | Required. A how-to title names the task ("Add a Linux server"). |
| `diataxis` | front matter | Required **(checked)**. One of `tutorial`, `how-to`, `reference`, `explanation`, `index`. |
| `devices` | front matter | Optional. A subset of `mac`, `iphone`, `ipad`, `server`. Shown in the page's opening line when present. |
| `description` | front matter | Optional. Used for search results and link previews. |
| path | file system | Must sit in the folder of its section **(checked)**: `tutorial` → `docs/tutorials/`, and so on. `index` only for `docs/index.md` and `docs/<section>/index.md`. |
| nav | `mkdocs.yml` | Must appear exactly once **(checked)**. |
| links | body | Every link to a page or heading inside `docs/` resolves (checked by strict build). |
| body | body | No private paths, names, addresses or tokens **(checked)**. An explanation has no ordered list **(checked)**. A tutorial has a `## Where next` heading **(checked)**. |

**Lifecycle**: added → edited → moved, which needs a `redirect_maps` entry from the old path, so that old links
still work → removed, which also needs a redirect to the nearest page.

## Section

This is fixed. There are four, plus the home page.

| Section | Folder | Nav tab | Index page |
|---------|--------|---------|------------|
| Tutorials | `docs/tutorials/` | Tutorials | `tutorials/index.md` in learning order |
| How-to guides | `docs/how-to/` | How-to guides | `how-to/index.md`, grouped by area (projects, agents, servers, phone, automation) |
| Reference | `docs/reference/` | Reference | `reference/index.md` |
| Explanation | `docs/explanation/` | Explanation | `explanation/index.md` |

## Screenshot

| Field | Rule |
|-------|------|
| path | `docs/<section>/images/<page>-NN.png` |
| used | Referenced by at least one page **(checked)**. Every reference resolves **(checked)**. |
| size | ≤ 400 KB **(checked)** |
| source | A scratch root or Alex's devices on a scratch root. Never the real app's projects (checked by eye, quickstart V6). |
| alt text | Required. It says what the picture shows, for screen readers and for when the picture fails **(checked: non-empty)**. |

## Nav entry

This is the `nav:` in `mkdocs.yml`: a tree of `Section title → [page paths]`. Its order is the reading order.
It is the one list of what the site contains. A page outside it fails the check.

## Docs note (in a feature spec)

`## Docs` in `specs/NNN-*/spec.md`. It is a list of `docs/…` paths, each marked *add* or *change* with one line on
what changes, or the single line `None — <reason>`. Contract: contracts/spec-docs-section.md.
