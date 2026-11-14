# People first, then surfaces (#5206)

Status: agreed. Written by the Product Owner, 2026-11-13.

## Decisions (Alex, 2026-11-13, #5206)

- **Roles replace tiers.** Each feature gets a role; the tier comes from the role by the rule below.
- **The web page is one site with four areas** in its bar.
- **The iPad stays the Remote.** For set-up, a person opens the web page.
- **Android shows the engineer area only.**
- Decided: the areas are named **Agents, Work, Manage, Reports**, because today's Work section
  (issues, PRs, epics) is the lead's planning already, so no section changes its name. Alex can
  overrule.

## The problem

Today each feature gets a **tier** (#2796): Core, Mac + web, Web + Mac link, Mac only, Web only,
Remote only. The tier says which clients draw the feature. It does not say **who** uses the
feature. We added the tiers one rule at a time (#2796, #2798, #3224, #4030, #4759, #4937), so
they do not come from one model.

Facts from the parity table (`scripts/parity-counts.py`, 2026-11-13):

| Tier | Rows |
|---|---|
| Core | 409 |
| Mac + web | 120 |
| Web + Mac link | 14 |
| Mac only | 11 |
| Web only | 14 |
| Remote only | 0 |
| **All** | **568** |

- 72% of the rows are Core. "Core" now holds the agent work and much more: Machines, Secrets,
  Accounts, Add Folder, Work ▸ Features, Velocity (#4030, #4758). The word no longer says "the small
  set the Remote keeps".
- Three more clients come (Windows #4456, Linux #4454, Android #4466). Epic #4487 decides that each
  one is the web page in a shell, so each one is a full client. The tiers do not say what an
  Android phone shows: it is a phone, as the iPhone is, but it draws the full web page.
- The web page has **12 sections in one bar** (`Web/src/model/nav.ts`): Overview, Agents, Work,
  Docs, Messages, Machines, Workflows, Reports, Requests, People, Status, Settings. Engineer
  pages, planning pages, admin pages and reports are side by side. Alex: "the web has become a
  bit of a dumping ground".

## The model: a person, then a surface

Step 1: give each feature a **role**: the person who typically uses it.
Step 2: a rule gives each role its **surfaces** (the clients that draw it).
The tier then comes from the role. Nobody picks a tier by hand.

### The roles

| Role | What the person does | Examples of features |
|---|---|---|
| **Engineer** | Directs agents and does the work, on their own machines and folders. | Sessions, chat, cards, prompt bar, approvals, files, diffs, terminals, worktrees, machines (start, stop), runtimes, their own secrets and accounts, their own usage, their own workflows, Docs, Messages |
| **Lead** (engineering manager) | Plans work and sees it get done. | Work (issues, PRs, epics, Features, Timeline, Releases), Team Workflows, Velocity, Delivery, Forecast, Estimates |
| **Admin** | Manages the estate: people, machines, policy. | People and Groups, Sign-in, Requests, Policy, Model Access, Catalogue, Read API, Audit and Sinks, Backups, Live Now, the fleet's Machines |
| **Report reader** | Reads what the organisation used and did. Often the Lead or the Admin, sometimes finance. | Spend, Outcomes, Time, Adoption, Runtimes, Workflows, Saved Views |

The **control plane** is not a role. It is headless: it routes and keeps the directory
(Principle 6). It serves the web page, but it has no page of its own.

One person can have more than one role. Alex is all four. The role is of the **feature**, not a
permission: a member who opens an admin page by its address is still told why not (as now).

### The surfaces

| Surface | Clients |
|---|---|
| **Desk** | Mac window; the Windows and Linux shells (#4456, #4454) |
| **Hand** | the Remote on iPhone and iPad; the Android shell (#4466) |
| **Web** | the web page in any browser |

### The rule: role to surface

| Role | Web | Desk (Mac) | Hand (Remote, Android) |
|---|---|---|---|
| Engineer, agent work | yes | yes | yes |
| Engineer, set-up (folders, connectors, Agent Configuration, Folder Settings) | yes | yes | no |
| Lead | yes | a link to the web (Work ▸ Features stays native) | no (Features stays) |
| Admin | yes | no; a link only where an engineer looks for it (Edit in Console) | no |
| Report reader | yes | a link to the web (Reports, #4938) | no |

Map to the old tiers, so that no row changes on day one:

| Role (and part) | Old tier |
|---|---|
| Engineer, agent work | Core |
| Engineer, set-up | Mac + web |
| Lead | Web + Mac link (Features and Velocity: Core) |
| Admin | Web only, or Web + Mac link |
| Report reader | Web + Mac link |

So step 1 changes **no client**. It adds a Role cell to every row and says why each tier is what
it is. The later steps (below) change clients where the role says the tier is wrong.

## The web page: four areas, one site

Today: 12 sections in one bar. Proposal: **group the bar in four areas**, one per role. Each area
has its own sections. A person sees only the areas of their roles; a person with one area sees
no area switch at all.

| Area | Sections |
|---|---|
| **Agents** (Engineer; the desk view) | Agents, Docs, Messages, Machines (mine), Workflows (mine), Status (with Reports ▸ Features, #5205), Settings ▸ You |
| **Work** (Lead) | Issues, PRs, epics, Features, Timeline, Releases, Team Workflows, Velocity |
| **Manage** (Admin) | Machines (all), People, Sign-in, Requests, Policy, Model Access, Catalogue, Read API, Audit, Backups, Live Now |
| **Reports** (Report reader) | The Reports pages as #5205 groups them (Cost, Output, Time, Plan, Use, Saved), each with the lens bar (Me, Project, Organisation). Usage and Multiplier are the Me lens of their pages. |

The Overview stays the home. It shows one card per area the person has.


### Options for the web page

1. **One site, four areas in the bar (chosen).** One bundle, one sign-in, one address. The
   bar shows the area's sections and an area switch. It keeps #2141's decision (one site, no
   separate app) and the shells (#4487) bundle one page. A link from the Mac opens the right
   area by its address (`#/reports/…` as now).
2. **Four places, one site.** Separate entry addresses (`/agents`, `/work`, `/manage`,
   `/reports`) of the same bundle, each with only its own bar. Clearer for a person with one
   role. More work for the links and the shells, and it partly reverses #2141.
3. **Keep the flat bar, group it by headings only.** Cheapest. It does not fix "a dumping
   ground" for a person with one role.

## The Remote and the iPad

Alex: keep the Remote simpler (cost, screen size), but starting a machine and doing work on it
is needed. That is the rule above: Hand gets **Engineer, agent work**, which includes the
Machines group since #4030.

Options for the iPad:

1. **The iPad stays the Remote (chosen).** One app, one set of features on iPhone and iPad.
   An engineer who wants set-up on the iPad opens the web page there. Lowest cost.
2. **The iPad is a Desk.** It gets the engineer set-up features too (folders, connectors, Agent
   Configuration). It adds about 120 Mac + web rows to the Remote's work, on the iPad only.
3. **The iPad shows the web page for set-up.** A row on the iPad opens that page of the web page
   in Safari or a web view. Like Web + Mac link, for the iPad.

## Android: a phone that draws the web page

#4487 says every shell is a full client. With roles, Android is a Hand. Options:

1. **Android draws the Agents area only (chosen).** The shell opens the web page with the
   Work, Manage and Reports areas hidden, as a phone needs. The web page decides the areas by a
   shell flag; no second build.
2. **Android draws the whole web page.** As #4487 decided. Simple, but a phone gets admin and
   report pages that the iPhone does not.

## Steps

1. **Task:** add a Role cell to every row of `specs/071-web-remote/walks/parity/`, and the rule
   above to `parity.md` and AGENTS.md "Keeping the three clients in step". `parity-counts.py`
   counts by role and fails on a row whose tier does not agree with its role. No client changes.
2. **Story (web, needs Alex's approval, new layout):** the four areas in the web bar, with the
   area switch and the Overview's cards.
3. **Story (Mac):** check each Lead and Report reader row; the Mac draws a link, not a native
   page, where the rule says so (some are in #4936 now).
4. **Story (Remote):** remove what the rule says Hand does not get, as #2798 did.
5. **Story (Android, #4466):** the shell opens the Agents area only.

## Open questions

None. Alex answered 1 to 3 and 5 on 2026-11-13; 4 (names) is decided above.

## Reports (#5205)

Epic #5276 regroups Reports and gives every report the lenses Me, Project and Organisation (no team lens; Alex, 2026-11-13). The Reports area takes that list whole. #5292 waits for #5280.

## Principles

This agrees with `docs/explanation/direction.md`. Principle 1 (the web page has every feature)
holds: every role's features are on the web page. Principle 6 holds: the control plane stays
headless, with no area of its own.
