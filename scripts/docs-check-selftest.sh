#!/bin/sh
# Proves the docs check catches each kind of break (044, SC-004).
#
#   scripts/docs-check-selftest.sh
#
# Each break is made in a throwaway copy of mkdocs.yml and docs/, never in the real ones,
# and must fail the check (docs-check.py, then the strict build) with the broken file named.
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZENSICAL=$(sed -n 's/^ZENSICAL=//p' "$root/scripts/docs.sh")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
failed=0

fresh() {
	rm -rf "$work/copy"
	mkdir -p "$work/copy"
	cp "$root/mkdocs.yml" "$work/copy/"
	cp -R "$root/docs" "$work/copy/"
}

page() { # page <path under docs> <diataxis> <body>
	mkdir -p "$(dirname "$work/copy/docs/$1")"
	printf -- '---\ndiataxis: %s\n---\n\n# Self-test page\n\n%s\n' "$2" "$3" > "$work/copy/docs/$1"
}

in_nav() { # in_nav <path under docs>: adds it under Reference, as the page after its index
	awk -v page="$1" '{ print } $0 == "      - reference/index.md" { print "      - " page }' \
		"$work/copy/mkdocs.yml" > "$work/nav.yml" && mv "$work/nav.yml" "$work/copy/mkdocs.yml"
}

expect() { # expect <name> <file the output must name>
	out=$( (python3 "$root/scripts/docs-check.py" --root "$work/copy" &&
		cd "$work/copy" && uvx -q "$ZENSICAL" build --strict --clean) 2>&1)
	status=$?
	if [ $status -ne 0 ] && printf '%s' "$out" | grep -q "$2"; then
		echo "PASS $1"
	else
		echo "FAIL $1 (exit $status, expected a failure naming $2)"
		printf '%s\n' "$out" | tail -5 | sed 's/^/    /'
		failed=1
	fi
}

fresh
out=$(python3 "$root/scripts/docs-check.py" --root "$work/copy" 2>&1) ||
	{ echo "FAIL the unbroken copy does not pass: $out"; exit 1; }

fresh; page reference/dead-link.md reference "[gone](no-such-page.md)"; in_nav reference/dead-link.md
expect "dead link" "dead-link.md"

fresh; page reference/dead-anchor.md reference "[gone](index.md#no-such-heading)"; in_nav reference/dead-anchor.md
expect "dead anchor" "dead-anchor.md"

fresh; page reference/unreached.md reference "Nobody links here."
expect "page not in the nav" "reference/unreached.md"

fresh; printf '# No front matter\n' > "$work/copy/docs/reference/no-section.md"; in_nav reference/no-section.md
expect "page with no section" "reference/no-section.md"

fresh; page how-to/lesson.md tutorial "## Where next"; in_nav how-to/lesson.md
expect "page in the wrong section's folder" "how-to/lesson.md"

fresh; page reference/no-picture.md reference "![A picture](images/missing.png)"; in_nav reference/no-picture.md
expect "missing picture" "reference/no-picture.md"

fresh; page reference/private.md reference "It lives in /Users/someone/code."; in_nav reference/private.md
expect "private path" "reference/private.md"

[ $failed -eq 0 ] && echo "docs-check-selftest: all breaks caught" || echo "docs-check-selftest: some breaks slipped through"
[ -z "$(git -C "$root" status --porcelain -- docs mkdocs.yml)" ] ||
	echo "note: docs/ or mkdocs.yml has uncommitted changes of your own (this test never writes there)"
exit $failed
