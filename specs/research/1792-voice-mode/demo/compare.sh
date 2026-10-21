#!/bin/zsh
# The #1792 runtime comparison: every prompt in prompts.txt, for each runtime given,
# with the voice-mode text and without, on a run-app scratch root. One JSON line a turn.
#   compare.sh ROOT OUT.jsonl claude cursor
set -u
root=$1 out=$2; shift 2
here=${0:A:h}
for runtime in "$@"; do
  for mode in voice plain; do
    while IFS= read -r prompt; do
      git -C "$root/work" reset -q --hard && git -C "$root/work" clean -qfd
      flag=(); [[ $mode == plain ]] && flag=(--plain)
      python3 "$here/voice-turn.py" "$root" "$runtime" "$prompt" "${flag[@]}" --timeout 240 >> "$out"
    done < "$here/prompts.txt"
  done
done
