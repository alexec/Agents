# #192: the Needs you widget at large and extra large

The PNGs here are every size of the Remote's Needs you widget, in each state, drawn by
`render/render.sh` with `ImageRenderer` on the Mac. They use the widget's real view files and
the phone's type sizes (`render/TypeScaleShim.swift`). No simulator is involved.

- `<size>-<n>.png`: the widget with *n* sessions waiting (0, 1, 5, 15).
- `<size>-unknown.png`, `<size>-stale.png`: the app has written nothing yet, or wrote 40 minutes ago.
- `<size>-15-dark.png`, `<size>-15-larger-text.png`: dark mode, and text at about 1.4 times the default size.

What these are not: the real Home screen. WidgetKit's margins, its own Dynamic Type sizes and
the taps on each row are checked on Alex's iPhone and iPad. The renderer draws a `Link` as just
its label (`render/TypeScaleShim.swift`), so taps cannot be checked from these images.

The medium images overflow at the top and bottom. Medium's layout dates from 068 and #192
leaves it unchanged, so whether the phone shows the same overflow is for the device check.
