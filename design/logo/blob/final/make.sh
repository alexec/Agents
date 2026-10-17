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
# face SMILE: the Blob placed in the 1024 tile, the smile's stroke as given
face() {
  echo "<g transform=\"translate(512 516) scale(.9)\"><path d=\"$BLOB\" fill=\"none\" stroke=\"#3A78E6\" stroke-width=\"56\" stroke-linejoin=\"round\"/><path d=\"$BLOB\" fill=\"#fff\"/><g fill=\"#0E1A3A\">$EYES</g><path d=\"M-64 80 Q0 150 64 80\" fill=\"none\" stroke=\"#0E1A3A\" stroke-width=\"$1\" stroke-linecap=\"round\"/></g>"
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
echo "$SVG$BODY<defs><filter id=\"s\" x=\"-10%\" y=\"-10%\" width=\"120%\" height=\"130%\"><feDropShadow dx=\"0\" dy=\"10\" stdDeviation=\"12\" flood-color=\"#000\" flood-opacity=\".28\"/></filter></defs><g transform=\"translate(100 100) scale(.8046875)\"><rect width=\"1024\" height=\"1024\" rx=\"230\" fill=\"url(#g)\" filter=\"url(#s)\"/>$FACE</g></svg>" > mac.svg
echo "$SVG$BODY<defs><filter id=\"s\" x=\"-10%\" y=\"-10%\" width=\"120%\" height=\"130%\"><feDropShadow dx=\"0\" dy=\"10\" stdDeviation=\"12\" flood-color=\"#000\" flood-opacity=\".28\"/></filter></defs><g transform=\"translate(100 100) scale(.8046875)\"><rect width=\"1024\" height=\"1024\" rx=\"230\" fill=\"url(#g)\" filter=\"url(#s)\"/>$SMALL</g></svg>" > mac-small.svg

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
echo done
