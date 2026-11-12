# Paper, version 2: more charcoal and a face of our own, easy to read (#4926)

**Status:** spike, 2026-11-12. Epic #4925. No product code: this spec, a mock (`mock.html`) and the stories.
**Clients:** none in the spike. The build is Core: the Mac window, the Remote and the web page.

## What Alex asked for

The app must be very comfortable to use and nice to look at. Paper (#326, #4600, `design/tokens.json`) is close, but it has not enough charcoal.

Alex, 2026-11-12, on the first mock (handwriting): the goal is not handwriting. It is **a clean, modern character: a look of our own that separates us from the competition, that is simple, very easy on the eye and very easy to read.** So this version has no handwritten face and no sketched edges.

## The answer in short

1. **Charcoal:** a warm paper ground (not pure white), charcoal ink (not pure black), darker hairlines, deeper charcoal shadows, and a charcoal dark mode (warm greys, not blue-black).
2. **One face of our own for all text:** most tools in this space draw in Inter, Geist or the system font, so a different, clear face is the quickest way to a look of our own. The mock compares three, all made for reading.
3. **Reading text gets the dyslexia guides' spacing:** line height 1.5, a little letter and word spacing, and lines of at most about 70 characters.

## Mock

**High fidelity (the pictures in the PR, `pr-<n>/web-*.png`):** the real web page, built from this branch, on a run-app scratch set-up (a scratch control plane and host, a demo repo `web-shop`, and three real Claude sessions). The new colours, the reading spacing and each face were put on the running page as a constructed stylesheet, with the fonts served from the page's own origin. Nothing in `Web/src` changed. One scratch-only card (a machine waiting to join) was hidden. Each look is shown in light and dark at 1280 × 800.

**Low fidelity:** `mock.html` draws a simple session list and chat, light and dark side by side (`?v=v1|A|B|C`).

| Variant | Text | Code |
|---|---|---|
| **today** | system sans (SF) | system mono |
| **A** | Atkinson Hyperlegible Next | Atkinson Hyperlegible Mono |
| **B** | Lexend | system mono |
| **C** | Figtree | system mono |

A, B and C have the v2 colours; only the face differs.

## Fonts

All are SIL OFL 1.1, maintained, on Google Fonts and Fontsource, and work in SwiftUI (`Font.custom(_:size:relativeTo:)`, which follows Dynamic Type) and on the web (`@font-face`, self-hosted). Sizes are the variable Latin woff2.

| Font | Made by | Character | Easy to read | Size | Verdict |
|---|---|---|---|---|---|
| **Atkinson Hyperlegible Next** + **Mono** | Braille Institute, Applied Design (2025) | clean grotesque with letters drawn to differ: a `b` and `d` that are not mirrors, a tailed `l`, a slashed `0`, open `a` and `e`; a mono of the same family for code | made for low vision; letters hard to confuse, which also helps dyslexia | 34 KB + 18 KB | **Recommended:** the only one with a matching mono, so text and code look like one product; rare among competitors |
| Lexend | Bonnie Shaver-Troup, Thomas Jockin (Google, 2019–2023) | wide, round, friendly geometric | made for reading fluency; wide spacing helps some readers | 40 KB | Good; wider, so less fits in the sidebar and list |
| Figtree | Erik Kennedy (2022) | clean, modern geometric, a little warm | clear, but `I` and `l` look alike | 20 KB | Clean, but close to Inter: less of a look of our own |
| OpenDyslexic | Abbie Gonzalez | heavy bottoms | studies found no reading gain (Wery and Diliberto 2017; Kuster et al. 2018) | 120 KB | Not shown: neither clean nor modern |

**How it ships.** `design/fonts/` holds the chosen family's variable fonts and `OFL.txt`; `font.text` and `font.mono` in `design/tokens.json` name it first, with the system faces after it. The Mac and the Remote register it at launch with `CTFontManagerRegisterFontsForURL` from `Shared/UI`'s bundle; the web page serves its woff2 from `Web/assets/fonts/` (FR-034: nothing from another origin). The About screen's acknowledgements name it with its licence. Scripts it has no letters for (CJK, Arabic) fall back to the system face.

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
| `color.secondary` | `#5a5750` | `#aaa69d` | a row's second line and the speaker's name, in place of the system's `.secondary`, so it matches the warm ground; Swift `Paper.secondary` |
| `type.leading.reading` | `1.5` | | the line height of `reading` text (chat, prose) |
| `type.tracking.reading` | `0.01em` | | letter spacing of `reading` text; word spacing `0.06em` beside it |

Changed fonts: `font.text` becomes `["Atkinson Hyperlegible Next", "-apple-system", "BlinkMacSystemFont", "system-ui", "sans-serif"]` and `font.mono` becomes `["Atkinson Hyperlegible Mono", "ui-monospace", "SF Mono", "Menlo", "monospace"]` (or the face Alex picks; Lexend and Figtree keep the system mono). `TypeScale.swift`'s steps keep their sizes and text styles. The accent, the code inks, the forge colours and the timeline do not change (each still passes on the new grounds; see below).

## Contrast (WCAG 2.2 AA)

Text needs 4.5:1. Every text colour on every ground it is drawn on:

**Light**

| Text | ground | sidebar | raised | well | wash |
|---|---|---|---|---|---|
| ink `#252422` | 14.2 | 13.1 | 15.1 | 13.0 | 12.0 |
| secondary `#5a5750` | 6.6 | 6.1 | 7.0 | 6.0 | 5.6 |
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
| accent `#7fb0ff` | 7.2 | 7.8 | 6.3 | 6.5 | 5.4 |
| attention `#f0a06b` | 7.5 | 8.1 | 6.5 | 6.8 | 5.7 |
| failure `#f08086` | 6.1 | 6.6 | 5.4 | 5.6 | 4.6 |
| vouched `#8bc6a7` | 8.0 | 8.7 | 7.1 | 7.4 | 6.1 |
| issue `#6cc6db` | 8.1 | 8.7 | 7.1 | 7.4 | 6.1 |
| pull `#b79af0` | 6.7 | 7.2 | 5.8 | 6.1 | 5.1 |

All pass. On `selection` some tints are under 4.5:1, as today: nothing is drawn in a tint on a selection (the token's own rule). The build's first story adds these pairs to `DesignTokensTests` so a later change cannot drop under 4.5:1.

## Reading and dyslexia

From the British Dyslexia Association's style guide and the WCAG 1.4.12 text-spacing rule:

- **No pure white, no pure black:** the paper ground and charcoal ink above.
- **Line height 1.5** for reading text (chat, prose, cards). The web page's chat has it (`.reply`); the Mac and the Remote get the same.
- **Letter spacing about 0.01em, word spacing a little more** for reading text. WCAG 1.4.12 asks that a person's own larger spacing does not break the layout: the web page must not clip at 0.12em letter and 0.16em word spacing.
- **Line length at most about 70 characters** in the chat column (it is wider on a big window today).
- **No italics or capitals for emphasis** in the app's own words; bold instead.
- **Size:** `reading` stays at the platform's body size (15 pt on the Mac, 17 pt on iOS, 1rem on the web) and follows the person's text size.

## Decisions

- Decided: no handwriting and no sketched edges, because Alex wants a clean, simple look (2026-11-12).
- Decided: one face for all text (and its mono for code where the family has one), not a display face for titles beside a second body face, because one face is simpler and easier on the eye. Alex can overrule.
- Decided: the token values above, because each one passes WCAG AA and follows the dyslexia guides' paper and charcoal. Alex can overrule.
- Decided: reading spacing of 1.5 line height, 0.01em letter spacing and a 70-character line, because the dyslexia guides ask for it and it costs no look. Alex can overrule.
- Decided: no setting to turn the face off, because a clear face is easy for everyone to read and one look is simpler. A setting can follow if a person asks. Alex can overrule.
- **Alex's choice (pending):** the face: A (Atkinson Hyperlegible Next + Mono), B (Lexend), C (Figtree) or keep the system font. Claude recommends **A**.

## Stories (Core: Mac, Remote, web)

Filed as sub-issues of #4925, each blocked by #4926. Story 1 first; story 2 after it or at the same time.

1. **Paper v2 colours and reading spacing** (`design/tokens.json`, `Paper.swift`, `StateTint.swift`, `paper.css`; contrast pairs in `DesignTokensTests`).
2. **The chosen face for all text and code** (`design/fonts/`, `font.text` and `font.mono`, `TypeScale.swift`, `Web/assets/fonts`, acknowledgements).

The docs site and www get the colours from story 1's generated CSS, and the face from story 2's `font.text`, when they load it.
