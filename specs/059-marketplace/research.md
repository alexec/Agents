# 059 · Research

Everything below was checked on 2026-09-26 against the live services and against the `skills`
CLI (vercel-labs/skills 1.7.0, `dist/cli.mjs`, from the npx cache). Probes were run with `curl`
and `node`. None of them wrote to disk.

## R1 · Search: skills.sh `/api/search`

**Decision**: search with `GET https://skills.sh/api/search?q=<query>`. The request has no key,
and the app waits 300 ms after the last keystroke before sending it. Results are shown in the
order returned, which is most installed first.

**Findings**: it returns up to 100 results in the form `{id, source, skillId, name, installs}`.
`source` is `owner/repo` for GitHub skills. There is no description. That is why frame B shows
none and frame C fetches the skill. The search is fuzzy (Algolia) and answered in well under a
second.

**Non-GitHub sources**: some results come from "well-known" URL sources, such as a vendor's own
site. This slice does not show them, because R3 depends on GitHub. They can come back with a
later catalogue slice.

**Alternatives**: `npx skills find`. It is interactive and needs Node, so it was rejected.

## R2 · Which folder in the repo is the skill

**Decision**: use the CLI's own rule. The daemon lists every `SKILL.md` in the repo's tree. It
then picks the one whose folder name, or whose front-matter `name` put through the CLI's
`toSkillSlug`, equals the result's `skillId`. If none matches, the detail says "not found in the
repository" and does not offer Add.

**Findings**: `avdlee/swiftui-agent-skill` has two `SKILL.md` files,
`skills/swiftui-expert-skill/` and `.agents/skills/update-swiftui-apis/`. The folder-name match
picks the right one. The CLI records the result as `skillPath` (`skills/…/SKILL.md`), and so
will the app.

## R3 · Getting exactly the files, at one commit

**Decision**: use GitHub's tree at a fixed commit as the list of files, and fetch the content
from the cheapest place that matches it.

1. **Commit**: read the default branch's HEAD from git's smart-HTTP ref list,
   `https://github.com/<o>/<r>.git/info/refs?service=git-upload-pack`. It has no rate limit,
   needs no key and no `git`, and names the default branch through `symref=HEAD:refs/heads/…`.
2. **Manifest**: `GET /repos/<o>/<r>/git/trees/<commit>?recursive=1`. For every file under the
   skill's folder this gives the path, the mode and the git blob SHA-1. It also gives the
   folder's own tree SHA, which is what the CLI stores (R5).
3. **Contents**: `GET https://skills.sh/api/download/<o>/<r>/<skillId>` returns the text files
   as `{files:[{path, contents}], hash}`. Each file's git blob SHA-1 is checked against the
   manifest. A file that is missing (skills.sh leaves out binaries) or that doesn't match is
   fetched from `raw.githubusercontent.com/<o>/<r>/<commit>/<path>`. That host has no API limit.

**Findings**: for `swiftui-expert-skill` at `b24e68a`, all 49 snapshot files matched their
blobs. The tree had 51 files, and the two not in the snapshot were `assets/logo.png` and
`assets/logo-small.png`. So the snapshot is a text-only cache of HEAD. It cannot stand in for the
repository, but it can be checked against it.

**Why not only one source**:
- The snapshot alone has no commit and drops binaries.
- Raw fetches alone means one request per file: 51 here.
- A git clone needs `git` and fetches the whole repository.
- A codeload tarball also fetches the whole repository, which can be tens of MB for collections.

The tarball is still the **fallback** when the tree API is rate-limited (R4). It is fetched at
the commit, capped at 50 MB, and only the skill's folder is extracted.

**What "exactly what is shown" means (FR-008)**: the preview is fetched once into a staging
folder the daemon owns. Add moves that folder into place. Nothing is fetched a second time.

## R4 · GitHub's API limit

**Decision**: when the person has `gh` signed in, call the tree API through `gh api`, using the
`GitHubCLI` 038 already has. That gives 5,000 requests an hour, and the app never holds the
person's token. Otherwise call it anonymously, which allows 60 an hour per IP. When the limit is
hit, fall back to the tarball (R3).

- A preview costs **one** API call.
- An update check costs **none** when HEAD hasn't moved (R1's ref list answers that) and one per
  source repository when it has.
- The date on "a91e04b · 5 days ago" costs one more call (`/commits?path=<folder>&sha=<commit>
  &per_page=1`). It is only made when `gh` is signed in, otherwise the date is left off. That is
  a small, deliberate change from frame C.

**Alternatives**: asking the person for a GitHub token was rejected. It would be a new secret for
the app to hold, and `gh` already covers people who have one.

## R5 · The records: the `skills` CLI's two lock files

**Decision**: read and write the CLI's own files in its own shape, so that each tool sees what
the other added. The app keeps nothing of its own in them.

| | User (`~/.agents`) | Project |
|---|---|---|
| File | `~/.agents/.skill-lock.json` (or `$XDG_STATE_HOME/skills/.skill-lock.json` when that is set) | `<project>/skills-lock.json` |
| Version | 3 | 1 |
| Entry | `source` "o/r", `sourceType` "github", `sourceUrl` "https://github.com/o/r.git", `skillPath`, `skillFolderHash` = **the folder's git tree SHA**, `installedAt`, `updatedAt` | `source`, `sourceType`, `skillPath`, `computedHash` = **SHA-256 over each file's relative path then its bytes, in `localeCompare` order**; keys sorted, 2-space indent, trailing newline |
| Other keys | `dismissed`, `lastSelectedAgents` and anything unknown are kept untouched | only `version`, `skills` |

**Findings**:
- The CLI rebuilds an entry whole when it writes it. Any extra key the app put there would be
  lost, which is why the app adds none.
- A file older than the version above is read by the CLI as empty. The app refuses to write to
  such a file and says so rather than wiping it.
- The CLI's `localeCompare` order equals case-folded order for every path checked. Swift has to
  reproduce it, so the hash is covered by golden tests made with `node` (quickstart §0).
- skills.sh's own `hash` field is none of these (it matched neither ordering) and is not used.

**The app's own sidecar**: `<root>/catalog-skills.json` holds what the lock files have no field
for. For each skill added (keyed by destination and name) it records:
- the commit;
- the commit date, when known;
- the folder tree SHA, for project skills;
- the catalogue it came from.

It lets "update?" skip the API when HEAD hasn't moved, and it lets the detail show "Taken at". A
skill the CLI added has no sidecar entry. It still gets Update and Remove, but its detail says
"Taken at: not recorded".

**"Added by a tool" (FR-013, FR-021)**: a skill is manageable, meaning Update, Remove and
Replace are offered, exactly when a lock entry names it. It does not matter whether the CLI or
the app wrote that entry. A folder with no entry is the person's own, or belongs to a tool the
app doesn't know. The app never touches it.

## R6 · Edited since it was added (FR-019)

**Decision**: work out the installed folder's hash the way its lock recorded it: the git tree SHA
for a user skill, `computedHash` for a project skill. If it differs from the lock, the person has
edited the skill, and Update warns and asks again.

**Findings**: computing a git tree hash needs only file modes, names and blob SHA-1s, sorted in
git's order (a folder sorts as if its name ended in `/`). That is about forty lines and has no
dependency. It is covered by golden tests against `git write-tree` on fixtures.

## R7 · Where a project skill goes, and what reaches agents

**Decision**: `<folder>/.agents/skills/<name>`, where `<folder>` is the project or worktree the
page is showing. `<name>` is the front-matter `name` put through `toSkillSlug`, the same as the
CLI. The app does not add links. The dotagents layout already links `.claude/skills` to
`../.agents/skills`, and the other runtimes read the folder themselves (054 research R1). The
app creates `.agents/skills` if it is missing. If `.claude/skills` is missing too, 054's
`layOutOnce` would not run again for that project, so the app makes the link itself through
`DotAgents`.

**User skills**: `~/.agents/skills/<name>`. 054's `reconcile` already runs before every session
start, so Claude's link is made at the next start (FR-011) and taken away once the folder is gone
(FR-020). There is nothing new to wire up.

## R8 · Where the work runs

**Decision**:
- In `agentsd`: all network access, staging, writing and the lock files. The code lives in
  `AgentsKit/Catalog/`, and new `catalog/*` and `skills/*` methods are **control-only**. They are
  not in `deviceMethods`, so neither the phone nor an agent can add a skill.
- In the app: the sheet, the project section and Shared's changes.

**Why the daemon**: it already owns `~/.agents` and a project's layout, and runs as the person.
It also decides the scratch home (`AGENTS_PERSONAL_HOME`, FR-024). If the app wrote files
itself, there would be a second writer to the same folders.

**Test hooks**: `AGENTS_TEST_CATALOG_URL` stands in for skills.sh, and `AGENTS_TEST_GITHUB_URL`
stands in for github.com, api.github.com and raw.githubusercontent.com. One fixture server serves
all the paths. `gh` is replaced through `GitHubCLI`'s `executable`, as 038's tests already do.

## R9 · Trash

**Decision**: use `FileManager.trashItem(at:resultingItemURL:)`. It works from a process with no
UI. Remove and Replace move the old folder to the Trash; they never delete it outright.

**Scratch roots**: `trashItem` always uses the real user's Trash, even when the personal home is
a scratch one. A walk would then leave files in the person's own Trash, which breaks FR-024. So
whenever the personal home came from `AGENTS_PERSONAL_HOME`, or the daemon is on a non-standard
root, "the Trash" is `<root>/trash/<name>-<timestamp>` instead. Only the ordinary daemon uses the
real Trash.

## R10 · Server projects

**Decision**: this slice has **no Skills section on a project that lives on a server**. The
spec's edge case said the section would be read-only there. Doing that would need a way to list
folders on a host that this slice doesn't otherwise need, so it moves to the MCP slice, which
has to reach hosts anyway. The spec is changed to match.

## R11 · Known owners

**Decision**: a short list ships in code and is not fetched: `anthropics`, `openai`, `google`,
`google-gemini`, `github`, `microsoft`, `vercel`, `vercel-labs`, `apple`, `expo`, `figma`,
`stripe`, `supabase`, `cloudflare`. It only adds a mark (Alex, look gate).
