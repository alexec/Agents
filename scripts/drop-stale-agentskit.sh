#!/usr/bin/env bash
# Drop AgentsKit's own targets from a restored SwiftPM build folder when the graph was
# built from other AgentsKit sources (#898, #897). SwiftPM recompiles AgentsKit but not
# AgentsKitCore on such a graph, and the link fails on undefined AgentsKitCore symbols;
# the clean retry after it rebuilds swift-nio, swift-nio-ssl and SwiftTerm as well, which
# cost 4–11 minutes a run.
#
# Usage: scripts/drop-stale-agentskit.sh <.build folder> <agentskit sources hash>
# The save step writes the hash to <.build folder>/agentskit-sources.
set -euo pipefail

build=${1:?.build folder required}
want=${2:?AgentsKit sources hash required}

out="$build/out"
built="$(cat "$build/agentskit-sources" 2>/dev/null || true)"
if [[ "$built" == "$want" ]]; then
	exit 0
fi
echo "AgentsKit sources differ from the graph restored in $build (${built:-unrecorded}); dropping its own targets."
rm -rf "$out/Intermediates.noindex/AgentsKit.build"
if [[ -d "$out/Products/Debug" ]]; then
	find "$out/Products/Debug" -maxdepth 1 \( -name 'AgentsKit*' -o -name 'libAgentsKit*' \
		-o -name 'ControlDial*' -o -name 'libControlDial*' -o -name 'CShims*' \
		-o -name 'accept-probe*' -o -name 'accept_probe*' \) -exec rm -rf {} +
fi
