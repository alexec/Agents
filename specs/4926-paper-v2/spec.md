# Paper, version 2: the design system (#4926)

**Status:** spike, 2026-11-12. Epic #4925. No product code: this spec, a contact sheet and the stories.
**Clients:** none in the spike. The build is Core: the Mac window, the Remote and the web page.

## What Alex asked for

The app must be very comfortable to use and nice to look at. Paper (#326, #4600, `design/tokens.json`) is close, but it has not enough charcoal.

Alex's words on the earlier rounds (2026-11-12):

1. On the handwriting mock: the goal is **a clean, modern character, a look of our own that separates us from the competition, simple, very easy on the eye and very easy to read.** No handwriting.
2. On the font mocks: show **a high-fidelity mock**.
3. On the high-fidelity shots of the product: **get the font, the colour and the iconography right together.** Show **a contact sheet of the design system**: every component, the colours and how they are used, the icons and what they mean, the common components. **Borders and shading must be right, and very subtle.**

## The contact sheet

`contact-sheet.html` is the design system on one page, light and dark (`?mode=dark`). `contact-sheet.py` writes it, with Lucide's SVGs inlined (`python3 contact-sheet.py <lucide-static icons dir>`). The pictures are in the PR (`pr-<n>/sheet-light.png`, `sheet-dark.png`). It has five parts:

- **Colour:** every token, light and dark, what it is for, and its contrast on the ground.
- **Type:** the scale, the letters that are easy to confuse, and the four faces we compared.
- **Edges and depth:** the four levels, the lines and the radii.
- **Icons:** each icon with its name and what it means: states, things, actions, notices.
- **Components:** buttons, fields, toggles, a segmented control, labels and state badges, notices, a menu, a tooltip, a toast, progress, the session list (selected, hover, waiting, unread, failed), the chat (your message, a tool row, code, a question card), the prompt bar, a sheet and an empty state.

## Principles

1. **Quiet.** Few colours, each with one job. Colour means something: a link, a state or a label. It is never decoration.
2. **Warm charcoal on paper.** No pure white and no pure black. These come from the dyslexia guides and are easy on the eye.
3. **Edges you feel more than see.** A hairline at about 1.2:1 separates two things. A shadow you barely see lifts a thing. Only a sheet casts a shadow you notice. A control's own edge is the exception: it is 3:1, so a person can find it (WCAG 1.4.11).
4. **One face, one icon set, on all three clients.** Today the Mac and the Remote draw SF Symbols, and the web page draws Unicode glyphs (`✎ ▤ ◉ ▦ ✓`). One set makes the three clients look like one product.

## Token changes (`design/tokens.json`)

### Colour

| Token | Today light / dark | v2 light | v2 dark | Used for |
|---|---|---|---|---|
| `color.ground` | `#f7f8f9` / `#1c1d20` | `#f7f6f2` | `#222220` | the page |
| `color.sidebar` | `#f0f1f3` / `#161719` | `#f1efea` | `#1c1c1a` | the folders column |
| `color.raised` | `#ffffff` / `#26282c` | `#fdfcfa` | `#2a2a27` | cards, the prompt bar, menus, sheets |
| `color.well` | `#f0f2f4` / `#2a2d31` | `#efede8` | `#2d2d2a` | code, your own message, a filled field |
| `color.wash` | `#e7eaee` / `#33363b` | `#e9e6e0` | `#34332f` | hover; a pressed quiet button |
| `color.selection` | `#d8dee6` / `#3a3e44` | `#e2ddd3` | `#3d3c37` | the picked row |
| `color.ink` | `#1c1d20` / `#e8eaed` | `#262522` | `#ebe8e1` | text, icons, the prominent button |
| `color.secondary` (new) | system `.secondary` | `#5c5952` | `#aba79e` | second lines, speakers, section headings |
| `color.tertiary` (new) | system `.tertiary` | `#6e6a63` | `#959189` | timestamps, counts, placeholders (only on ground, sidebar, raised) |
| `color.rule` | `#dde1e6` / `#3a3e44` | `#e4e1da` | `#3a3935` | hairlines, about 1.2:1 |
| `color.edge` (new) | none | `#8f8a80` | `#77736b` | a field's, checkbox's or toggle's edge, 3:1 |
| `color.tint.attention` | `#ba4a13` / `#f0a06b` | `#a8420f` | `#f0a06b` | needs you |
| `color.tint.vouched` | `#2d765c` / `#8bc6a7` | `#2a7157` | `#8bc6a7` | done, approved |

The accent, the failure tint, the issue and pull labels, the code inks and the forge colours keep their values.

### Depth (new: `shadow.*`, replacing the one `color.shadow`)

| Token | Light | Dark | Used for |
|---|---|---|---|
| `shadow.raised` | `0 1px 2px` at 6% | `0 1px 2px` black at 30% | cards, buttons (with a `rule` hairline) |
| `shadow.floating` | raised + `0 6px 20px` at 8% | + `0 8px 24px` at 35% | menus, the prompt bar, toasts |
| `shadow.sheet` | `0 2px 6px` 5% + `0 18px 48px` 12% | 30% + 50% | sheets and dialogs (no hairline) |
| `focus` | 3px ring, accent at 28% | the same | keyboard focus |

The shadows' colour is the ink (`#262522`) in the light and black in the dark. On the Mac and the Remote, each one is a `.shadow` pair in `Paper.swift`.

### Radius

The values do not change. `radius.code` (5) and `radius.pill` (99) are added: code at 5, a control at 7, a card at 10, floating things at 16, and a state badge as a pill.

### Type

- `font.text`: `["Atkinson Hyperlegible Next", <the system stack>]`.
- `font.mono`: `["Atkinson Hyperlegible Mono", <the system mono stack>]`.
- New: `type.leading.reading` (1.5), `type.tracking.reading` (0.01em), and word spacing 0.06em.
- The steps keep their sizes and text styles.

### Icons (new: `icon.*`)

| Token | Value |
|---|---|
| `icon.set` | Lucide (ISC), pinned version |
| `icon.stroke` | 1.5 |
| `icon.size` | 16 in a row, 18 in a control |

The meanings are the table in the contact sheet's Icons part. They go into `design/icons.json` (name → meaning → Lucide name), so the three clients use the same icon for the same thing.

## Contrast (WCAG 2.2 AA)

The contact sheet prints each colour's ratio on the ground, light and dark. Every text colour is 4.5:1 or more on each surface it is drawn on. `tertiary` is drawn only on the ground, the sidebar and raised surfaces, where it is 4.6:1 to 5.3:1. A tint on `selection` falls under 4.5:1, as it does today, so nothing is drawn in a tint on a selection. The edge of a control is 3:1 or more on the ground and on raised surfaces. The first story adds these pairs to `DesignTokensTests`.

## Fonts

All the faces we compared are SIL OFL 1.1 and maintained. Each works in SwiftUI (`Font.custom(_:size:relativeTo:)`, which follows Dynamic Type) and on the web (self-hosted `@font-face`; FR-034: nothing from another origin).

| Font | Size (Latin woff2) | Verdict |
|---|---|---|
| **Atkinson Hyperlegible Next + Mono** (Braille Institute, 2025) | 34 KB + 18 KB | **Proposed:** letters drawn to differ; a mono of the same family; few competitors use it |
| Lexend | 40 KB | wider and rounder; less fits in the list |
| Figtree | 20 KB | clean, but close to Inter, so it is less our own |
| System (SF) | 0 | what we have; the look most tools have |

**How it ships.** `design/fonts/` holds the faces and `OFL.txt`. The Mac and the Remote register them at launch with `CTFontManagerRegisterFontsForURL` from `Shared/UI`'s bundle. The web page serves them from `Web/assets/fonts/`. The About screen's acknowledgements name them.

## Icons

**Lucide** (ISC, 1.72.0 on 2026-11-11, about 1,600 icons, released weekly) at a 1.5 stroke.

- **Why Lucide.** It is thin and round, so it is quiet. It meets the library rule in AGENTS.md: permissive, updated in the last 12 months, widely used, and pinned in `package.json`.
- **Not Phosphor.** Its last release was 2025-03-31, which fails the 12-month rule.
- **Not SF Symbols.** Apple's licence forbids them on the web.
- **How it ships.** On the web, the SVGs are imported from `lucide-static` (pinned) and inlined at build time. On the Mac and the Remote, an asset catalogue of symbol images is made from the same SVGs by `scripts/design.sh icons`, so `Image("lucide.circle-check")` scales with the text.

## Reading and dyslexia

These rules come from the British Dyslexia Association's style guide and from WCAG 1.4.12:

- **Line height:** 1.5 for reading text.
- **Spacing:** a little letter and word spacing.
- **Line length:** at most about 70 characters.
- **Emphasis:** no italics or capitals; use bold.
- **Text size:** it follows the person's own text size.

The web page must not clip when a person sets 0.12em letter spacing and 0.16em word spacing.

## Decisions

- Decided: no handwriting, because Alex wants a clean, simple look (2026-11-12).
- Decided: borders and shadows are very subtle (hairline 1.2:1, shadows of 6–12%), but a control's edge is 3:1, because Alex asked for subtle and WCAG 1.4.11 needs a control to be found. Alex can overrule.
- Decided: one icon set, Lucide at a 1.5 stroke, on all three clients, because the clients draw different icons today and Lucide is the one set that meets the library rule. Alex can overrule.
- Decided: the colour, depth, radius and spacing tokens above, because each passes WCAG AA and follows the principles. Alex can overrule.
- Decided: no setting to turn the face off, because one clear look is simpler. Alex can overrule.
- **Alex's choice (pending):** the contact sheet as a whole, including the face (Atkinson Hyperlegible Next is proposed).

## Stories (Core: Mac, Remote, web)

These are filed as sub-issues of #4925 after Alex approves the sheet. Each is blocked by #4926. Story 1 goes first; stories 2, 3 and 4 follow it and can run at the same time.

1. **Paper v2 tokens:** colour, depth, radius and reading spacing (`design/tokens.json`, `Paper.swift`, `StateTint.swift`, `paper.css`, contrast pairs in `DesignTokensTests`).
2. **The face:** Atkinson Hyperlegible Next and Mono on the three clients (`design/fonts/`, `TypeScale.swift`, `Web/assets/fonts`, acknowledgements).
3. **One icon set:** Lucide on the three clients (`design/icons.json`, `scripts/design.sh icons`, an asset catalogue, the web's glyphs replaced).
4. **The components to the sheet:** buttons, fields, badges, notices, menus, the session row, the question card and the prompt bar drawn as the contact sheet shows, on the three clients.

The docs site and www take the colours and the face from story 1's and story 2's generated CSS.
