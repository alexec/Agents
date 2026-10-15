# Logo ideas

Six marks for an app whose subject is a group of agents. Drawn as SVG so any of them can
be taken further; `contact-sheet.png` shows all six together, and at 32 and 16 points,
which is where most icons fall apart.

| | Idea | What it says | Holds up small? |
|---|---|---|---|
| 1 | **Formation** | Three of them moving as one, with a leader. | Yes. Three dots survive anything |
| 2 | **Queue** | Work in hand, work waiting, one not started. | No. Turns into a smudge |
| 3 | **Constellation** | You in the middle, the agents around you. | Just. The lines go first |
| 4 | **Faces** | Four of them, looking back at you. | No. The eyes vanish and it is four grey squares |
| 5 | **Bubbles** | Every agent is a conversation. | No. Reads as one bubble, so the group is lost |
| 6 | **Status grid** | The app's own vocabulary: filled is working, ringed is waiting, hollow is done. | Yes, as "many", though the states blur |

The dark ground and the absence of colour are deliberate: the app uses colour for one
thing only, which is something going wrong, and an icon that shouts undoes that.

## Now: Blob

Since 2026-10-03 the icon is **Blob** from `colour/` (violet, oval eyes, the soft outline),
chosen from the variations in `blob/`. `blob/final/make.sh` draws it and writes the Mac
and iPhone icons, the docs logo and favicon, and the web page's favicon; `Web/dist` is rebuilt by the next
Agents Host build, or `scripts/web.sh build`.

## Three happy Blobs (#1007)

`three-blobs/` holds eight ways to draw three Blobs together, each at 240, 64, 32 and 16
points on `sheet.png` (`python3 make.py`, then `swift render.swift sheet.svg sheet.png`).
On 2026-10-14 Alex chose **B Huddle**, one white Blob in front and two light-blue ones
behind, as a mark for the places that show a team. The app icon stays one Blob.

The Huddle is drawn in code, not from these files: `Shared/UI/Huddle.swift` for the window
and the Remote, `Web/src/views/Huddle.tsx` for the web page. It shows over a new session
and a new chat (#987) and on the first-run page of all three (#1007), without a tile and
with the two Blobs at the back light blue, on paper and on the dark theme alike. The
README, the docs, the favicon and About keep the one Blob.
