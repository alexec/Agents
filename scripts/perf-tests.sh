#!/bin/sh
# The performance check (#225): the tests marked `.perfBudget`, on their own, held to
# their wall-clock budgets with AGENTS_RUN_PERF=1. Every other run of these tests (a plain
# `swift test`, CI, a merge wave's test-agentskit and test-codetext) asserts what they
# compute and prints the time, but holds no budget, because a budget measured beside
# three builds measures the load.
#
# Run it on a quiet Mac, nothing else building:
#   scripts/perf-tests.sh             both packages
#   scripts/perf-tests.sh --filter    print each package's filter and run nothing
# CI runs it from the perf job in .github/workflows/slow-tests.yml.
set -eu
cd "$(dirname "$0")/.."
filter() {
    grep -rhoE '@Test\(\.perfBudget[^)]*\)( @[A-Za-z]+)* func [A-Za-z0-9_]+' "$1/Tests" \
        | sed -E 's/.* func //' | sort -u | sed 's/$/\\(/' | paste -sd'|' -
}
status=0
for package in Packages/AgentsKit Packages/CodeText; do
    f=$(filter "$package")
    [ -n "$f" ] || continue
    if [ "${1:-}" = --filter ]; then echo "$package $f"; continue; fi
    echo "perf-tests: $package" >&2
    AGENTS_RUN_PERF=1 swift test --package-path "$package" --filter "$f" || status=1
done
exit $status
