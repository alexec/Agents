# Quickstart: Validating 044 Docs Site

Run everything from the worktree, `.agents/worktrees/044-docs-site`. You need `uv` and `python3`, which are both
already on this Mac.

## V1 — The site builds and the check passes

```sh
scripts/docs.sh check
```

**Expected**: `docs-check: ok (N pages, K pictures)`, then a strict build with no warnings, and exit 0.

## V2 — Every kind of break is caught (SC-004)

```sh
scripts/docs-check-selftest.sh
```

**Expected**: one `PASS` line per break (dead link, dead anchor, nav-missing, section-missing, section-folder,
image-missing, private path), each showing the failing file name. It exits 0. The real `docs/` is untouched:
`git status docs/` is clean afterwards.

## V3 — Read it locally, as a reader would

```sh
scripts/docs.sh serve    # open http://127.0.0.1:8000
```

**Expected**:
- The home page has one "Start here" that leads to *Your first agent*.
- Four tabs are shown.
- On any page, the tab shows the section.
- Searching "server" lists *Add a Linux server* in the first results.
- Switching macOS to dark changes the site to dark.
- Narrowing the window to phone width causes no sideways scroll outside tables and code.

## V4 — The tutorial works (SC-001)

On a scratch root (the `run-app` skill), follow *Your first agent* step by step from a new project.

**Expected**: each step's "You should see" matches the window, and the agent ends in Complete. Time it. Later,
someone who hasn't used the app does the same run, and it must take ≤ 15 minutes.

## V5 — Reference matches the app (SC-003)

For each reference page, compare its list with the source of truth named in research R9, and with the scratch app.

**Expected**: nothing is missing and nothing extra.

## V6 — Nothing private (SC-006)

Open every picture in `docs/**/images/` and read every page once.

**Expected**: no real project names, conversations, paths, server addresses or tokens. `docs-check.py` has
already covered the text. This pass is for what pictures show.

## V7 — Publishing (SC-005), after Alex turns Pages on

1. A pull request touching `docs/` shows the `docs-check` workflow run and pass. A deliberately broken one fails
   with the file named.
2. Merge a one-word docs change to `main`. The `docs-publish` run deploys, and `https://alexec.github.io/Agents/`
   shows the word within 10 minutes.
3. A push to a branch that is not main runs the check and does not deploy.
4. Open the site on the iPhone (SC-007).
