---
diataxis: reference
description: The look of the app, the docs site and the website — its principles, every token, the type steps, and where each surface reads them.
---

# The design system

The app has one look, **Paper**, and this page writes it down: the principles, every token
with its light and dark value, the type steps, and the files where each surface reads them.
The Mac window, the iPhone and iPad app and the web page draw it today. The docs site, the
website (agentloops.dev) and the forge connector pages move onto it next (#4600).

The values come from one file, `design/tokens.json`. The tables on this page are made from
that file by `scripts/design.sh gen`, and `scripts/design.sh check` fails when they do not
agree with it, so this page cannot drift from the code.

## Principles

- **Paper, not glass.** Most of what the app shows is prose: a report, a transcript, a
  document that an agent writes. The ground is a cool near-white, not pure white, and the
  ink is charcoal, not pure black. A list is rows under hairline rules, not a stack of
  cards. Only the things that are on top float: the prompt bar, a sheet, a menu. They sit
  on a short, neutral shadow, as paper lifted a little off a desk.
- **One sans-serif and one monospace.** Both are the system's own fonts. Nothing is loaded
  from the network: no web font, on any surface.
- **One accent.** The cobalt of the app icon is for links, focus, controls and the
  prominent button. Nothing is drawn in the accent on a selection, where it is too faint.
- **Three state tints, and only Needs you in colour in a list.** Orange means that a
  person is needed, red means that something failed, and green means an ending that the
  app can vouch for (approved, done). In a list, only **Needs you** is drawn in colour.
- **Label hues never read as a state.** A session label that names an issue (`#12`) is
  teal, and one that names a pull request (`P#12`) is violet. Neither is a tint.
- **Every text colour can be read.** Each one clears 4.5:1 on the ground and on the well,
  in light and in dark.
- **Marketing is a size of the system, not a second look.** The website keeps its hero
  title with the two `display` type steps.

## Colour

Each colour has a light and a dark value; the surface follows the system's appearance. The
CSS name is the custom property that the token files declare. The Swift name is where the
Mac window and the iPhone and iPad app hold the same value.

<!-- design.sh gen: colour -->
| Token | CSS | Swift | Light | Dark | For |
|---|---|---|---|---|---|
| ground | `--paper-ground` | `Paper.ground` | `#f7f8f9` | `#1c1d20` | The page every column sits on. |
| sidebar | `--paper-sidebar` | `Paper.sidebar` | `#f0f1f3` | `#161719` | The folders column, one shade deeper. |
| raised | `--paper-raised` | `Paper.raised` | `#ffffff` | `#26282c` | What floats: the prompt bar, cards, menus. |
| well | `--paper-well` | `Paper.well` | `#f0f2f4` | `#2a2d31` | What is set into the page: code, your own message. |
| wash | `--paper-wash` | `Paper.wash` | `#e7eaee` | `#33363b` | A row under the pointer, a picked item. |
| rule | `--paper-rule` | `Paper.rule` | `#dde1e6` | `#3a3e44` | Hairlines between rows, and round raised things. |
| ink | `--paper-ink` | `Paper.ink` | `#1c1d20` | `#e8eaed` | Text, and the prominent button's fill. |
| selection | `--paper-selection` | `paperSelection` | `#d8dee6` | `#3a3e44` | A selection. Nothing is drawn in the accent on it. |
| shadow | `--paper-shadow` | `Paper.shadow` | `#20242a` at 10% | `#000000` at 10% | Under a raised thing: short and neutral, paper lifted a little off the desk. |
| accent | `--accent` | `AccentColor.colorset` | `#1f5fc8` | `#7fb0ff` | The app icon's cobalt: links, focus, controls and the prominent button's fill. |
| tint.attention | `--tint-attention` | `StateTint.orange` | `#ba4a13` | `#f0a06b` | Needs you; the only tint drawn in a list. |
| tint.failure | `--tint-failure` | `StateTint.red` | `#b4232b` | `#f08086` | Failed. |
| tint.vouched | `--tint-vouched` | `StateTint.green` | `#2d765c` | `#8bc6a7` | Approved, done: an ending the app can vouch for. |
| label.issue | `--label-issue` | `Paper.issue` | `#0e6b82` | `#6cc6db` | A label naming an issue, #12. |
| label.pull | `--label-pull` | `Paper.pull` | `#7442b8` | `#b79af0` | A label naming a pull request, P#12. |
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
| control | `--radius-control` | `Paper.Radius.control` | `7px` | Chips, the rail, inputs. |
| card | `--radius-card` | `Paper.Radius.card` | `10px` | Rows, wells, cards. |
| floating | `--radius-floating` | — | `16px` | Sheets, menus, the prompt bar (web). |
<!-- /design.sh gen -->

## Fonts

<!-- design.sh gen: font -->
| Token | CSS | Stack | For |
|---|---|---|---|
| text | `--font-text` | `-apple-system, BlinkMacSystemFont, system-ui, sans-serif` | The system's sans-serif, for everything a person reads. Nothing is loaded from the network. |
| mono | `--font-mono` | `ui-monospace, SF Mono, Menlo, monospace` | The system's monospace, for code. |
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

## Where each surface reads it

| Surface | Reads | How it stays the same as `design/tokens.json` |
|---|---|---|
| Mac window | `Shared/UI/Paper.swift`, `Shared/UI/StateTint.swift`, `Shared/UI/TypeScale.swift`, `App/Resources/Assets.xcassets/AccentColor.colorset` | Written by hand. `DesignTokensTests` fails and says what to change when one differs from the file. `ConsistencyTests` makes sure no other Swift file names a colour or a font. |
| iPhone and iPad app | The same `Shared/UI` files, and `Remote/Resources/Assets.xcassets/AccentColor.colorset` | As the Mac window. |
| Web page | `Web/src/theme/tokens.css`, which `Web/src/theme/paper.css` imports | Made by `scripts/design.sh gen`. |
| Website (agentloops.dev) | `www/tokens.css` | Made by `scripts/design.sh gen`. `www/style.css` still has its own values until #4606. |
| Docs site | `docs/stylesheets/tokens.css`; the dark values follow the theme's `slate` scheme | Made by `scripts/design.sh gen`. The site still uses its theme's own colours and fonts until #4605. |
| Forge connector pages | `Go/internal/forgepages/tokens.css`, as `light-dark()` pairs | Made by `scripts/design.sh gen`. Each page's `common.css` still has its own values until #4607. In the app, the host gives a page the app's own colours and fonts, which it then uses. |
| This page | The tables above | Made by `scripts/design.sh gen`. |

`scripts/lint.sh` runs `scripts/design.sh check`, so CI fails when a made file is stale.

### To change a token

1. Change `design/tokens.json`.
2. Run `scripts/design.sh gen`, and commit the files that it writes.
3. Run `DesignTokensTests`, and change the Swift files or the AccentColor assets that it
   names.

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
