#!/bin/sh
# Makes the docs site's narrated videos with no person (#1078). See make.py and README.md.
#
#   scripts/video/make.sh u1 a2 …   [--no-build] [--keep] [--voice-only] [--compose-only] [--upload]
#   scripts/video/make.sh --sign-in linear   the video Chrome, for the person to sign in once
#
# The first run makes the voice and Whisper set-up in ~/.cache/agents-video/venv. Chatterbox's
# watermarker needs pkg_resources, so setuptools stays below 81.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
venv="$HOME/.cache/agents-video/venv"
if [ ! -x "$venv/bin/python" ]; then
	uv venv -q --python 3.11 "$venv"
	VIRTUAL_ENV="$venv" uv pip install -q chatterbox-tts==0.1.7 mlx-whisper pillow "setuptools<81"
fi
exec "$venv/bin/python" "$here/make.py" "$@"
