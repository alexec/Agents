#!/bin/sh
# Copy the stand-in ACP runtime into <dir> as `grok` and `copilot`, for a scratch app
# launched with AGENTS_TEST_SEARCH_PATHS=<dir> (052, T005). Test-only.
set -eu
dir=${1:?usage: install-fake-runtimes.sh <dir>}
case "$dir" in
  "$HOME"/Library*|"$HOME"/.local*|"$HOME"/.grok*) echo "refusing $dir: that is where real runtimes live" >&2; exit 2 ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$dir"
for name in grok copilot; do
  cp "$here/fake-acp-runtime.py" "$dir/$name"
  chmod +x "$dir/$name"
done
echo "$dir: grok, copilot (write spent or ok to <dir>/<name>.behaviour)"
