# Design system (#4600)

One design system for everything a person sees from Agents: the Mac window, the Remote, the web
page, the docs site, www and the forge connector pages. The epic, #4600, holds the decisions and
the plan; this file holds what its slices write down.

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
| `Go/internal/agentsd/templates/iphone-app/…/AppIcon.png` | PNG | 1024 | template (#3707) | a starter app's placeholder, out of scope |

No `.icns` is in the repo; `actool` builds it from the icon set.
