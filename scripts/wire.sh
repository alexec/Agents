#!/bin/sh
# The wire's types (#1135). Packages/Wire is the source: the schema (Packages/Wire/schema) and
# the methods (daemon.openrpc.json, control.openrpc.json). Go and TypeScript are made from it;
# Swift's Model types are written by hand and checked against it (WireSchemaTests).
#
#   scripts/wire.sh gen     write Go/wire/types_gen.go, Go/wire/methods_gen.go and
#                           Web/src/protocol/generated.ts from Packages/Wire
#   scripts/wire.sh check   write nothing; fail when one of them is not what Packages/Wire makes
#   scripts/wire.sh compat  fail when what a caller sends changed since the last release tag
#                           with the same x-capability (#4095; scripts/wire-compat.py)
#
# Go runs through Go/scripts/go.sh, the Mac's own Go (#4709): lease "build" first. A change
# to a type changes the schema, runs `gen`, and commits all three files; a conflict in one of
# them is settled by running `gen` again, never by hand.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "${1:-}" in
gen) exec "$root/Go/scripts/go.sh" run ./cmd/wiregen ;;
check) exec "$root/Go/scripts/go.sh" run ./cmd/wiregen -check ;;
compat)
	shift
	cd "$root" && exec python3 scripts/wire-compat.py "$@"
	;;
*)
	echo "usage: scripts/wire.sh gen | check | compat [tag]" >&2
	exit 2
	;;
esac
