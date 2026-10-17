#!/bin/sh
# Draw the happy Blob (#1237: the front Blob of the Huddle, `Blob` in Shared/UI/Huddle.swift, with its
# outline, eyes and smile, white on the cobalt tile) and write it into every place the app shows it.
# Run from this folder: ./make.sh
set -e
ROOT=$(cd ../../../.. && pwd)
BODY='<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5B9BFF"/><stop offset="1" stop-color="#1A52C0"/></linearGradient></defs>'
# The Blob in its own units of 600 by 580, centred on 0 0, as Huddle.swift and Huddle.tsx draw it
BLOB='M0 -290 C188 -290 300 -186 300 4 C300 196 188 290 0 290 C-188 290 -300 196 -300 4 C-300 -186 -188 -290 0 -290 Z'
EYES='<ellipse cx="-92" cy="-30" rx="46" ry="62"/><ellipse cx="92" cy="-30" rx="46" ry="62"/>'
INK='fill="none" stroke="#0E1A3A" stroke-linecap="round" stroke-linejoin="round"'
# The icon's moods (#1317), drawn on the Dock tile and the web favicon while the app runs:
# asleep (nothing runs, nothing asks) has its eyes shut and a "z" in the tile's corner;
# quizzical (a question waits) leans its head, raises one brow and has a "?" in the corner.
# The marks in the corner are white and heavy, to hold at a favicon's 16 px.
ASLEEP_FACE="<path d=\"M-140 -22 Q-92 22 -44 -22 M44 -22 Q92 22 140 -22\" $INK stroke-width=\"30\"/><path d=\"M-40 100 Q0 122 40 100\" $INK stroke-width=\"26\"/>"
ASLEEP_MARK='<path d="M770 92 H900 L770 222 H900" fill="none" stroke="#fff" stroke-width="44" stroke-linecap="round" stroke-linejoin="round"/>'
QUIZZICAL_FACE="<g fill=\"#0E1A3A\"><ellipse cx=\"-92\" cy=\"-24\" rx=\"42\" ry=\"52\"/><ellipse cx=\"92\" cy=\"-34\" rx=\"46\" ry=\"66\"/></g><path d=\"M-140 -110 L-46 -100 M44 -150 Q92 -196 140 -150\" $INK stroke-width=\"28\"/><path d=\"M-60 104 Q-24 82 4 100 Q32 118 62 92\" $INK stroke-width=\"28\"/>"
QUIZZICAL_MARK='<path d="M778 126 Q778 64 838 64 Q898 64 898 120 Q898 160 842 182 L842 214" fill="none" stroke="#fff" stroke-width="44" stroke-linecap="round" stroke-linejoin="round"/><circle cx="842" cy="276" r="28" fill="#fff"/>'
# face SMILE [MOOD]: the Blob placed in the 1024 tile, the smile's stroke as given; happy
# unless a mood is named
face() {
  case "$2" in
  asleep) INSIDE=$ASLEEP_FACE; MARK=$ASLEEP_MARK; TILT= ;;
  quizzical) INSIDE=$QUIZZICAL_FACE; MARK=$QUIZZICAL_MARK; TILT=' rotate(-7)' ;;
  *) INSIDE="<g fill=\"#0E1A3A\">$EYES</g><path d=\"M-64 80 Q0 150 64 80\" $INK stroke-width=\"$1\"/>"; MARK=; TILT= ;;
  esac
  echo "<g transform=\"translate(512 516) scale(.9)$TILT\"><path d=\"$BLOB\" fill=\"none\" stroke=\"#3A78E6\" stroke-width=\"56\" stroke-linejoin=\"round\"/><path d=\"$BLOB\" fill=\"#fff\"/>$INSIDE</g>$MARK"
}
FACE=$(face 28)
# At 32 px and under the smile's thin stroke is lost, so those sizes draw it heavier
SMALL=$(face 64)
SVG='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'

# tile: the rounded square on its own (favicons, the docs logo)
echo "$SVG$BODY<rect width=\"1024\" height=\"1024\" rx=\"230\" fill=\"url(#g)\"/>$FACE</svg>" > tile.svg
# ios: full bleed, square; iOS rounds the corners itself
echo "$SVG$BODY<rect width=\"1024\" height=\"1024\" fill=\"url(#g)\"/>$FACE</svg>" > ios.svg
# mac: the macOS grid, an 824 tile in 1024 with a soft shadow beneath
mac() { # face out
  echo "$SVG$BODY<defs><filter id=\"s\" x=\"-10%\" y=\"-10%\" width=\"120%\" height=\"130%\"><feDropShadow dx=\"0\" dy=\"10\" stdDeviation=\"12\" flood-color=\"#000\" flood-opacity=\".28\"/></filter></defs><g transform=\"translate(100 100) scale(.8046875)\"><rect width=\"1024\" height=\"1024\" rx=\"230\" fill=\"url(#g)\" filter=\"url(#s)\"/>$1</g></svg>" > "$2"
}
mac "$FACE" mac.svg
mac "$SMALL" mac-small.svg
# the moods (#1317): the Dock tile is drawn at 128 pt and more, so the full stroke does
for MOOD in asleep quizzical; do
  mac "$(face 28 $MOOD)" mac-$MOOD.svg
  echo "$SVG$BODY<rect width=\"1024\" height=\"1024\" rx=\"230\" fill=\"url(#g)\"/>$(face 28 $MOOD)</svg>" > tile-$MOOD.svg
done

# Agents Host's menu bar mark: a template of outline, eyes and smile in one colour, so it
# follows a light or dark menu bar; the eyes and smile cut through, the outline and smile
# heavier to hold at 18 pt
echo "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"-340 -330 680 660\" width=\"19\" height=\"18\"><path d=\"$BLOB\" fill=\"none\" stroke=\"#000\" stroke-width=\"72\" stroke-linejoin=\"round\"/><g fill=\"#000\">$EYES</g><path d=\"M-72 80 Q0 160 72 80\" fill=\"none\" stroke=\"#000\" stroke-width=\"56\" stroke-linecap=\"round\"/></svg>" > "$ROOT/Host/Resources/Assets.xcassets/MenuBarBlob.imageset/menu-bar.svg"

# Quick Look fills transparency white, so render with AppKit instead
swiftc -O -o /tmp/blob-render render.swift
render() { # svg size out
  /tmp/blob-render "$1" "$2" "$3"
}

# the Mac app and Agents Host, which has the same icon (#1237)
for MAC in "$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset" "$ROOT/Host/Resources/Assets.xcassets/AppIcon.appiconset"; do
for s in 16 32 128 256 512; do
  one=mac.svg; [ $s -le 32 ] && one=mac-small.svg
  two=mac.svg; [ $s -le 16 ] && two=mac-small.svg
  render $one $s "$MAC/icon_${s}x${s}.png"
  render $two $((s*2)) "$MAC/icon_${s}x${s}@2x.png"
done
done

# iOS wants no alpha: through JPEG and back drops it
render ios.svg 1024 /tmp/blob-ios.png
sips -s format jpeg -s formatOptions best /tmp/blob-ios.png --out /tmp/blob-ios.jpg >/dev/null
sips -s format png /tmp/blob-ios.jpg --out "$ROOT/Remote/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" >/dev/null

render tile.svg 256 "$ROOT/docs/assets/logo.png"
render tile.svg 64 "$ROOT/docs/assets/favicon.png"
render tile.svg 64 "$ROOT/Web/assets/favicon.png"
# the web page installed as an app (#791): the tile for Chrome, full bleed for a maskable
# icon and for iOS's home screen, which rounds it itself
render tile.svg 192 "$ROOT/Web/assets/icon-192.png"
render tile.svg 512 "$ROOT/Web/assets/icon-512.png"
render ios.svg 512 "$ROOT/Web/assets/icon-maskable-512.png"
render ios.svg 180 "$ROOT/Web/assets/apple-touch-icon.png"
render tile.svg 1024 tile-1024.png

# the moods (#1317): the Dock tile's images, which the app sets while it runs (the happy
# Blob is the bundle's own icon), and the favicons the web page swaps between
DOCK="$ROOT/App/Resources/Assets.xcassets"
for MOOD in asleep quizzical; do
  NAME=Dock$(echo $MOOD | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
  mkdir -p "$DOCK/$NAME.imageset"
  render mac-$MOOD.svg 1024 "$DOCK/$NAME.imageset/dock.png"
  printf '{\n  "images" : [\n    { "filename" : "dock.png", "idiom" : "universal", "scale" : "2x" }\n  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > "$DOCK/$NAME.imageset/Contents.json"
  render tile-$MOOD.svg 64 "$ROOT/Web/assets/favicon-$MOOD.png"
  render tile-$MOOD.svg 1024 tile-$MOOD-1024.png
done
echo "done"
