# Paper, version 2: the design system (#4926)

**Status:** spike, 2026-11-12. Epic #4925. No product code: this spec, a contact sheet and the stories.
**Clients:** none in the spike. The build is Core: the Mac window, the Remote and the web page.

## What Alex asked for

The app must be very comfortable to use and nice to look at. Paper (#326, #4600, `design/tokens.json`) is close, but it has not enough charcoal.

Alex's words on the earlier rounds (2026-11-12):

1. On the handwriting mock: the goal is **a clean, modern character, a look of our own that separates us from the competition, simple, very easy on the eye and very easy to read.** No handwriting.
2. On the font mocks: show **a high-fidelity mock**.
3. On the high-fidelity shots of the product: **get the font, the colour and the iconography right together.** Show **a contact sheet of the design system**: every component, the colours and how they are used, the icons and what they mean, the common components. **Borders and shading must be right, and very subtle.**
4. On the first contact sheet: **a bit more high-contrast; too much shading; gradients are fine.**
5. On the second: **rather than dark backgrounds, use lighter backgrounds and gradients.**
6. On the third: **only use the gradient on paper (greyscale) backgrounds. It is used as a way to avoid low contrast.**
7. On the fourth: **only use a gradient on what were large grey backgrounds. Never on coloured backgrounds, nor on small areas like buttons or notices.**

## The contact sheet

`contact-sheet.html` is the design system on one page, light and dark (`?mode=dark`). `contact-sheet.py` writes it, with Lucide's SVGs inlined (`python3 contact-sheet.py <lucide-static icons dir>`). The pictures are in the PR (`pr-<n>/sheet-light.png`, `sheet-dark.png`). It has five parts:

- **Colour:** every token, light and dark, what it is for, and its contrast on the ground.
- **Type:** the scale, the letters that are easy to confuse, and the four faces we compared.
- **Edges and depth:** the four levels, the lines and the radii.
- **Icons:** each icon with its name and what it means: states, things, actions, notices.
- **Components:** buttons, fields, toggles, a segmented control, labels and state badges, notices, a menu, a tooltip, a toast, progress, the session list (selected, hover, waiting, unread, failed), the chat (your message, a tool row, code, a question card), the prompt bar, a sheet and an empty state.

## Principles

1. **Clear and crisp.** High contrast: deep charcoal ink (17:1) on near-white paper. Every text colour is 4.5:1 or more on every surface, the selection included.
2. **Few colours, each with one job.** Colour means something: a link, a state or a label. It is never decoration.
3. **Lines, not shading.** A line (1.5:1) sets things apart. Nothing on the page casts a shadow and there are few grey fills. Only what floats over the page (a menu, a toast, a sheet) has a short shadow. A control's edge is 3:1 or more (WCAG 1.4.11).
4. **One gradient, on the large grey only.** The sidebar column, the one large grey background, goes from paper to a slightly deeper grey, top to bottom. Nothing else has a gradient: not a coloured background, and not a small thing such as a button, a chip, a badge, a notice or a card. Those are flat paper with a line. Colour never fills. It is only in text, icons, lines (a state's edge, the selection's bar) and a switch that is on.
5. **One face, one icon set, on all three clients.** Today the Mac and the Remote draw SF Symbols, and the web page draws Unicode glyphs (`✎ ▤ ◉ ▦ ✓`). One set makes the three clients look like one product.

## Token changes (`design/tokens.json`)

### Colour

| Token | Today light / dark | v2 light | v2 dark | Used for |
|---|---|---|---|---|
| `color.ground` | `#f7f8f9` / `#1c1d20` | `#fcfbf9` | `#1a1a19` | the page |
| `color.sidebar` | `#f0f1f3` / `#161719` | `#f5f4f0` | `#141413` | the folders column |
| `color.raised` | `#ffffff` / `#26282c` | `#ffffff` | `#212120` | cards, the prompt bar, menus, sheets |
| `color.well` | `#f0f2f4` / `#2a2d31` | `#f3f2ee` | `#262625` | code, your own message, a filled field |
| `color.wash` | `#e7eaee` / `#33363b` | `#eeece7` | `#2e2e2c` | hover; a pressed quiet button |
| `color.selection` | `#d8dee6` / `#3a3e44` | `#e6e3dc` | `#363633` | the picked row, with a 3px accent bar |
| `color.ink` | `#1c1d20` / `#e8eaed` | `#1a1918` | `#f4f2ed` | text, icons |
| `color.secondary` (new) | system `.secondary` | `#4a4741` | `#bdb9b0` | second lines, speakers, section headings |
| `color.tertiary` (new) | system `.tertiary` | `#625e57` | `#a29e95` | timestamps, counts, placeholders |
| `color.rule` | `#dde1e6` / `#3a3e44` | `#d6d2c9` | `#3d3d3a` | the line that sets things apart, 1.5:1 |
| `color.edge` (new) | none | `#7d786e` | `#85817a` | a field's, checkbox's or toggle's edge, 3:1 or more |
| `color.accent` | `#1f5fc8` / `#7fb0ff` | `#1a52c0` | `#86b4ff` | links, focus, the chosen control |
| `color.tint.attention` | `#ba4a13` / `#f0a06b` | `#a3400e` | `#f3a672` | needs you |
| `color.tint.failure` | `#b4232b` / `#f08086` | `#b0222a` | `#f4878d` | failed |
| `color.tint.vouched` | `#2d765c` / `#8bc6a7` | `#25684f` | `#92ccad` | done, approved |
| `color.label.issue` | `#0e6b82` / `#6cc6db` | `#0c6278` | `#73cbe0` | #812 |
| `color.label.pull` | `#7442b8` / `#b79af0` | `#6c3cae` | `#bea3f2` | P#44 |

The code inks and the forge colours keep their values.

### Gradient (new: `gradient.sidebar`): the large grey only

| Token | Light | Dark | Used for |
|---|---|---|---|
| `gradient.sidebar` | `#f7f6f3` → `#ecebe6`, top to bottom | `#181817` → `#111110` | the sidebar column (`color.sidebar` stays as its flat value where a gradient cannot be drawn) |

There are no other gradients. Buttons, chips, badges, notices, cards and a picked choice are flat `raised` with a `rule` or `edge` line. A state shows its colour in its text, its icon and a line: `line.accent` `#a9c2ee` / `#3d5687`, `line.attention` `#ebbf9f` / `#6b4a33`, `line.vouched` `#a9d3bb` / `#36614d` and `line.failure` `#eeb0b3` / `#6b3a3d`. A notice also has a 3px bar. A switch or checkbox that is on is a flat `accent`. Every text colour is 5.3:1 or more on the deeper end of the sidebar gradient. SwiftUI draws it as a `LinearGradient`.

### Depth (new: `shadow.*`, replacing the one `color.shadow`)

| Token | Light | Dark | Used for |
|---|---|---|---|
| `shadow.floating` | `0 4px 12px` ink at 10% | black at 40% | menus, the prompt bar, toasts (with a `rule` line) |
| `shadow.sheet` | `0 12px 32px` ink at 18% | black at 55% | sheets and dialogs, over a dimmed page |
| `focus` | a 2px accent ring with a 2px gap | the same | keyboard focus |

Cards, buttons and rows have no shadow, only a `rule` line.

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

The contact sheet prints each colour's ratio on the ground, light and dark.

- **Text:** every text colour is 4.5:1 or more on every surface: ground, sidebar, raised, well, wash and selection.
- **Ink:** 17:1 in the light and 15.6:1 in the dark.
- **Control edges:** 3:1 or more on every surface where a control is drawn.
- **The sidebar gradient:** every text colour is 5.3:1 or more on its deeper end.

The first story adds these pairs to `DesignTokensTests`.

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
- Decided: higher contrast (ink 17:1), lines (1.5:1) in place of shadows on the page, few grey fills, short shadows only on what floats, and one gradient, on the sidebar (the one large grey), with colour only in text, icons, lines and a switch that is on, because Alex asked for more contrast, less shading, light backgrounds, and a gradient only on large grey backgrounds (2026-11-12). Alex can overrule.
- Decided: one icon set, Lucide at a 1.5 stroke, on all three clients, because the clients draw different icons today and Lucide is the one set that meets the library rule. Alex can overrule.
- Decided: the colour, gradient, depth, radius and spacing tokens above, because each passes WCAG AA and follows the principles. Alex can overrule.
- Decided: no setting to turn the face off, because one clear look is simpler. Alex can overrule.
- **Alex's choice (pending):** the contact sheet as a whole, including the face (Atkinson Hyperlegible Next is proposed).

## Stories (Core: Mac, Remote, web)

These are filed as sub-issues of #4925 after Alex approves the sheet. Each is blocked by #4926. Story 1 goes first; stories 2, 3 and 4 follow it and can run at the same time.

1. **Paper v2 tokens:** colour, the sidebar gradient, depth, radius and reading spacing (`design/tokens.json`, `Paper.swift`, `StateTint.swift`, `paper.css`, contrast pairs in `DesignTokensTests`).
2. **The face:** Atkinson Hyperlegible Next and Mono on the three clients (`design/fonts/`, `TypeScale.swift`, `Web/assets/fonts`, acknowledgements).
3. **One icon set:** Lucide on the three clients (`design/icons.json`, `scripts/design.sh icons`, an asset catalogue, the web's glyphs replaced).
4. **The components to the sheet:** buttons, fields, badges, notices, menus, the session row, the question card and the prompt bar drawn as the contact sheet shows, on the three clients.

The docs site and www take the colours and the face from story 1's and story 2's generated CSS.
