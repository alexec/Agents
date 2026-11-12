# Paper, version 2: more charcoal, a handwritten feel, friendly to dyslexia (#4926)

**Status:** spike, 2026-11-12. Epic #4925. No product code: this spec, a mock (`mock.html`) and the stories.
**Clients:** none in the spike. The build is Core: the Mac window, the Remote and the web page.

## What Alex asked for

The app must be very comfortable to use and nice to look at. Paper (#326, #4600, `design/tokens.json`) is close, but it has not enough charcoal and no handwriting. Most handwriting fonts are hard to read for people with dyslexia, so the handwriting must not make reading harder.

## The answer in short

1. **Charcoal:** a warm paper ground (not pure white), charcoal ink (not pure black), darker hairlines, a new charcoal `stroke` for sketched edges, deeper charcoal shadows, and a charcoal dark mode (warm greys, not blue-black).
2. **Handwriting only where text is short:** page titles, section headings, question titles, empty states. Body text, chat, code, lists' second lines and all controls stay in the system sans-serif.
3. **The handwritten face is Shantell Sans** at a fixed, calm setting (Informality 0.5, Bounce 0, weight 600). Its letters are open and different from each other, so it stays readable.
4. **Reading text gets the dyslexia guides' spacing:** line height 1.5, a little letter and word spacing, and lines of at most about 70 characters.

## Mock

`mock.html` draws the session list and the chat, light and charcoal dark side by side (`?v=v1|A|B|C`). The pictures are in the PR (`pr-shots.sh`, branch `screenshots`, `pr-<n>/mock-*.png`).

| Variant | Handwriting | Sketched edges |
|---|---|---|
| **today** (`v1`) | none | none |
| **A** | the page title, the sidebar title, section headings | none |
| **B** | A, and the title of a question card | the question card and the prompt bar get a charcoal edge that looks drawn by hand |
| **C** | B, and every session's name in the list, and the speaker's name in the chat | as B |

Every variant has the v2 colours. Body text is the same in all four.

## Fonts

| Font | For | Licence | Last release | Size (Latin woff2) | SwiftUI | Web | Verdict |
|---|---|---|---|---|---|---|---|
| **Shantell Sans** (Arrow Type, Shantell Martin) | the handwritten face | SIL OFL 1.1 | v1.011, Fontsource 5.2.7 (2025) | 146 KB (Informality axis), 79 KB (weight only) | `Font.custom(_:size:relativeTo:)` on a static instance | `@font-face`, self-hosted | **Chosen** |
| Atkinson Hyperlegible Next (Braille Institute) | a body face, if we want one | SIL OFL 1.1 | 2025-02 | ~60 KB per weight | yes | yes | Not now: the system sans is as clear, follows Dynamic Type and every script, and costs nothing to load. It is the first choice if Alex wants a body face of our own. |
| Lexend | a body face | SIL OFL 1.1 | 2023 | ~70 KB | yes | yes | Not chosen: its wide spacing helps some readers, but the same spacing on the system sans gives most of it. |
| OpenDyslexic | a body face for dyslexia | SIL OFL 1.1 | 2023 | ~120 KB | yes | yes | Not chosen: studies found no reading gain (Wery and Diliberto 2017; Kuster et al. 2018), and people find its heavy bottoms tiring. |
| Patrick Hand, Kalam, Caveat, Architects Daughter | the handwritten face | SIL OFL 1.1 | various | 30–90 KB | yes | yes | Not chosen: single letter shapes (Caveat's joined letters, Kalam's tilt, Architects Daughter's all-caps feel) are harder to tell apart; none has Shantell's axes to calm the hand down. |

**Why Shantell Sans.** It was drawn from an artist's hand and then made for reading: open counters, a `b` and a `d` that are not mirror shapes, an `I`, `l` and `1` that differ, and an optional slashed zero. Its Informality axis goes from a structured sans to a loose hand; at 0.5 the text looks drawn but every letter keeps its shape. Bounce 0 keeps the baseline straight, which matters for dyslexia (an uneven baseline makes the eye lose its line). It is maintained, OFL, and on Fontsource and Google Fonts.

**How it ships.** One static instance (Informality 0.5, Bounce 0, weight 600), made from the variable font with fontTools' `varLib.instancer` by `scripts/design.sh fonts`, so `design/fonts/` holds the source font, its `OFL.txt` and the instance, and nothing is edited by hand. The Mac and the Remote register it at launch with `CTFontManagerRegisterFontsForURL` from `Shared/UI`'s bundle; the web page serves its woff2 from `Web/assets/fonts/` (FR-034: nothing from another origin). The About screen's acknowledgements name it with its licence.

## Token changes (`design/tokens.json`)

Changed values (light / dark). The old values are in `#4600`'s table.

| Token | Today | v2 light | v2 dark | Why |
|---|---|---|---|---|
| `color.ground` | `#f7f8f9` / `#1c1d20` | `#f6f5f1` | `#232321` | warm paper, not white; charcoal, not blue-black |
| `color.sidebar` | `#f0f1f3` / `#161719` | `#eeece6` | `#1c1c1b` | |
| `color.raised` | `#ffffff` / `#26282c` | `#fdfcf9` | `#2d2d2a` | no pure white anywhere (BDA) |
| `color.well` | `#f0f2f4` / `#2a2d31` | `#ecebe5` | `#2a2a28` | |
| `color.wash` | `#e7eaee` / `#33363b` | `#e4e2db` | `#373734` | |
| `color.rule` | `#dde1e6` / `#3a3e44` | `#cfcbc2` | `#4b4a46` | darker hairlines: more charcoal |
| `color.ink` | `#1c1d20` / `#e8eaed` | `#252422` | `#ece9e2` | charcoal ink, a little softer than today (14.2:1, was 15.9:1) |
| `color.selection` | `#d8dee6` / `#3a3e44` | `#dcd8cf` | `#46443f` | |
| `color.shadow` | `#20242a` α 0.10 / `#000` | `#2b2a27` α 0.16 | `#000000` α 0.35 | a charcoal shadow you can see |
| `color.tint.attention` | `#ba4a13` | `#a8420f` | `#f0a06b` | 4.5:1 on the darker well and wash |
| `color.tint.vouched` | `#2d765c` | `#2a7157` | `#8bc6a7` | the same |

New tokens:

| Token | Light | Dark | For |
|---|---|---|---|
| `color.stroke` | `#3a3935` | `#cfcbc2` | a sketched charcoal edge (question card, prompt bar, empty-state drawings); Swift `Paper.stroke` |
| `color.secondary` | `#5a5750` | `#aaa69d` | a row's second line and the speaker's name, in place of the system's `.secondary`, so it matches the warm ground; Swift `Paper.secondary` |
| `font.hand` | `["Shantell Sans", <font.text>]` | | titles and headings only; `$description` says where it may be used |
| `type.leading.reading` | `1.5` | | the line height of `reading` text (chat, prose) |
| `type.tracking.reading` | `0.01em` | | letter spacing of `reading` text; word spacing `0.06em` beside it |

The steps `title` and the section heading (`reading` with a weight) get `dev.agentloops.face: "hand"`; `reading`, `supporting`, `fine` and `code` keep the system faces. The accent, the code inks, the forge colours and the timeline do not change (each still passes on the new grounds; see below).

## Contrast (WCAG 2.2 AA)

Text needs 4.5:1. Every text colour on every ground it is drawn on:

**Light**

| Text | ground | sidebar | raised | well | wash |
|---|---|---|---|---|---|
| ink `#252422` | 14.2 | 13.1 | 15.1 | 13.0 | 12.0 |
| secondary `#5a5750` | 6.6 | 6.1 | 7.0 | 6.0 | 5.6 |
| stroke `#3a3935` | 10.6 | 9.8 | 11.3 | 9.7 | 8.9 |
| accent `#1f5fc8` | 5.5 | 5.0 | 5.8 | 5.0 | 4.6 |
| attention `#a8420f` | 5.6 | 5.2 | 5.9 | 5.1 | 4.7 |
| failure `#b4232b` | 6.0 | 5.5 | 6.4 | 5.5 | 5.0 |
| vouched `#2a7157` | 5.3 | 4.9 | 5.7 | 4.9 | 4.5 |
| issue `#0e6b82` | 5.6 | 5.2 | 5.9 | 5.1 | 4.7 |
| pull `#7442b8` | 6.0 | 5.5 | 6.4 | 5.5 | 5.0 |

**Dark**

| Text | ground | sidebar | raised | well | wash |
|---|---|---|---|---|---|
| ink `#ece9e2` | 13.0 | 14.1 | 11.4 | 11.9 | 9.8 |
| secondary `#aaa69d` | 6.5 | 7.0 | 5.7 | 5.9 | 4.9 |
| stroke `#cfcbc2` | 9.7 | 10.5 | 8.5 | 8.9 | 7.4 |
| accent `#7fb0ff` | 7.2 | 7.8 | 6.3 | 6.5 | 5.4 |
| attention `#f0a06b` | 7.5 | 8.1 | 6.5 | 6.8 | 5.7 |
| failure `#f08086` | 6.1 | 6.6 | 5.4 | 5.6 | 4.6 |
| vouched `#8bc6a7` | 8.0 | 8.7 | 7.1 | 7.4 | 6.1 |
| issue `#6cc6db` | 8.1 | 8.7 | 7.1 | 7.4 | 6.1 |
| pull `#b79af0` | 6.7 | 7.2 | 5.8 | 6.1 | 5.1 |

All pass. On `selection` some tints are under 4.5:1, as today: nothing is drawn in a tint on a selection (the token's own rule). The sketched `stroke` is 9.7:1 or more, far above the 3:1 that a control's edge needs. The build's first story adds these pairs to `DesignTokensTests` so a later change cannot drop under 4.5:1.

## Reading and dyslexia

From the British Dyslexia Association's style guide and the WCAG 1.4.12 text-spacing rule:

- **No pure white, no pure black:** the paper ground and charcoal ink above.
- **Line height 1.5** for reading text (chat, prose, cards). The web page's chat has it (`.reply`); the Mac and the Remote get the same.
- **Letter spacing about 0.01em, word spacing a little more** for reading text. WCAG 1.4.12 asks that a person's own larger spacing does not break the layout: the web page must not clip at 0.12em letter and 0.16em word spacing.
- **Line length at most about 70 characters** in the chat column (it is wider on a big window today).
- **No italics or capitals for emphasis** in the app's own words; bold instead. Handwriting is never all capitals and never under 14 pt.
- **Size:** `reading` stays at the platform's body size (15 pt on the Mac, 17 pt on iOS, 1rem on the web) and follows the person's text size.

## Decisions

- Decided: the handwritten face is Shantell Sans at Informality 0.5, Bounce 0, weight 600, because its letters stay distinct and its baseline straight, it is OFL and maintained, and it is small. Alex can overrule.
- Decided: body, chat and code stay in the system faces (no Atkinson Hyperlegible Next, Lexend or OpenDyslexic), because the system sans is as clear, follows Dynamic Type and every script, and costs nothing to load. Alex can overrule.
- Decided: the token values above, because each one passes WCAG AA and follows the dyslexia guides' paper and charcoal. Alex can overrule.
- Decided: reading spacing of 1.5 line height, 0.01em letter spacing and a 70-character line, because the dyslexia guides ask for it and it costs no look. Alex can overrule.
- **Alex's choice (pending):** how much handwriting: A, B or C (the mock). Claude recommends **B**.
- **Alex's choice (pending):** one look for all, or a setting to turn the handwriting off. Claude recommends a **Handwriting** toggle in Settings ▸ Appearance, on by default: dyslexia differs from person to person, and the toggle only swaps the face back to the system sans.

## Stories (Core: Mac, Remote, web)

Filed as sub-issues of #4925, each blocked by #4926. The order: 1 first; 2, 3 and 4 after it, at the same time.

1. **Paper v2 colours and reading spacing** (`design/tokens.json`, `Paper.swift`, `StateTint.swift`, `paper.css`; contrast pairs in `DesignTokensTests`).
2. **The handwritten face for titles and headings** (`design/fonts/`, `scripts/design.sh fonts`, `TypeScale.swift`, `Web/assets/fonts`, acknowledgements).
3. **Sketched charcoal edges** on the question card, the prompt bar and empty states (only for variant B or C).
4. **The Handwriting setting** in Settings ▸ Appearance (only if Alex wants a setting).

The docs site and www get the colours from story 1's generated CSS; the handwriting there is a later choice, not in this epic.
