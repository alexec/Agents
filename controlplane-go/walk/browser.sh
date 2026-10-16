#!/bin/sh
# The web page in headless Chrome against a run.sh set-up (stage 5, #1126): pairs with a
# --browser code, waits for an agent of the Mac host, opens it, sends a turn, reloads.
# Screenshots go beside this script. Chrome runs headless with a profile under /tmp, so it
# needs no screen and never touches Alex's Chrome.
#   walk/browser.sh <slug> <agent title>
set -e
here="$(cd "$(dirname "$0")" && pwd)"
slug="${1:-cpgo}"; want="${2:?the title of an agent on the Mac host}"
port="$(grep -o 'serving the web remote at http://localhost:[0-9]*' "/tmp/run-$slug/control/control.log" | tail -1 | grep -o '[0-9]*$')"
dir="$HOME/Library/Caches/Agents-build/cpgo-browser"
[ -d "$dir/node_modules/playwright-core" ] || { mkdir -p "$dir"; (cd "$dir" && npm init -y >/dev/null && npm i -s playwright-core); }
cp "$here/browser.mjs" "$dir/"
cd "$dir" && node browser.mjs "http://localhost:$port/" "$("$here/../run.sh" code "$slug" --client --browser)" "$want" "$here"
