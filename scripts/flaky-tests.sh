#!/bin/sh
# Prints a `swift test --filter` for the tests marked `.flakyUnderLoad` in one package,
# or nothing when there are none. The mark is written on the `@Test` line, beside the
# function's name. Used by .github/workflows/ci.yml to run them on their own.
#   scripts/flaky-tests.sh Packages/AgentsKit
set -eu
grep -rhoE '@Test\(\.flakyUnderLoad[^)]*\)( @[A-Za-z]+)* func [A-Za-z0-9_]+' "$1/Tests" \
    | sed -E 's/.* func //' | sort -u | sed 's/$/\\(/' | paste -sd'|' -
