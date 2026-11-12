#!/bin/sh
# A PR's silent clip (#4094): an animated WebP of a scratch window, for motion. See clip.py.
#
#   scripts/video/clip.sh /tmp/run-<slug> /tmp/run-<slug>-shots/mac-scroll.webp -- \
#     .agents/skills/run-app/scripts/walk.py /tmp/run-<slug> scroll --to bottom
#
# It needs only Pillow: the videos' venv when make.sh made it, else uv's own, with the same
# Pillow.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
venv="$HOME/.cache/agents-video/venv"
if [ -x "$venv/bin/python" ] && "$venv/bin/python" -c 'import PIL' 2>/dev/null; then
	exec "$venv/bin/python" "$here/clip.py" "$@"
fi
exec uv run -q --no-project --python 3.11 --with pillow==12.3.0 python "$here/clip.py" "$@"
