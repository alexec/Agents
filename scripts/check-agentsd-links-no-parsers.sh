#!/bin/zsh
# agentsd must not carry the code colouring (041): it moves text and reads none of it.
# Checks project.yml's agentsd target, and the built binary when there is one.
#
#   scripts/check-agentsd-links-no-parsers.sh [path/to/agentsd]

set -euo pipefail
root=${0:A:h:h}

# The agentsd target's block, up to the next target at the same indent.
block=$(awk '/^  agentsd:/{on=1; print; next} on && /^  [A-Za-z]/{exit} on{print}' $root/project.yml)
[[ -n $block ]] || { print -u2 "no agentsd target in project.yml"; exit 1 }
if print -r -- $block | grep -q 'CodeText'; then
  print -u2 "agentsd lists CodeText in project.yml"; exit 1
fi

binary=${1:-$(ls -d $root/build/DD/Build/Products/*/Agents.app/Contents/Helpers/agentsd(N) | head -1)}
if [[ -n $binary && -f $binary ]]; then
  if nm $binary 2>/dev/null | grep -qE 'tree_sitter_|ts_parser_'; then
    print -u2 "$binary has tree-sitter symbols"; exit 1
  fi
  print "agentsd: no parsers ($binary)"
else
  print "agentsd: project.yml clean (no built binary to check)"
fi
