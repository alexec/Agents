#!/bin/sh
# Makes the docs site's narrated videos with no person (#1078). See make.py and README.md.
#
#   scripts/video/make.sh u1 a2 …   [--no-build] [--keep] [--voice-only] [--compose-only] [--upload]
#   scripts/video/make.sh --sign-in linear   the video Chrome, for the person to sign in once
#
# The first run makes the voice and Whisper set-up in ~/.cache/agents-video/venv: Kokoro's
# voice through mlx-audio, with misaki (Kokoro's English) and spaCy's small English model,
# which misaki would otherwise try to install as it runs (#4964).
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
venv="$HOME/.cache/agents-video/venv"
if [ ! -x "$venv/bin/python" ]; then
	uv venv -q --python 3.11 "$venv"
fi
if ! "$venv/bin/python" -c "import mlx_audio, misaki, en_core_web_sm, mlx_whisper, PIL" 2>/dev/null; then
	VIRTUAL_ENV="$venv" uv pip install -q mlx-audio==0.6.5 "misaki[en]==0.9.4" soundfile mlx-whisper pillow \
		"en_core_web_sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
fi
exec "$venv/bin/python" "$here/make.py" "$@"
