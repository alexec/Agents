#!/bin/sh
# The design system (#4600; specs/4600-design-system/spec.md).
#
#   scripts/design.sh gen             write the CSS token files from design/tokens.json (#4602):
#                                     Web/src/theme/tokens.css, www/tokens.css,
#                                     docs/stylesheets/tokens.css, Go/internal/forgepages/tokens.css;
#                                     DesignTokensTests checks Paper.swift, StateTint.swift,
#                                     TypeScale.swift and the AccentColor assets against the JSON
#   scripts/design.sh check           write nothing; fail when a token file is not what the JSON
#                                     makes (scripts/lint.sh runs it, so CI fails on a stale file)
#   scripts/design.sh selftest        scripts/design.py's own test
#   scripts/design.sh marks           draw the Blob (#1237) and write every mark made from it: the
#                                     SVG parts in design/logo/blob/final/, the Mac and iOS app
#                                     icons, the Dock moods, the menu bar template, and the icons,
#                                     favicons and touch icons of the web page, the docs site and www
#   scripts/design.sh marks --check   write nothing; fail when a mark is not what `marks` makes
#                                     (CI's `marks` job, #4615): the same bytes, or for a PNG the
#                                     same size and every channel within 8/255
#
# `marks` runs on the Mac only: AppKit (design/logo/blob/final/render.swift) renders every PNG, so
# no two targets drift by a renderer. It needs no build lease: it compiles one file.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# marks OUT: write every mark under OUT, a copy of the repo's layout, and list the files it wrote
# in OUT/.marks
marks() {
	OUT=$1
	SRC="$OUT/design/logo/blob/final"
	work=$(mktemp -d)
	mkdir -p "$SRC"
	: >"$OUT/.marks"
	# put PATH: the file at OUT/PATH is a mark; make its folder
	put() {
		mkdir -p "$(dirname "$OUT/$1")"
		echo "$1" >>"$OUT/.marks"
		echo "$OUT/$1"
	}
	svg() { # name: an SVG part, written from stdin
		cat >"$(put "design/logo/blob/final/$1")"
	}

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
		case "${2:-}" in
		asleep) INSIDE=$ASLEEP_FACE MARK=$ASLEEP_MARK TILT= ;;
		quizzical) INSIDE=$QUIZZICAL_FACE MARK=$QUIZZICAL_MARK TILT=' rotate(-7)' ;;
		*) INSIDE="<g fill=\"#0E1A3A\">$EYES</g><path d=\"M-64 80 Q0 150 64 80\" $INK stroke-width=\"$1\"/>" MARK= TILT= ;;
		esac
		echo "<g transform=\"translate(512 516) scale(.9)$TILT\"><path d=\"$BLOB\" fill=\"none\" stroke=\"#3A78E6\" stroke-width=\"56\" stroke-linejoin=\"round\"/><path d=\"$BLOB\" fill=\"#fff\"/>$INSIDE</g>$MARK"
	}
	FACE=$(face 28)
	# At 32 px and under the smile's thin stroke is lost, so those sizes draw it heavier
	SMALL=$(face 64)
	SVG='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
	TILE='<rect width="1024" height="1024" rx="230" fill="url(#g)"/>'

	# tile: the rounded square on its own (favicons, the docs logo, www's mark)
	echo "$SVG$BODY$TILE$FACE</svg>" | svg tile.svg
	# tile-small: the tile with the heavy smile, for the favicons at 16 and 32 px
	echo "$SVG$BODY$TILE$SMALL</svg>" | svg tile-small.svg
	# ios: full bleed, square; iOS rounds the corners itself
	echo "$SVG$BODY<rect width=\"1024\" height=\"1024\" fill=\"url(#g)\"/>$FACE</svg>" | svg ios.svg
	# mac: the macOS grid, an 824 tile in 1024 with a soft shadow beneath
	mac() { # face
		echo "$SVG$BODY<defs><filter id=\"s\" x=\"-10%\" y=\"-10%\" width=\"120%\" height=\"130%\"><feDropShadow dx=\"0\" dy=\"10\" stdDeviation=\"12\" flood-color=\"#000\" flood-opacity=\".28\"/></filter></defs><g transform=\"translate(100 100) scale(.8046875)\"><rect width=\"1024\" height=\"1024\" rx=\"230\" fill=\"url(#g)\" filter=\"url(#s)\"/>$1</g></svg>"
	}
	mac "$FACE" | svg mac.svg
	mac "$SMALL" | svg mac-small.svg
	# the moods (#1317): the Dock tile is drawn at 128 pt and more, so the full stroke does
	for MOOD in asleep quizzical; do
		mac "$(face 28 $MOOD)" | svg mac-$MOOD.svg
		echo "$SVG$BODY$TILE$(face 28 $MOOD)</svg>" | svg tile-$MOOD.svg
	done
	# www's mark in the page (#1986) is the tile itself
	cp "$SRC/tile.svg" "$(put www/assets/icon.svg)"

	# The menu bar mark (Agents Host's, in the one app since #4225): a template of outline, eyes
	# and smile in one colour, so it follows a light or dark menu bar; the eyes and smile cut
	# through, the outline and smile heavier to hold at 18 pt
	echo "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"-340 -330 680 660\" width=\"19\" height=\"18\"><path d=\"$BLOB\" fill=\"none\" stroke=\"#000\" stroke-width=\"72\" stroke-linejoin=\"round\"/><g fill=\"#000\">$EYES</g><path d=\"M-72 80 Q0 160 72 80\" fill=\"none\" stroke=\"#000\" stroke-width=\"56\" stroke-linecap=\"round\"/></svg>" \
		>"$(put App/Resources/Assets.xcassets/MenuBarBlob.imageset/menu-bar.svg)"

	swiftc -O -o "$work/render" "$root/design/logo/blob/final/render.swift"
	render() { # svg size path
		"$work/render" "$SRC/$1" "$2" "$(put "$3")"
	}
	# ico path: a favicon.ico at 16, 32 and 48 px, the heavy smile at 16 and 32
	ico() {
		"$work/render" "$SRC/tile-small.svg" 16 "$work/16.png"
		"$work/render" "$SRC/tile-small.svg" 32 "$work/32.png"
		"$work/render" "$SRC/tile.svg" 48 "$work/48.png"
		"$work/render" ico "$(put "$1")" "$work/16.png" "$work/32.png" "$work/48.png"
	}

	# the Mac app: one since #4225, so one icon set (#1237)
	MAC=App/Resources/Assets.xcassets/AppIcon.appiconset
	for s in 16 32 128 256 512; do
		one=mac.svg two=mac.svg
		[ "$s" -le 32 ] && one=mac-small.svg
		[ "$s" -le 16 ] && two=mac-small.svg
		render $one $s "$MAC/icon_${s}x${s}.png"
		render $two $((s * 2)) "$MAC/icon_${s}x${s}@2x.png"
	done

	# iOS wants no alpha: through JPEG and back drops it
	"$work/render" "$SRC/ios.svg" 1024 "$work/ios.png"
	sips -s format jpeg -s formatOptions best "$work/ios.png" --out "$work/ios.jpg" >/dev/null
	sips -s format png "$work/ios.jpg" --out "$(put Remote/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png)" >/dev/null

	render tile.svg 1024 design/logo/blob/final/tile-1024.png
	# the docs site: its logo and favicon, and a favicon.ico at the site's root, where a browser
	# looks for one
	render tile.svg 256 docs/assets/logo.png
	render tile.svg 64 docs/assets/favicon.png
	ico docs/favicon.ico
	# the web page: the favicon its mood swaps (Web/src/model/iconMood.ts), and installed as an
	# app (#791) the tile for Chrome, full bleed for a maskable icon and for iOS's home screen,
	# which rounds it itself
	# (no favicon.ico: the tab's one icon link changes with the mood, and an .ico beside it would
	# keep the happy Blob)
	render tile.svg 64 Web/assets/favicon.png
	render tile.svg 192 Web/assets/icon-192.png
	render tile.svg 512 Web/assets/icon-512.png
	render ios.svg 512 Web/assets/icon-maskable-512.png
	render ios.svg 180 Web/assets/apple-touch-icon.png
	# www (#1986): the same favicon and the same full-bleed touch icon as the web page
	render tile.svg 64 www/assets/favicon.png
	ico www/assets/favicon.ico
	render ios.svg 180 www/assets/apple-touch-icon.png

	# the moods (#1317): the Dock tile's images, which the app sets while it runs (the happy
	# Blob is the bundle's own icon), and the favicons the web page swaps between
	for MOOD in asleep quizzical; do
		NAME=Dock$(echo $MOOD | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
		render mac-$MOOD.svg 1024 "App/Resources/Assets.xcassets/$NAME.imageset/dock.png"
		printf '{\n  "images" : [\n    { "filename" : "dock.png", "idiom" : "universal", "scale" : "2x" }\n  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' \
			>"$(put "App/Resources/Assets.xcassets/$NAME.imageset/Contents.json")"
		render tile-$MOOD.svg 64 "Web/assets/favicon-$MOOD.png"
		render tile-$MOOD.svg 1024 design/logo/blob/final/tile-$MOOD-1024.png
	done
	rm -rf "$work"
}

case "${1:-} ${2:-}" in
"gen " | "check ") exec python3 "$root/scripts/design.py" "$1" ;;
"selftest ") exec python3 "$root/scripts/design.py" --selftest ;;
"marks ")
	marks "$root"
	rm "$root/.marks"
	;;
"marks --check")
	MOST=8
	out=$(mktemp -d)
	trap 'rm -rf "$out"' EXIT
	marks "$out" >/dev/null
	swiftc -O -o "$out/.render" "$root/design/logo/blob/final/render.swift"
	stale=0
	while read -r f; do
		cmp -s "$out/$f" "$root/$f" && continue
		# A PNG may differ by a few levels from the Mac that made it (CI's GPU is a virtual one):
		# the same size and at most $MOST/255 on every channel is the same mark
		case "$f" in
		*.png) [ -f "$root/$f" ] && why=$("$out/.render" same "$out/$f" "$root/$f" "$MOST") && continue ;;
		*) why= ;;
		esac
		echo "design.sh: $f is not what \`scripts/design.sh marks\` makes${why:+ ($why)}" >&2
		stale=1
	done <"$out/.marks"
	if [ "$stale" = 1 ]; then
		echo "design.sh: run scripts/design.sh marks and commit what it writes" >&2
		exit 1
	fi
	echo "design.sh: every mark is what the Blob source makes ($(wc -l <"$out/.marks" | tr -d ' ') files)"
	;;
*)
	echo "usage: scripts/design.sh gen | check | selftest | marks [--check]" >&2
	exit 2
	;;
esac
