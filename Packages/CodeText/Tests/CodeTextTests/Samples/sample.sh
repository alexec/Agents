#!/usr/bin/env bash
# A small shop's till, for the colour samples (041).
set -euo pipefail

FLOAT=150
MASK=0xFF
receipts=()

sell() {
  local item=$1 price=$2 count=${3:-1}
  if (( count <= 0 )); then
    echo "cannot sell ${count} of ${item}" >&2
    return 1
  fi
  receipts+=("$item:$(( price * count ))")
  FLOAT=$(( FLOAT + price * count ))
}

sell coffee 3 2
for r in "${receipts[@]}"; do
  printf '%s\n' "$r"
done
echo "float is $FLOAT" | tee /tmp/till.log > /dev/null
