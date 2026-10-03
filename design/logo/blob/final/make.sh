#!/bin/sh
# Draw the chosen Blob (violet, ovals, soft) and write it into every place the app shows it.
# Run from this folder: ./make.sh
set -e
ROOT=$(cd ../../../.. && pwd)
BODY='<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#8E5CFF"/><stop offset="1" stop-color="#4A2BD6"/></linearGradient></defs>'
FACE='<path d="M512 226 C700 226 812 330 812 520 C812 712 700 806 512 806 C324 806 212 712 212 520 C212 330 324 226 512 226 Z" fill="#fff"/><ellipse cx="420" cy="500" rx="46" ry="62" fill="#1B1340"/><ellipse cx="604" cy="500" rx="46" ry="62" fill="#1B1340"/>'
SVG='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'

# tile: the rounded square on its own (favicons, the docs logo)
echo "$SVG$BODY<rect width=\"1024\" height=\"1024\" rx=\"230\" fill=\"url(#g)\"/>$FACE</svg>" > tile.svg
# ios: full bleed, square; iOS rounds the corners itself
echo "$SVG$BODY<rect width=\"1024\" height=\"1024\" fill=\"url(#g)\"/>$FACE</svg>" > ios.svg
# mac: the macOS grid, an 824 tile in 1024 with a soft shadow beneath
echo "$SVG$BODY<defs><filter id=\"s\" x=\"-10%\" y=\"-10%\" width=\"120%\" height=\"130%\"><feDropShadow dx=\"0\" dy=\"10\" stdDeviation=\"12\" flood-color=\"#000\" flood-opacity=\".28\"/></filter></defs><g transform=\"translate(100 100) scale(.8046875)\"><rect width=\"1024\" height=\"1024\" rx=\"230\" fill=\"url(#g)\" filter=\"url(#s)\"/>$FACE</g></svg>" > mac.svg

# Quick Look fills transparency white, so render with AppKit instead
swiftc -O -o /tmp/blob-render render.swift
render() { # svg size out
  /tmp/blob-render "$1" "$2" "$3"
}

MAC="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset"
for s in 16 32 128 256 512; do
  render mac.svg $s "$MAC/icon_${s}x${s}.png"
  render mac.svg $((s*2)) "$MAC/icon_${s}x${s}@2x.png"
done

# iOS wants no alpha: through JPEG and back drops it
render ios.svg 1024 /tmp/blob-ios.png
sips -s format jpeg -s formatOptions best /tmp/blob-ios.png --out /tmp/blob-ios.jpg >/dev/null
sips -s format png /tmp/blob-ios.jpg --out "$ROOT/Remote/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" >/dev/null

render tile.svg 256 "$ROOT/docs/assets/logo.png"
render tile.svg 64 "$ROOT/docs/assets/favicon.png"
render tile.svg 64 "$ROOT/Web/assets/favicon.png"
render tile.svg 1024 tile-1024.png
echo done
