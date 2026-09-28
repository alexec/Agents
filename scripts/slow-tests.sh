#!/bin/sh
# Prints a `swift test --filter` for `.slowUnderLoad` tests in one package.
#   scripts/slow-tests.sh Packages/AgentsKit
set -eu
grep -rhoE '@Test\(\.slowUnderLoad[^)]*\)( @[A-Za-z]+)* func [A-Za-z0-9_]+' "$1/Tests" \
    | sed -E 's/.* func //' | sort -u | sed 's/$/\\(/' | paste -sd'|' -
