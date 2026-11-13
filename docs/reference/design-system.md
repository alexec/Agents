---
diataxis: reference
description: The look of the app, the docs site and the website — its principles, every token, the type steps, and where each surface reads them.
---

# The design system

The app has one look, **Paper**, and this page writes it down: the principles, every token
with its light and dark value, the type steps, and the files where each surface reads them.
The Mac window, the iPhone and iPad app, the web page and the forge connector pages draw it
today: the connector pages read `Go/internal/forgepages`, which maps their MCP Apps variables
onto the tokens (#4607). The docs site and the website (agentloops.dev) move onto it next
(#4600).

The values come from one file, `design/tokens.json`. The tables on this page are made from
that file by `scripts/design.sh gen`, and `scripts/design.sh check` fails when they do not
agree with it, so this page cannot drift from the code.

## Principles

- **Paper, not glass (Paper v2, #4926).** Most of what the app shows is prose: a report, a
  transcript, a document that an agent writes. The ground is a warm near-white, not pure
  white, and the ink is a deep charcoal (17:1), not pure black.
- **Lines, not shading.** A rule (1.5:1) sets things apart. Nothing on the page casts a
  shadow, and there are few grey fills. Only what floats over the page (a menu, the prompt
  bar, a toast, a sheet) has a short shadow. A control's edge is 3:1 or more (WCAG 1.4.11).
- **Flat, with light greys.** There are no gradients. The large greys (the sidebar, a well,
  hover, the selection) are one small step from the page. Colour never fills: it is only in
  text, icons, lines (a state's line, the selection's bar) and a switch that is on.
- **One sans-serif and one monospace.** Both are the system's own fonts. Nothing is loaded
  from the network: no web font, on any surface.
- **One accent.** The cobalt of the app icon is for links, focus, controls and the
  prominent button. Nothing is drawn in the accent on a selection, where it is too faint.
- **Four state tints, and only Needs you in colour in a list.** Yellow means that a
  person is needed, orange is a warning, red means that something failed, and green means
  an ending that the app can vouch for (approved, done) (#5016). In a list, only **Needs
  you** is drawn in colour.
- **Label hues never read as a state.** A session label that names an issue (`#12`) is
  teal, and one that names a pull request (`P#12`) is violet. Neither is a tint.
- **Every text colour can be read.** Each one (ink, secondary, tertiary, the accent, the
  tints and the label hues) clears 4.5:1 on every surface (ground, sidebar, raised, well,
  wash and selection), in light and in dark. `DesignTokensTests` checks each pair.
- **Marketing is a size of the system, not a second look.** The website keeps its hero
  title with the two `display` type steps.

## Colour

Each colour has a light and a dark value; the surface follows the system's appearance. The
CSS name is the custom property that the token files declare. The Swift name is where the
Mac window and the iPhone and iPad app hold the same value.

<!-- design.sh gen: colour -->
| Token | CSS | Swift | Light | Dark | For |
|---|---|---|---|---|---|
| ground | `--paper-ground` | `Paper.ground` | `#fcfbf9` | `#1a1a19` | The page every column sits on: near-white paper. |
| sidebar | `--paper-sidebar` | `Paper.sidebar` | `#f8f7f4` | `#171716` | The folders column, one small step from the page; a rule sets it apart. |
| raised | `--paper-raised` | `Paper.raised` | `#ffffff` | `#212120` | Cards, the prompt bar, menus, sheets. Set apart by a rule, not a shadow. |
| well | `--paper-well` | `Paper.well` | `#f6f5f2` | `#262625` | What is set into the page: code, your own message, a filled field. |
| wash | `--paper-wash` | `Paper.wash` | `#f1f0ec` | `#2e2e2c` | Hover; a pressed quiet button. |
| rule | `--paper-rule` | `Paper.rule` | `#d6d2c9` | `#3d3d3a` | The line that sets things apart, in place of a shadow (1.5:1): rows, cards, columns. |
| edge | `--paper-edge` | `Paper.edge` | `#7d786e` | `#85817a` | The edge of a field, a checkbox, a toggle's track: 3:1 or more, so a control can be found (WCAG 1.4.11). |
| ink | `--paper-ink` | `Paper.ink` | `#1a1918` | `#f4f2ed` | Text and icons: deep charcoal, 17:1 on the ground. |
| secondary | `--paper-secondary` | `Paper.secondary` | `#4a4741` | `#bdb9b0` | A row's second line, a speaker's name, a section heading. |
| tertiary | `--paper-tertiary` | `Paper.tertiary` | `#625e57` | `#a29e95` | Timestamps, counts, placeholders. |
| selection | `--paper-selection` | `Paper.selection` | `#ebe9e4` | `#363633` | The picked row, with a 3px accent bar at its edge. Every text colour is 4.5:1 or more on it. |
| accent | `--accent` | `AccentColor.colorset` | `#1a52c0` | `#86b4ff` | The app icon's cobalt: links, focus, the chosen control, a switch that is on. |
| line.accent | `--line-accent` | `Paper.lineAccent` | `#a9c2ee` | `#3d5687` | The chosen thing, a link card. |
| line.attention | `--line-attention` | `Paper.lineAttention` | `#e3d196` | `#615326` | Needs you: the yellow's line (#5016). |
| line.warning | `--line-warning` | `Paper.lineWarning` | `#ebbf9f` | `#6b4a33` | A warning: the orange's line (#5016). |
| line.vouched | `--line-vouched` | `Paper.lineVouched` | `#a9d3bb` | `#36614d` | Done, approved. |
| line.failure | `--line-failure` | `Paper.lineFailure` | `#eeb0b3` | `#6b3a3d` | Failed. |
| tint.attention | `--tint-attention` | `StateTint.yellow` | `#7a6200` | `#e6c04f` | Needs you: a question, a request, a wait only the person can settle; the only tint drawn in a list. Yellow, never the warning's orange (#5016). |
| tint.warning | `--tint-warning` | `StateTint.orange` | `#a3400e` | `#f3a672` | A warning: something is wrong or nearly so, and a person should know. Not a request (#5016). |
| tint.failure | `--tint-failure` | `StateTint.red` | `#b0222a` | `#f4878d` | Failed. |
| tint.vouched | `--tint-vouched` | `StateTint.green` | `#25684f` | `#92ccad` | Approved, done: an ending the app can vouch for. |
| label.issue | `--label-issue` | `Paper.issue` | `#0c6278` | `#73cbe0` | A label naming an issue, #12. |
| label.pull | `--label-pull` | `Paper.pull` | `#6c3cae` | `#bea3f2` | A label naming a pull request, P#12. |
| on-fill | `--paper-on-fill` | `none: SwiftUI's Color.white` | `#ffffff` | `#ffffff` | What is drawn on a filled mark: a state's badge, a swipe's action. |
| scrim | `--paper-scrim` | `none: SwiftUI's Color.black` | `#000000` | `#000000` | Behind a sheet or a viewer, mixed with transparent to the strength it needs. |
| forge.open | `--forge-open` | `Paper.forgeOpen` | `#1a7f37` | `#3fb950` | Open; a check that passed; running. |
| forge.done | `--forge-done` | `Paper.forgeDone` | `#8250df` | `#a371f7` | A closed issue, a merged pull request. |
| forge.closed | `--forge-closed` | `Paper.forgeClosed` | `#cf222e` | `#f85149` | A pull request closed unmerged; a check that failed; changes asked for. |
| forge.draft | `--forge-draft` | `Paper.forgeDraft` | `#6e7781` | `#8b949e` | A draft, an issue not planned. |
| forge.waiting | `--forge-waiting` | `Paper.forgeWaiting` | `#9a6700` | `#d29922` | A check still running; an agent that waits on the person. |
| forge.waiting-wash | `--forge-waiting-wash` | `Paper.forgeWaitingWash` | `#fff8c5` | `#2f2a1a` | Under a notice in the forge's amber. |
| forge.waiting-rule | `--forge-waiting-rule` | `Paper.forgeWaitingRule` | `#d4a72c` | `#6b5a1e` | The edge of a notice in the forge's amber. |
| forge.mark | `--forge-mark` | `Paper.forgeMark` | `#212121` | `#212121` | The near-black disc under a connector's letters (GH, GL) in its set-up sheet. |
| forge.fill.open | `--forge-fill-open` | `Paper.forgeFillOpen` | `#1f883d` | `#238636` | An open badge; the merge button. |
| forge.fill.done | `--forge-fill-done` | `Paper.forgeFillDone` | `#8250df` | `#8957e5` | A merged or closed badge. |
| forge.fill.closed | `--forge-fill-closed` | `Paper.forgeFillClosed` | `#cf222e` | `#da3633` | A closed pull request's badge. |
| forge.fill.draft | `--forge-fill-draft` | `Paper.forgeFillDraft` | `#59636e` | `#6e7681` | A draft's or a not planned issue's badge. |
| code.comment | `--code-comment` | `InkValues.comment` | `#64707a` | `#a3adb8` | A comment, in italic. |
| code.keyword | `--code-keyword` | `InkValues.keyword` | `#2b4c8c` | `#8fb0e8` | A keyword, true, false, null. |
| code.string | `--code-string` | `InkValues.string` | `#4e6420` | `#a9c27a` | A string. |
| code.number | `--code-number` | `InkValues.number` | `#7a3e7a` | `#d5a3d5` | A number. |
| code.type | `--code-type` | `InkValues.type` | `#1f6a6a` | `#7cc4c0` | A type. |
| code.function | `--code-function` | `InkValues.function` | `#5b4bb5` | `#b3a6f0` | A function. |
| code.property | `--code-property` | `InkValues.property` | `#52627a` | `#bac5d7` | A property. |
| code.punctuation | `--code-punctuation` | `InkValues.punctuation` | `#5e6470` | `#a9b2bd` | Punctuation and operators. |
| timeline.plot | `--timeline-plot` | `none: WorkTimelinePane.plot` | `#ffffff` | `#0d1429` | The plot behind the lines. |
| timeline.faint | `--timeline-faint` | `none: WorkTimelinePane.faint` | `#8c8c8c` | `#999999` | The axis's marks. |
| timeline.trunk | `--timeline-trunk` | `none: WorkTimelinePane's trunk` | `#999999` | `#e7e8ea` | The trunk every feature leaves from. |
| timeline.release | `--timeline-release` | `none: WorkTimelinePane's release` | `#000000` | `#ffffff` | A release's ring on the trunk. |
| timeline.now | `--timeline-now` | `none: WorkTimelinePane.nowGrey` | `#8c8c8c` | `#8c8c8c` | The Now line. |
<!-- /design.sh gen -->

## Shape

<!-- design.sh gen: shape -->
| Token | CSS | Swift | Value | For |
|---|---|---|---|---|
| code | `--radius-code` | `Paper.Radius.code` | `5px` | Code, inline and in a block. |
| control | `--radius-control` | `Paper.Radius.control` | `7px` | Chips, the rail, inputs. |
| card | `--radius-card` | `Paper.Radius.card` | `10px` | Rows, wells, cards. |
| floating | `--radius-floating` | — | `16px` | Sheets, menus, the prompt bar (web). |
| pill | `--radius-pill` | `Paper.Radius.pill` | `99px` | A state badge: round ends. |
| shadow.floating | `--shadow-floating` | `Paper.Shadow.floating` | `0 4px 12px rgb(26 25 24 / 10%)`; dark `0 4px 12px rgb(0 0 0 / 40%)` | Menus, the prompt bar, toasts, with a rule line. |
| shadow.sheet | `--shadow-sheet` | `Paper.Shadow.sheet` | `0 12px 32px rgb(26 25 24 / 18%)`; dark `0 12px 32px rgb(0 0 0 / 55%)` | Sheets and dialogs, over a dimmed page. |
| focus.width | `--focus-width` | `Paper.Focus.width` | `2px` | The ring's width. |
| focus.gap | `--focus-gap` | `Paper.Focus.gap` | `2px` | The gap between the control and the ring. |
<!-- /design.sh gen -->

## Depth and focus

The `shadow` and `focus` rows are in the table above: `shadow.floating` for a menu, the
prompt bar and a toast, `shadow.sheet` for a sheet or a dialog, and a focus ring of
`focus.width` in the accent, `focus.gap` from the control.

## Reading spacing

Reading text (prose, messages) has a line height of 1.5 and a little letter and word
spacing, from the British Dyslexia Association's style guide and WCAG 1.4.12.

<!-- design.sh gen: spacing -->
| Token | CSS | Swift | Value | For |
|---|---|---|---|---|
| leading.reading | `--type-leading-reading` | `TextStep.readingLeading` | `1.5` | Reading text: prose, messages. |
| tracking.reading | `--type-tracking-reading` | `TextStep.readingTracking` | `0.01em` | Reading text: a little letter spacing. |
| word-spacing.reading | `--type-word-spacing-reading` | `none: SwiftUI has no word spacing` | `0.06em` | Reading text: a little word spacing. |
<!-- /design.sh gen -->

## Fonts

<!-- design.sh gen: font -->
| Token | CSS | Stack | For |
|---|---|---|---|
| text | `--font-text` | `Atkinson Hyperlegible Next, -apple-system, BlinkMacSystemFont, system-ui, sans-serif` | Atkinson Hyperlegible Next (SIL OFL 1.1, design/fonts/), for everything a person reads; the system's sans-serif where it is not loaded. Nothing is loaded from another origin (#4975). |
| mono | `--font-mono` | `Atkinson Hyperlegible Mono, ui-monospace, SF Mono, Menlo, monospace` | Atkinson Hyperlegible Mono (SIL OFL 1.1, design/fonts/), for code; the system's monospace where it is not loaded. |
<!-- /design.sh gen -->

## Type

A step is a place on each platform's own scale, not one size for all. On the Mac and on
the iPhone and iPad it is a SwiftUI text style, so it follows Dynamic Type. On the web it
is in `rem`, so it follows the browser's font size and zoom. The `display` steps are for
the website only.

<!-- design.sh gen: type -->
| Step | CSS | Mac | iPhone and iPad | Web | For |
|---|---|---|---|---|---|
| title | `--type-title` | `.title` | `.title` | `1.375rem` | A page's title. |
| reading | `--type-reading` | `.title3` | `.body` | `1rem` | Prose: what everything is read at unless there is a reason otherwise. |
| supporting | `--type-supporting` | `.body` | `.subheadline` | `0.875rem` | A row's second line. |
| fine | `--type-fine` | `.subheadline` | `.footnote` | `0.75rem` | A timestamp, a count. |
| code | `--type-code` | `.body` | `.subheadline` | `0.875rem` | Code, paths, commands, in the monospace. |
| display.1 | `--type-display-1` | — | — | `clamp(2rem, 5vw, 3.2rem)` | www's hero title. |
| display.2 | `--type-display-2` | — | — | `1.8rem` | www's section titles. |
<!-- /design.sh gen -->

## Messages

A message tells the person about a status, a warning, a failure or a success. Every client
uses the same six kinds, and each kind has one place on the screen. A message never pushes
the content that the person reads or types into (#4737).

### The kinds

| Kind | Use it for | Where it goes | Reflow | Goes away |
|---|---|---|---|---|
| **Field note** | One field: a value that is not correct, a hint for that field. | Under the field, on a line that is kept for it. Show a failure after Submit, not while the person types. | None: the line is always there. | When the value is correct. |
| **Sheet note** | The action of a sheet or a form: it failed, or it is in progress. | Beside or above the sheet's buttons, in a space that is kept for it (two lines, as the web's `.sheet-note`). | None. | When the action starts again, or the sheet closes. |
| **Banner** | A condition of a pane or a page: offline, stale, a read that failed, a limit that is reached, a folder that has gone. | Across the top of the pane that it is about, inset, under the toolbar. Never over the content. | Only when the condition starts or ends, with a short animation. | When the condition ends. The person cannot close it. |
| **Toast** | The result of an action that the person did outside a sheet: copied, archived, sent, or that it failed. | Floats at the bottom centre of the window (the web page: of the viewport), above the prompt bar. One at a time: a new toast replaces the last one. | None: it floats. | A success after 4 seconds; a toast with Undo after 8 seconds. A failure stays until the person closes it. The time stops while the pointer, the focus or VoiceOver is on the toast. |
| **Alert** | A choice that blocks the work: the person must decide before the app can continue (Delete? Let it use this sign-in?). | Modal, from the platform (`HeldAlert` on the Mac, `.alert` on the Remote, `<dialog>` on the web). | None. | When the person chooses. |
| **Notice or transcript row** | Work that the person did not start now: an agent's `notify`, a turn that failed, background work that failed. | Not on the page: the Notices list, the system notification, or a row in the transcript. | None. | As the notice or the transcript does. |

To choose a kind, ask these questions in this order:

1. Must the person choose something before the work can continue? Use an **alert**.
2. Is it about one field? Use a **field note**.
3. Is it about the action of an open sheet? Use a **sheet note**.
4. Does it stay true until something changes (a condition)? Use a **banner**.
5. Is it the result of something that the person did now? Use a **toast**.
6. If not, use a **notice or transcript row**.

A button that copies something changes its own label for 2 seconds ("Copied"), and keeps
its width. It shows no toast. A copy from a menu item or a keyboard shortcut shows a toast,
because no control is in view to change.

### Tone, colour and icon

| Tone | Means | Tint | Mac and Remote icon (SF Symbol) | Web icon |
|---|---|---|---|---|
| **Neutral** | A status: offline, stale, in progress, set by your organisation. | None: `ink` on the `well`. | `info.circle`, or `wifi.slash` when offline | ⓘ |
| **Attention** | A person is needed: pair, sign in, approve, choose the folder again. | `tint.attention` | `exclamationmark.circle.fill` | ⚠︎ |
| **Warning** | The session's place is not right: a Strip (specs/session-cards, #5029). Not a request. | `tint.warning` | (#5034) | ⛔ |
| **Failure** | Something failed: a read, an action, a limit that stopped the work. | `tint.failure` | `xmark.octagon.fill` | ✕ |
| **Success** | An ending that the app can vouch for: done, sent, archived. | `tint.vouched` | `checkmark.circle.fill` | ✓ |

- **The warning tone is for a Strip only** (specs/session-cards, Decided). The web's account
  move strip has it first (#5029); #5034 moves the other strips, on all three clients. Outside
  messages, a warning line (a field that would fail, an allowance nearly spent, a disk
  that runs low) draws `tint.warning`, the orange.
- **Yellow means only that a person is needed** (specs/018 FR-006a; #5016). Orange is a
  warning, red is a failure: a request never reads as a warning. A cost limit that stopped
  the work is a failure, not attention.
- **The tint is on the icon only.** The words are in `ink`, the ground is `well` (a banner)
  or `raised` (a toast). A message never fills its ground with a tint.
- **Never colour alone.** Each message has an icon and words.

### Words

- The words say what happened, then what to do: "Could not archive the session. Try
  again." Follow **Copy** below.
- A banner or a toast has at most two actions, as buttons (Try Again, Undo, Open
  Account). A field note has none.

### Screen readers

| Kind | Web | Mac and Remote |
|---|---|---|
| Field note | `aria-describedby` from the field; `aria-invalid` on a failure | `.accessibilityHint` on the field |
| Sheet note, banner, toast | `role="status"` (`role="alert"` for a failure), in a live region that is always in the page | An announcement (`AccessibilityNotification.Announcement`) when it appears |
| Alert | `<dialog>` | The platform's alert |

### Where each pattern goes

The client stories (#4600) move each pattern to its kind. Inline error text in a form (about
130 SwiftUI sites and 45 on the web) is a field note or a sheet note, by the questions above.

| Pattern today | Client | Kind | Tone |
|---|---|---|---|
| `WindowAlert.problem` ("Could not finish that"), `.makeFailed` (`ContentView.swift`) | Mac | Toast | Failure |
| `WindowAlert.lend`, `.lendGit`, `.folderGone`; Delete archived agents now? | Mac | Alert (no change) | — |
| `.alert` for a failed action (`RemoteApp.swift`, `RuntimesView.swift`) | Remote | Toast | Failure |
| `.problem` strip (`Errors.tsx`), with OK | Web | Toast | Failure |
| `ControlAwayStrip` | Mac | Banner | Neutral; attention when the address refused and Open Account shows |
| `StaleBanner` (reach) | Remote | Banner | Neutral; attention when it must pair |
| `.banner` (`Banner.tsx`), control plane away | Web | Banner | Neutral; attention when refused |
| `OfflineStrip`, `MacHostDownNotice` | Mac | Banner | Neutral |
| `HostOfflineStrip` | Remote | Banner | Neutral |
| `.offline-strip` (`OfflineStrip.tsx`), its orange dot | Web | Banner | Neutral (the dot is not orange) |
| `ArchivedStaleStrip`, `.offline-strip.archived-stale` | All | Banner | Neutral |
| `MissingFolderStrip`, `RemoteMissingFolderStrip`, `.problem.folder-gone` | All | Banner | Attention |
| `AccountMoveStrip`, `RemoteAccountMoveStrip` | Mac, Remote | Banner | Attention (warning in #5034) |
| `.account-move-strip` (`AccountMove.tsx`) | Web | Banner | Warning |
| `ContinueWhenBackStrip`, `RemoteContinueWhenBackStrip` | Mac, Remote | Banner | Neutral |
| `CostLimitBanner` | Mac, Remote | Banner | Failure |
| `OrgPolicyStrip`, `.policy-banner` | All | Banner | Neutral |
| `WorkErrorStrip` (amber, the `forge.waiting` wash), `ErrorStrip` in `.work-problem` | All | Banner | Failure |
| `ArchiveUndoStrip` (a card at the foot of the list) | Mac, Remote | Toast with Undo | Success |
| `.archive-undo` foot line (`Sidebar.tsx`) | Web | Toast with Undo | Success |
| A turn's Undo These Changes result ("↩︎ undone", its failure) | All | Sheet note in the card (no change) | Success, failure |
| A button's "Copied" label | All | Its own label (no change) | — |
| `.sheet-note`, `.sheet-note.failure` | Web | Sheet note (no change) | Neutral, failure |
| `.hint.failure`, `.hint.attention` beside a field | Web | Field note | Failure, attention |
| Inline red, orange or grey error `Text` | Mac, Remote | Field note or sheet note | Failure (never orange or grey) |
| `SentNotice`, the Notices list, `TurnError` rows | All | Notice or transcript row (no change) | — |

On the web, the fallbacks `--tint-success` and `--danger`, which no token declares, become
`--tint-vouched` and `--tint-failure`.

On the web, the kinds are components in `Web/src/views/MessageKinds.tsx` (#4740): `MessageBanner`,
the one toast (`Toasts`), and `ask`, which asks a choice in the page's own `<dialog>` in place of
`window.confirm`. Their tones, times and button words are in `Web/src/model/messageKinds.ts`.

On the Mac and the Remote, the kinds are `PaneBanner`, `FieldNote`, `SheetNote` and `Toast` in
`Shared/UI/Messages.swift` (#4738). Each has one toast host: the window's `WindowToasts`
(`App/Sources/WindowToast.swift`) and the Remote scene's `RemoteToasts`
(`Remote/Sources/RemoteToast.swift`, #4739), whose prompt bar says how high to float it.

## Where each surface reads it

| Surface | Reads | How it stays the same as `design/tokens.json` |
|---|---|---|
| Mac window | `Shared/UI/Paper.swift`, `Shared/UI/StateTint.swift`, `Shared/UI/TypeScale.swift`, `App/Resources/Assets.xcassets/AccentColor.colorset` | Written by hand. `DesignTokensTests` fails and says what to change when one differs from the file. `ConsistencyTests` makes sure no other Swift file names a colour or a font. |
| iPhone and iPad app | The same `Shared/UI` files, and `Remote/Resources/Assets.xcassets/AccentColor.colorset` | As the Mac window. |
| Web page | `Web/src/theme/tokens.css`, which `Web/src/theme/paper.css` imports | Made by `scripts/design.sh gen`. |
| Website (agentloops.dev) | `www/tokens.css` | Made by `scripts/design.sh gen`. `www/style.css` still has its own values until #4606. |
| Docs site | `docs/stylesheets/tokens.css`; the dark values follow the theme's `slate` scheme | Made by `scripts/design.sh gen`. The site still uses its theme's own colours and fonts until #4605. |
| Forge connector pages | `Go/internal/forgepages/tokens.css`, as `light-dark()` pairs | Made by `scripts/design.sh gen`. Each page's `common.css` still has its own values until #4607. In the app, the host gives a page the app's own colours and fonts, which it then uses. |
| Hosted sign-in pages, connector sign-in loopback page, org OIDC page | `Go/internal/paperpage/tokens.css` and `page.css`, inlined in each page's `<style>` | Made by `scripts/design.sh gen`. `page.css` names colours and fonts only by the tokens; the package's test fails when it names one raw. The OIDC page's policy lets in only the style's hash. |
| OAuth hand-back pages (oauth.agentloops.dev) | `deploy/site/www/oauth/tokens.css`, which each page links before `callback.css` | Made by `scripts/design.sh gen`. The site's policy is `style-src 'self'`, so the file is served from the same origin. |
| This page | The tables above | Made by `scripts/design.sh gen`. |

`scripts/lint.sh` runs `scripts/design.sh check`, so CI fails when a made file is stale.

### To change a token

1. Change `design/tokens.json`.
2. Run `scripts/design.sh gen`, and commit the files that it writes.
3. Run `DesignTokensTests`, and change the Swift files or the AccentColor assets that it
   names.

## How fresh the data is

Alex, 2026-11-12 (#5139): every page that shows cached data says how old it is, with
**"Last update <time ago>"**. Then the person knows how fresh the data is.

- **Cached data** is data from an earlier read: the local copy, a read that is shown while
  its source does not answer, a read when the page opens, or a poll of 30 s or more. A
  page that reads again every 5 s or less shows the line only after a read fails.
- **The time is the time of the read,** not the time of the content (a PR's `updatedAt`)
  and not the time the link went down. When parts of a page were read at different
  times, show the oldest.
- **The words are the same on every client:** "Last update just now" (under 1 minute),
  "Last update 5 min ago", "Last update 2 h ago", "Last update yesterday", then "Last
  update 3 Nov". Do not show a clock time ("Updated 14:02") for the age of a list.
- **It ticks:** every 10 s for the first minute, then once a minute.
- **Where:** in the pane's banner, after its words, when the pane has one; when not, at
  the top of the pane in `ink.secondary` at the caption step (at the trailing end of the
  pane's header when it has one). It is a status line, not a control.

The pages and the plan are in `specs/5139-last-update/spec.md`.

## Marks

The Blob, the app's mark, has one source: `scripts/design.sh marks` draws it, and writes
every app icon, favicon and touch icon from it. `scripts/design.sh marks --check` fails
when a committed mark differs.

## Copy

The words on every surface follow the project's writing rules (ASD-STE100, Simplified
Technical English), not this page.

## Not on this page

- The words that the app shows (see **Copy**).
- The controls that each platform draws for itself, such as a Mac menu or an iPhone
  switch.
- The looks of the app on Windows, Linux and Android, which follow each platform.
