#!/bin/sh
# The wire's types (#1135). Packages/Wire is the source: the schema (daemon.schema.json) and
# the methods (daemon.openrpc.json, control.openrpc.json). Go and TypeScript are made from it;
# Swift's Model types are written by hand and checked against it (WireSchemaTests).
#
#   scripts/wire.sh gen     write Go/wire/types_gen.go, Go/wire/methods_gen.go and
#                           Web/src/protocol/generated.ts from Packages/Wire
#   scripts/wire.sh check   write nothing; fail when one of them is not what Packages/Wire makes
#
# Go runs through Go/scripts/go.sh, in a container on the Mac: lease "build" first. A change
# to a type changes the schema, runs `gen`, and commits all three files; a conflict in one of
# them is settled by running `gen` again, never by hand.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "${1:-}" in
gen) exec "$root/Go/scripts/go.sh" run ./cmd/wiregen ;;
check) exec "$root/Go/scripts/go.sh" run ./cmd/wiregen -check ;;
*)
	echo "usage: scripts/wire.sh gen | check" >&2
	exit 2
	;;
esac
