# Contract: `scripts/docs.sh` and `scripts/docs-check.py`

## `scripts/docs.sh <command>`

| Command | Does | Exit |
|---------|------|------|
| `serve` | Serves the site at `http://127.0.0.1:8000` with live reload. | Runs until interrupted. |
| `build` | Runs a strict build into `site/`. | 0 on success, non-zero if the build fails. |
| `check` | Runs `python3 scripts/docs-check.py`, then `build`. | 0 only if both pass. |

The Zensical version is pinned once, in this script, as `ZENSICAL=zensical==<version>`. The script runs from
any directory, because it resolves the repository root from its own path.

## `scripts/docs-check.py [--root <repo>]`

Python 3.9+ standard library only. It reads `mkdocs.yml` (only the `nav:` and `docs_dir:` keys, parsed with a
small indentation reader, so PyYAML is not needed) and everything under `docs/`.

**Output**: one line per problem on stdout:

```
docs/how-to/add-a-linux-server.md:12: link to images/server-03.png: no such file
docs/explanation/leases.md:1: explanation pages have no numbered steps (line 18)
docs/reference/new-page.md:1: not in the nav of mkdocs.yml
```

It then prints a summary line, `docs-check: N problems in M pages`, or `docs-check: ok (M pages, K pictures)`.

**Exit**: 0 if there are no problems, 1 if there are any, and 2 if it could not run (for example, if there is no
`mkdocs.yml`).

**Problems it reports**:

| Code | Rule |
|------|------|
| section-missing | No `diataxis:` in the front matter. |
| section-unknown | `diataxis:` is not one of the five values. |
| section-folder | The page is not in its section's folder, or is an `index` page outside the allowed places. |
| nav-missing | A page is not in `nav:`. |
| nav-dead | A `nav:` entry has no file. |
| nav-twice | A page appears in `nav:` twice. |
| image-missing | A referenced picture does not exist. |
| image-unused | A file in `images/` is not referenced by any page. |
| image-large | A picture is over 400 KB. |
| image-alt | A picture has empty alt text. |
| private | A path, name, address or token matches the patterns in research R3 §4. |
| shape-steps | An explanation page contains an ordered list. |
| shape-where-next | A tutorial has no `## Where next`. |

Links between pages and to headings are left to the strict build, which already resolves them the way the site
will.
