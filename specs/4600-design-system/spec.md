# A design system: one look for the app, the docs site and www (#4600)

**Status:** filed 2026-11-10, Product Owner. The epic is #4600; its children are its plan.
**Clients:** none directly. The app already draws the system; this epic writes it down and extends it to the docs site, www and the forge connector pages.

## What Alex asked for

A design system: a consistent look and feel that extends to the docs and marketing sites (2026-11-10).

## Where each surface stands today

The app has one look, Paper (#326 crisp paper, #695 cobalt), and it is enforced: `Shared/UI/Paper.swift`, `StateTint.swift` and `TypeScale.swift` are the only places Swift names a colour or a font (`ConsistencyTests`), and `Web/src/theme/paper.css` mirrors them by hand. Nothing outside the app reads those values.

| Surface | Drawn by | Ground (light) | Dark | Accent | Fonts | Radius / shadow |
|---|---|---|---|---|---|---|
| Mac window, Remote | `Shared/UI` | `#F7F8F9` | `#1C1D20` | `#1F5FC8` / `#7FB0FF` (the asset) | system sans, SF Mono | 7 / 10; neutral 10% |
| Web page | `Web/src/theme/paper.css`, `console.css` | same | same | same | same, nothing loaded | 7 / 10 / 16; neutral 10% |
| Docs site | `mkdocs.yml`, Material via Zensical | Material white | Material slate | Material **indigo** | **Roboto from Google Fonts** (Material's default) | Material's |
| www | `www/style.css` | `#FFFFFF`, bands `#F3F6FC` | **navy `#0B1020`** | **`#1A52C0`**, ink navy `#0E1A3A` | system sans | 14; blue drop shadow |
| Forge connector pages | `Go/internal/*mcp/pages/common.css` | `#FFF` | `#111` | `#33C` links | system | 6 |

Also: `Web/src/app.css` names about 30 raw hex colours (GitHub's `#8250df`, `#1a7f37`, `#cf222e`, `#3fb950`, `#f85149`, greys) outside the token file, where `paper.css` says nothing else names a colour.

## Surfaces (#4601)

| Surface | Drawn by | Colours (where) | Fonts | Marks |
|---|---|---|---|---|
| Mac window | SwiftUI, `App/Sources`, `Shared/UI` | Paper: 11 light/dark pairs, `Shared/UI/Paper.swift:33-46,56,80-82,103-105` (ground `#F7F8F9`/`#1C1D20`, sidebar, raised, well, wash, rule, ink, issue `#0E6B82`/`#6CC6DB`, pull `#7442B8`/`#B79AF0`, shadow, selection); accent `#1F5FC8`/`#7FB0FF` from `AccentColor.colorset`; StateTint orange/red/green `StateTint.swift:51-53`; **outside the token files**: GitHub state colours (`WorkLook.swift:45-57`, `WorkView.swift:449-452`), amber `0x9A6700/0xD29922` ×7 in `Shared/UI/Work/`, code ink `CodeText/InkValues.swift:19-44`, `Color(white:)` in `ConnectGitHubSheet.swift:290` and `WorkTimelineView.swift` | system only: `TypeScale.swift`, 5 steps; no `Font.custom`; nothing from the network | app icon, Dock moods (`DockMood.swift`), Huddle (`Huddle.swift:147-149`: `#3A78E6`, `#CFE3FF`, `#0E1A3A`), crowd (`Multiplier/Crowd.swift`) |
| Agents Host menu bar | SwiftUI, `Host/Sources/HostApp.swift:47` | none | system | `MenuBarBlob` template |
| Remote (+ widget, notification) | SwiftUI, `Remote/Sources`, `Shared/UI` | Paper and StateTint via `Shared/UI`; own `AccentColor.colorset`, same values; system colours in `Sidebar/*`, `AgentCard.swift`, `RuntimesView.swift`, `ShellKeys.swift` | system (TypeScale `uiFont`) | app icon 1024, Huddle (`StartAgentView.swift:100`, `PairingView.swift:24`) |
| Web page (Host and control plane serve `Web/dist`) | Preact + CSS, `Web/src` | `theme/paper.css`: 26 unique hex, mirrors Paper by hand, `--accent #1f5fc8/#7fb0ff`; `console.css`: `#fff`; **`app.css`: 85 hex, 32 unique**: GitHub greens `#1a7f37 #1f883d #238636 #3fb950`, purples `#8250df #8957e5 #a371f7`, reds `#cf222e #da3633 #f85149`, greys/ambers `#59636e #6e7781 #8b949e #bf8700 #9a6700 #d29922` (lines 2102-2125, 2162-2168, 2272-2472); syntax fallbacks lines 443-448 (`#8656a3 #287a50 #a45a12 #777 #246b8a`, differ from Swift's `InkValues`); fallbacks for never-defined `--tint-success` (`#1e8a4c`), `--danger` (`#bd4238`), `--code-*`, `--mono`; timeline lines 2526-2530; TSX: `Huddle.tsx`, `Multiplier.tsx`, `WorkTimeline.tsx:44` (12 system hex), `model/work.ts:343`; `index.html:13-14` and `manifest.webmanifest` theme-color `#f7f8f9`/`#1c1d20` | `paper.css:55-56` system sans + `ui-monospace, "SF Mono", Menlo`; FR-034 (`specs/071-web-remote/spec.md:431`): nothing from another origin | favicons ×3 moods, PWA icons, touch icon (`Web/assets`), Huddle (`NewAgent.tsx:494`, `Pairing.tsx:130`) |
| Forge connector pages (MCP Apps, 18 pages in 9 connectors) | embedded static HTML/CSS/JS, `Go/internal/*mcp/pages/` | `common.css` ×9 byte-identical: 27 unique hex as `light-dark()` pairs (`#fff/#111`, `#33c/#99f` links, `#b00/#f77`, `#070/#7c7`, `#8a5a00/#e8b04a`, …); `labels.js:11-12` text `#000`/`#fff`. **Fallbacks only**: `bridge.js:49-52` takes the host's `hostContext.styles.variables`, which `Go/internal/agentsd/views.go:917-980` (`viewThemeVariables`) fills with ~22 Paper hex as `--color-*` and `--font-sans`/`--font-mono` | `system-ui, sans-serif`; `ui-monospace, monospace`; overridden by the host | none |
| Docs site (Zensical 0.0.65, `scripts/docs.sh:12`, Material theme in `mkdocs.yml`) | mkdocs/Zensical | `mkdocs.yml:25-39` only: `primary: white`/`black`, `accent: indigo`; no `extra_css`, no `docs/stylesheets/`, no `overrides/` | **no `font:` key → Material's default Roboto + Roboto Mono from Google Fonts**: the one surface that loads a font from the network | `docs/assets/logo.png` 256, `favicon.png` 64 (same bytes as Web's) |
| www (agentloops.dev) | static `www/index.html`, `www/style.css` | 15 unique hex: `--cobalt #1a52c0`, `--cobalt-light #5b9bff`, `--ink #0e1a3a`, `--text #1d2433/#e6eaf2`, `--muted #5a6478/#9aa4b8`, `--page #ffffff/#0b1020`, `--band #f3f6fc/#121a30`, `--line #dde3ef/#26304a`, `--link #1a52c0/#7fb0ff`; not Paper | system sans + mono, `style.css:1` "no web fonts"; CSP `'self'` + `youtube-nocookie.com` | `icon.svg`, `favicon.png`, `apple-touch-icon.png` (hand copies, #4603), screenshots `assets/shots/*` |
| Hosted sign-up/sign-in/account | Go `html/template`, `Go/internal/hosted/pages.go:418-509` | 12 unique hex: `#1d1d1f #fbfbf8 #6e6e73 #b3261e #c7c7cc #fff #2c5fd6 #f0f0ec`, dark `#1c1c1e #f2f2f7 #2c2c2e #48484a`; not Paper | `-apple-system, system-ui, sans-serif`; loads Turnstile's script when on | none (`<h1>Agents</h1>`) |
| OAuth hand-back (oauth.agentloops.dev) | static `deploy/site/www/oauth/*.html`, `callback.css` | `#1d1d1f #f4f1ea #2b4f86`, dark `#f2f2f2 #1c1c1e #8fb1ea`; warm paper, unlike all others | system sans; CSP `default-src 'none'` | none |
| Connector sign-in loopback | Go string, `Go/internal/agentsd/mcpsignin.go:566-569` | `#222` | inline `-apple-system` | none |
| Org OIDC fallback | Go string, `Go/internal/controlplane/identity_oidc_http.go:56-61` | none | browser default | none |
| App Store / TestFlight listing | text, `promo/app-store/listing.md`; screenshots `promo/app-store/screenshots/` | none of its own | n/a | the app's own icon and UI; out of scope |
| GitHub social preview, README | GitHub settings; `README.md` has no images | none in the repo | n/a | out of scope |

### Material variables a token must set (for #4605)

`--md-primary-fg-color` (+`--light/--dark`), `--md-primary-bg-color` (header, tabs), `--md-accent-fg-color` (+`--transparent`), `--md-default-bg-color`, `--md-default-fg-color` (+`--light/--lighter/--lightest`), `--md-typeset-color`, `--md-typeset-a-color`, `--md-typeset-mark-color`, `--md-typeset-table-color`, `--md-typeset-kbd-color`, `--md-code-bg-color`, `--md-code-fg-color` (`--md-code-hl-*` only once `pymdownx.highlight` is on; it is not today, so code blocks have no syntax colour), `--md-admonition-fg-color`, `--md-admonition-bg-color` (each type's own hue is hard-coded in Material, not a variable), `--md-footer-fg-color` (+`--light/--lighter`), `--md-footer-bg-color` (+`--dark`), `--md-mermaid-*`. Features in use: `navigation.tabs/.sections/.indexes/.top/.footer`, `search.suggest/.highlight`, `content.code.copy`; extensions `admonition`, `pymdownx.details`, `pymdownx.superfences` (mermaid), `pymdownx.tabbed`. Fonts: `theme.font: false` loads none and falls back to the system stack; check that Zensical honours it (unverified here: no local build).

### Four blues, three grounds

Accent `#1F5FC8`/`#7FB0FF` (app), icon and www cobalt `#1A52C0`/`#5B9BFF`, hosted `#2C5FD6`, OAuth `#2B4F86`/`#8FB1EA`, plus the docs' indigo. Grounds: Paper `#F7F8F9`, hosted `#FBFBF8`, OAuth `#F4F1EA`, www `#FFFFFF`/`#0B1020`, docs white/slate.

## Marks

The Blob (#1237) has one source: `scripts/design.sh marks` draws it (one body path, two eyes, a
smile, the cobalt plate `#5B9BFF` → `#1A52C0`, outline `#3A78E6`, ink `#0E1A3A`), writes its SVG
parts to `design/logo/blob/final/`, and renders every PNG and `.ico` below with one renderer,
AppKit (`design/logo/blob/final/render.swift`), and `sips`. Running it twice changes nothing.
`scripts/design.sh marks --check` writes into a temporary folder and fails when a committed mark
differs; CI's `marks` job runs it on the macOS 27 image (#4615). The inventory is #4603's.

| Path | Format | Sizes | Made by | Shows |
|---|---|---|---|---|
| `App/Resources/Assets.xcassets/AppIcon.appiconset/` | PNG RGBA | 16, 32, 64, 128, 256, 512, 1024 (mac @1x/@2x, 10 entries) | `marks` (`mac.svg`; `mac-small.svg` at 16@1x, 16@2x, 32@1x) | happy Blob on the shadowed macOS plate (824 in 1024) |
| `Remote/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png` | PNG RGB, no alpha | 1024 (single size) | `marks` (`ios.svg`, flattened through JPEG) | full-bleed happy Blob |
| `App/Resources/Assets.xcassets/DockAsleep.imageset/dock.png`, `DockQuizzical.imageset/dock.png` | PNG RGBA | 1024 | `marks` (`mac-asleep.svg`, `mac-quizzical.svg`) | eyes shut + "z"; tilted head, raised brow + "?" (`App/Sources/DockMood.swift`) |
| `App/Resources/Assets.xcassets/MenuBarBlob.imageset/menu-bar.svg` | SVG template | 19×18 pt | `marks` | outline-only Blob in `#000`, heavier smile, no plate |
| `Shared/UI/Huddle.swift` (`Blob`, `BlobShape`, `Smile`), `Shared/UI/Multiplier/Crowd.swift` | Swift-drawn | any | code, same path and hex by hand | Huddle (back Blobs `#CFE3FF`), crowd |
| `Web/src/views/Huddle.tsx` (`BODY`, `BlobParts`), `Web/src/views/Multiplier.tsx` `drawBlob` | inline SVG / canvas | any | code, same path and hex by hand | Huddle, crowd |
| `docs/assets/logo.png`, `docs/assets/favicon.png` | PNG RGBA | 256, 64 | `marks` (`tile.svg`) | rounded tile; the favicon is the same bytes as the web page's |
| `docs/favicon.ico` | ICO | 16, 32, 48 | `marks` (`tile-small.svg` at 16 and 32, `tile.svg` at 48) | rounded tile, heavy smile at 16 and 32; at the site's root |
| `Web/assets/favicon.png`, `favicon-asleep.png`, `favicon-quizzical.png` | PNG RGBA | 64 | `marks` | tile, three moods (`Web/src/model/iconMood.ts`); no `.ico`, because the mood changes the tab's one icon link |
| `Web/assets/icon-192.png`, `icon-512.png`, `icon-maskable-512.png`, `apple-touch-icon.png` | PNG RGBA | 192, 512, 512, 180 | `marks` (`tile.svg`; `ios.svg` for maskable and touch) | tile; full bleed |
| `www/assets/icon.svg` | SVG | 1024 viewBox | `marks` (a copy of `tile.svg`) | tile |
| `www/assets/favicon.png`, `www/assets/favicon.ico`, `www/assets/apple-touch-icon.png` | PNG RGBA, ICO | 64; 16, 32, 48; 180 | `marks`, the same bytes as the web page's | tile; full-bleed touch icon |
| `design/logo/blob/final/tile-1024.png`, `tile-asleep-1024.png`, `tile-quizzical-1024.png` | PNG RGBA | 1024 | `marks` | the tiles at full size, for reference |
| `www/index.html` `og:image` → `www/assets/shots/mac.png` | PNG | 1440×900 | screenshot (`promo/shots/`) | the app, not a mark; out of scope |
| `design/logo/colour/*`, `design/logo/blob/{blob,three-blobs,crowd,faces}` | SVG, PNG | various | `make.py` | archive: the old violet Blob, not shipped |
| `alexec/iphone-app-starter`: `App/…/AppIcon.png` | PNG | 1024 | template (#3707, #4561) | a starter app's placeholder, out of scope |

No `.icns` is in the repo; `actool` builds it from the icon set.

## Decisions (Product Owner, 2026-11-10; Alex can overrule)

1. **The system is Paper, written down and extended.** Not a new look: Alex chose it in #326 and #695 and every client draws it.
2. **One token source, generated outputs, a test.** `design/tokens.json` (W3C Design Tokens shape) and `scripts/design.sh gen` write `tokens.css` for the web page, www, the docs site and the forge pages. A Swift test says what to change in the three Swift files by hand. This is the `Packages/Wire` pattern.
3. **No web font anywhere.** The app loads none (`paper.css` FR-034). Google Fonts is a sub-processor the compliance pack does not list.
4. **Marketing is a size of the system, not a second look.** www keeps its hero through `display` type steps that the system gains.
5. **The written system is one docs page**, `docs/reference/design-system.md`.
6. **Milestone `1.0 Public release`**, because the docs site and www are the public face.

## The tokens

The values the app has today. `design/tokens.json` holds them (#4602; the repo's folder is `design/`), `scripts/design.sh gen` makes the CSS token files from it, and `DesignTokensTests` checks `Paper.swift`, `StateTint.swift`, `TypeScale.swift` and the AccentColor assets against it.

### Colour

| Token | Light | Dark | For |
|---|---|---|---|
| ground | `#F7F8F9` | `#1C1D20` | the page every column sits on |
| sidebar | `#F0F1F3` | `#161719` | the folders column, one shade deeper |
| raised | `#FFFFFF` | `#26282C` | what floats: the prompt bar, cards, menus |
| well | `#F0F2F4` | `#2A2D31` | what is set into the page: code, your own message |
| wash | `#E7EAEE` | `#33363B` | a row under the pointer, a picked item |
| rule | `#DDE1E6` | `#3A3E44` | hairlines between rows and round raised things |
| ink | `#1C1D20` | `#E8EAED` | text |
| selection | `#D8DEE6` | `#3A3E44` | a selection |
| shadow | `#20242A` 10% | `#000000` 10% | under a raised thing: short, neutral |
| accent | `#1F5FC8` | `#7FB0FF` | the icon's cobalt: links, focus, the prominent button |
| tint.attention | `#BA4A13` | `#F0A06B` | Needs you; the only tint drawn in a list |
| tint.failure | `#B4232B` | `#F08086` | failed |
| tint.vouched | `#2D765C` | `#8BC6A7` | approved, done |
| label.issue | `#0E6B82` | `#6CC6DB` | a label naming an issue, `#12` |
| label.pull | `#7442B8` | `#B79AF0` | a label naming a pull request, `P#12` |
| forge.open | `#1A7F37` | `#3FB950` | an item's state on its forge (GitHub's colours, #4618): open, a check passed |
| forge.done | `#8250DF` | `#A371F7` | a closed issue that is done, a merged pull request |
| forge.draft | `#6E7781` | `#8B949E` | not planned, a draft |
| forge.closed | `#CF222E` | `#F85149` | closed without a merge, a check failed, changes requested |
| forge.waiting | `#9A6700` | `#D29922` | the forge's amber: waits on someone, still runs |
| forge.waiting-wash, waiting-rule | `#FFF8C5`, `#D4A72C` | `#2F2A1A`, `#6B5A1E` | a notice in the amber: fill, edge |
| forge.mark | `#212121` | `#212121` | the disc under a connector's letters |
| forge.fill.open, done, closed, draft | `#1F883D`, `#8250DF`, `#CF222E`, `#59636E` | `#238636`, `#8957E5`, `#DA3633`, `#6E7681` | a state chip's fill under white words |
| code.comment … code.punctuation | `InkValues.swift` | | code's ink, 8 roles (041); `DesignTokensTests` checks `InkValues.swift` |

Every text colour clears 4.5:1 on the ground and the well; the accent is never drawn on a selection. In Swift a colour's value is written only in `Paper.swift`, `StateTint.swift` and `InkValues.swift`; `ConsistencyTests.noCallSiteWritesAColourValue` fails on one anywhere else in `App/Sources`, `Remote/Sources` and `Shared/UI` that is not on its allow-list (#4618).

### Shape

| Token | Value | For |
|---|---|---|
| radius.control | 7 | chips, the rail, inputs |
| radius.card | 10 | rows, wells, cards |
| radius.floating | 16 | sheets, menus, the prompt bar (web) |

### Type

One sans-serif (the system's) and one monospace. Nothing is loaded from the network.

| Step | Mac | iOS | Web | For |
|---|---|---|---|---|
| title | `.title` 22 | `.title` 28 | `h1` | a page's title |
| reading | `.title3` 15 | `.body` 17 | 1rem (18px at the browser default, #2135) | prose |
| supporting | `.body` 13 | `.subheadline` 15 | 0.875rem | a row's second line |
| fine | `.subheadline` 11 | `.footnote` 13 | 0.75rem | a timestamp, a count |
| code | `.body` mono 13 | `.subheadline` mono 15 | 0.875rem mono | code, paths, commands |
| display.1, display.2 | — | — | `clamp(2rem, 5vw, 3.2rem)`, 1.8rem | www's hero and section titles (new, decision 4) |

## The plan

| Step | Issue | What | Size |
|---|---|---|---|
| 1 | #4601 | Spike: inventory every surface a person sees | S |
| 1 | #4602 | `design/tokens.json`, `scripts/design.sh gen`, the Swift test | S |
| 1 | #4603 | Spike: the brand marks, one Blob source | S |
| 2 | #4604 | The design-system page in the docs | S |
| 2 | #4605 | The docs site on the design system (waits for Alex) | S |
| 2 | #4606 | www on the design system (waits for Alex) | S |
| 2 | #4607 | The forge connector pages on the tokens | XS |
| 2 | #4608 | The web page's raw colours onto the tokens | S |
| 3 | #4609 | Lint: no colour outside a token file | XS |

The "blocked by" links on GitHub are the order; this table is prose.

## Open questions

1. Are the hosted sign-in and pairing pages the control plane serves, and the sign-up mail, in scope? Answered by #4601: the hosted and OAuth pages are in (#4617), the pairing page is the web page (#4608), and no mail goes out.
2. Does the docs site keep Material's layout? Recommended yes, with Paper's tokens; a layout of its own is a later epic.
3. Is the Blob the same on www, the docs and the app icon? Answered by #4603, and #4615 made one source: see `## Marks`.

## Out of scope

A new look; the Remote's or the Mac's own controls; the Windows, Linux and Android looks (#4471, #4461, #4482 follow each platform on purpose); copy, which the writing-voice rules own.
