#!/bin/sh
# The docs site (044): serve it locally, build it, or check it the way CI does.
#
#   scripts/docs.sh serve   http://127.0.0.1:8000, reloading as pages change
#   scripts/docs.sh build   strict build into site/
#   scripts/docs.sh check   docs-check.py, then the strict build
#
# Needs uv (https://docs.astral.sh/uv/) and python3. Nothing is installed globally.
set -eu

# The one place the generator's version is pinned.
ZENSICAL=zensical==0.0.65

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

case "${1:-}" in
serve) exec uvx "$ZENSICAL" serve -a 127.0.0.1:8000 ;;
build) exec uvx "$ZENSICAL" build --strict --clean ;;
check)
	python3 scripts/docs-check.py
	exec uvx "$ZENSICAL" build --strict --clean
	;;
*)
	echo "usage: scripts/docs.sh serve | build | check" >&2
	exit 2
	;;
esac
